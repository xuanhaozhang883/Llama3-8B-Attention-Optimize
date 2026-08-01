`timescale 1ns/1ps

// Full-size pre-optimization qualification for v3.0 Online-Fused Attention.
// This is simulation-only code. It does not alter or wrap the design math.
module tb_v30_full8_golden_profile;
    localparam int SEQ = 128;
    localparam int DIM = 128;
    localparam int GROUPS = 8;
    localparam int Q_PER_GROUP = 4;
    localparam int Q_HEADS = GROUPS*Q_PER_GROUP;
    localparam int Q_WORDS = Q_HEADS*SEQ*DIM;
    localparam int KV_WORDS = GROUPS*SEQ*DIM;
    localparam int CONTEXT_WORDS = Q_WORDS;
    localparam int RAW_REQUESTS = GROUPS*(Q_PER_GROUP+1)*SEQ*(DIM/2);

`ifdef V30_XSIM
    localparam Q_FILE = "q_before_rope_bf16.hex";
    localparam K_FILE = "k_before_rope_bf16.hex";
    localparam V_FILE = "v_bf16.hex";
    localparam GOLDEN_FILE = "attn_out_online_fused_bf16.hex";
    localparam EXP_FILE = "exp_lut_q15.mem";
    localparam SIN_FILE = "sin_bf16.hex";
    localparam COS_FILE = "cos_bf16.hex";
`else
    localparam Q_FILE = "vitis/data/q_before_rope_bf16.hex";
    localparam K_FILE = "vitis/data/k_before_rope_bf16.hex";
    localparam V_FILE = "vitis/data/v_bf16.hex";
    localparam GOLDEN_FILE = "vitis/data/attn_out_online_fused_bf16.hex";
    localparam EXP_FILE = "mem/exp_lut_q15.mem";
    localparam SIN_FILE = "mem/sin_bf16.hex";
    localparam COS_FILE = "mem/cos_bf16.hex";
`endif

    logic [15:0] q_mem [0:Q_WORDS-1];
    logic [15:0] k_mem [0:KV_WORDS-1];
    logic [15:0] v_mem [0:KV_WORDS-1];
    logic [15:0] golden_mem [0:CONTEXT_WORDS-1];

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, start, start_ready, busy, done;
    logic raw_req_valid, raw_req_ready, raw_req_is_k;
    logic [4:0] raw_req_head;
    logic [6:0] raw_req_token;
    logic [5:0] raw_req_pair;
    logic raw_rsp_valid, raw_rsp_ready;
    logic [15:0] raw_rsp_x0, raw_rsp_x1;
    logic v_load_valid, v_load_ready;
    logic [16:0] v_load_addr;
    logic [63:0] v_load_data;
    logic context_valid, context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [2:0] context_group_id;
    logic [1:0] context_head;
    logic [4:0] context_global_q_head;
    logic [6:0] context_row, context_col;
    logic context_group_last, context_global_last;
    logic group_complete;
    logic [2:0] completed_group_id, active_group_id;
    logic rope_busy, qk_busy, online_busy;
    logic [31:0] qk_tiles_computed, qk_tiles_skipped;
    logic [31:0] masked_tiles_emitted;
    logic [31:0] online_tiles_processed, online_tiles_skipped;
    logic [31:0] online_rescale_events, online_v_vectors_read;
    logic [31:0] online_mac_terms;
    logic start_while_busy_error, qk_causal_skip_error;
    logic v_cache_error, online_order_error, online_numeric_error;
    logic protocol_error;

    logic raw_pending;
    integer raw_request_count, output_count, group_complete_count;
    integer exact_mismatches, combined_failures, failures;
    integer actual_fd, profile_fd, marker_fd;
    longint unsigned total_cycles, qk_busy_cycles, online_busy_cycles;
    longint unsigned rope_busy_cycles, score_backpressure_cycles;
    longint unsigned context_backpressure_cycles;
    longint unsigned state_cycles [0:31];
    longint unsigned group_start_cycle, group_cycles [0:GROUPS-1];
    logic profiling;

    attention_online_system_with_rope_top #(
        .QK_TILE(4), .QK_LANES(2), .V_LANES(4),
        .SEQ_LEN(SEQ), .HEAD_DIM(DIM), .Q_HEADS(Q_PER_GROUP),
        .GQA_GROUPS(GROUPS), .RUN_GQA_GROUPS(GROUPS),
        .EXP_LUT_FILE(EXP_FILE), .SIN_ROM_FILE(SIN_FILE),
        .COS_ROM_FILE(COS_FILE)
    ) dut (
        .clk, .rst_n, .start, .start_ready, .busy, .done,
        .causal_en(1'b1),
        .raw_req_valid, .raw_req_ready, .raw_req_is_k,
        .raw_req_head, .raw_req_token, .raw_req_pair,
        .raw_rsp_valid, .raw_rsp_ready, .raw_rsp_x0, .raw_rsp_x1,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group_id, .context_head,
        .context_global_q_head, .context_row, .context_col,
        .context_group_last, .context_global_last,
        .group_complete, .completed_group_id, .active_group_id,
        .rope_busy, .qk_busy, .online_busy,
        .qk_tiles_computed, .qk_tiles_skipped, .masked_tiles_emitted,
        .online_tiles_processed, .online_tiles_skipped,
        .online_rescale_events, .online_v_vectors_read,
        .online_mac_terms, .start_while_busy_error,
        .qk_causal_skip_error, .v_cache_error,
        .online_order_error, .online_numeric_error, .protocol_error
    );

    function automatic integer bf16_key(input logic [15:0] value);
        integer raw;
        begin
            raw = value;
            if (value[15]) bf16_key = (~raw) & 16'hFFFF;
            else bf16_key = raw ^ 16'h8000;
        end
    endfunction

    function automatic integer bf16_ulp(
        input logic [15:0] expected,
        input logic [15:0] actual
    );
        integer delta;
        begin
            if (((expected & 16'h7FFF) == 0) &&
                ((actual & 16'h7FFF) == 0)) begin
                bf16_ulp = 0;
            end else begin
                delta = bf16_key(expected) - bf16_key(actual);
                bf16_ulp = (delta < 0) ? -delta : delta;
            end
        end
    endfunction

    function automatic real pow2_integer(input integer exponent_value);
        integer step;
        real result;
        begin
            result = 1.0;
            if (exponent_value >= 0)
                for (step = 0; step < exponent_value; step = step+1)
                    result = result * 2.0;
            else
                for (step = 0; step < -exponent_value; step = step+1)
                    result = result / 2.0;
            pow2_integer = result;
        end
    endfunction

    function automatic real bf16_to_real(input logic [15:0] value);
        integer exponent_value;
        integer fraction_value;
        real magnitude;
        begin
            exponent_value = value[14:7];
            fraction_value = value[6:0];
            if (exponent_value == 0)
                magnitude = (fraction_value / 128.0) * pow2_integer(-126);
            else if (exponent_value == 255)
                magnitude = 1.0e300;
            else
                magnitude = (1.0 + fraction_value / 128.0) *
                            pow2_integer(exponent_value-127);
            bf16_to_real = value[15] ? -magnitude : magnitude;
        end
    endfunction

    assign raw_req_ready = !raw_pending && !raw_rsp_valid;
    assign context_ready = 1'b1;

    always @(posedge clk) begin : RAW_MEMORY_MODEL
        integer base;
        if (!rst_n) begin
            raw_pending = 1'b0;
            raw_rsp_valid = 1'b0;
            raw_rsp_x0 = '0;
            raw_rsp_x1 = '0;
            raw_request_count = 0;
        end else begin
            if (raw_req_valid && raw_req_ready) begin
                base = $unsigned(raw_req_head)*SEQ*DIM +
                       $unsigned(raw_req_token)*DIM +
                       $unsigned(raw_req_pair);
                if (raw_req_is_k) begin
                    raw_rsp_x0 <= k_mem[base];
                    raw_rsp_x1 <= k_mem[base + DIM/2];
                end else begin
                    raw_rsp_x0 <= q_mem[base];
                    raw_rsp_x1 <= q_mem[base + DIM/2];
                end
                raw_pending <= 1'b1;
                raw_request_count = raw_request_count + 1;
            end
            if (raw_pending && !raw_rsp_valid)
                raw_rsp_valid <= 1'b1;
            if (raw_rsp_valid && raw_rsp_ready) begin
                raw_rsp_valid <= 1'b0;
                raw_pending <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin : CHECK_AND_PROFILE
        integer expected_index;
        integer ulp;
        integer state_index;
        real abs_error;
        if (!rst_n) begin
            output_count = 0;
            group_complete_count = 0;
            exact_mismatches = 0;
            combined_failures = 0;
            failures = 0;
            total_cycles = 0;
            qk_busy_cycles = 0;
            online_busy_cycles = 0;
            rope_busy_cycles = 0;
            score_backpressure_cycles = 0;
            context_backpressure_cycles = 0;
            group_start_cycle = 0;
            profiling = 1'b0;
            for (state_index = 0; state_index < 32; state_index = state_index+1)
                state_cycles[state_index] = 0;
            for (state_index = 0; state_index < GROUPS; state_index = state_index+1)
                group_cycles[state_index] = 0;
        end else begin
            if (start && start_ready) begin
                profiling = 1'b1;
                group_start_cycle = 0;
            end
            if (profiling) begin
                total_cycles = total_cycles + 1;
                if (qk_busy) qk_busy_cycles = qk_busy_cycles + 1;
                if (online_busy) online_busy_cycles = online_busy_cycles + 1;
                if (rope_busy) rope_busy_cycles = rope_busy_cycles + 1;
                if (dut.score_valid && !dut.score_ready)
                    score_backpressure_cycles = score_backpressure_cycles + 1;
                if (context_valid && !context_ready)
                    context_backpressure_cycles = context_backpressure_cycles + 1;
                state_index = dut.u_online.state;
                if (state_index >= 0 && state_index < 32)
                    state_cycles[state_index] = state_cycles[state_index] + 1;
            end
            if (group_complete) begin
                group_cycles[completed_group_id] =
                    total_cycles - group_start_cycle;
                group_start_cycle = total_cycles;
                group_complete_count = group_complete_count + 1;
            end
            if (done) profiling = 1'b0;

            if (context_valid && context_ready) begin
                expected_index = $unsigned(context_global_q_head)*SEQ*DIM +
                                 $unsigned(context_row)*DIM +
                                 $unsigned(context_col);
                ulp = bf16_ulp(golden_mem[expected_index], context_bf16);
                if (context_bf16 !== golden_mem[expected_index])
                    exact_mismatches = exact_mismatches + 1;
                if (ulp > 1) begin
                    abs_error = bf16_to_real(golden_mem[expected_index]) -
                                bf16_to_real(context_bf16);
                    if (abs_error < 0.0) abs_error = -abs_error;
                    if (abs_error > 0.0001) begin
                        if (combined_failures < 32)
                            $display("[FAIL] context index=%0d exp=%h got=%h ulp=%0d abs=%e",
                                     expected_index, golden_mem[expected_index],
                                     context_bf16, ulp, abs_error);
                        combined_failures = combined_failures + 1;
                    end
                end
                if (expected_index != output_count) failures = failures + 1;
                if (context_group_last !==
                    ((output_count % (Q_PER_GROUP*SEQ*DIM)) ==
                     (Q_PER_GROUP*SEQ*DIM)-1)) failures = failures + 1;
                if (context_global_last !==
                    (output_count == CONTEXT_WORDS-1)) failures = failures + 1;
                $fdisplay(actual_fd, "%04X", context_bf16);
                output_count = output_count + 1;
            end
        end
    end

    task automatic load_all_v;
        integer address;
        begin
            for (address = 0; address < KV_WORDS; address = address + 4) begin
                @(negedge clk);
                v_load_addr = address[16:0];
                v_load_data = {v_mem[address+3], v_mem[address+2],
                               v_mem[address+1], v_mem[address]};
                v_load_valid = 1'b1;
                while (!v_load_ready) @(negedge clk);
                @(negedge clk);
                v_load_valid = 1'b0;
            end
        end
    endtask

    initial begin : TEST
        integer final_failures;
        integer index;
        $readmemh(Q_FILE, q_mem);
        $readmemh(K_FILE, k_mem);
        $readmemh(V_FILE, v_mem);
        $readmemh(GOLDEN_FILE, golden_mem);
        actual_fd = $fopen("v30_full8_actual_bf16.hex", "w");
        if (actual_fd == 0) $fatal(1, "cannot create actual Context output");

        rst_n = 1'b0;
        start = 1'b0;
        v_load_valid = 1'b0;
        v_load_addr = '0;
        v_load_data = '0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        load_all_v();

        while (!start_ready) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            wait(done);
            begin
                repeat (200000000) @(posedge clk);
                $fatal(1, "[FAIL] full8 timeout outputs=%0d", output_count);
            end
        join_any
        disable fork;
        repeat (4) @(posedge clk);
        $fclose(actual_fd);

        final_failures = failures + combined_failures;
        if (output_count != CONTEXT_WORDS) final_failures = final_failures + 1;
        if (raw_request_count != RAW_REQUESTS) final_failures = final_failures + 1;
        if (group_complete_count != GROUPS) final_failures = final_failures + 1;
        if (qk_tiles_computed != 16896 || qk_tiles_skipped != 15872 ||
            masked_tiles_emitted != 15872) final_failures = final_failures + 1;
        if (online_tiles_processed != 16896 || online_tiles_skipped != 15872 ||
            online_v_vectors_read != 2162688 ||
            online_mac_terms != 33816576 ||
            online_rescale_events != 9390) final_failures = final_failures + 1;
        if (start_while_busy_error || qk_causal_skip_error || v_cache_error ||
            online_order_error || online_numeric_error || protocol_error)
            final_failures = final_failures + 1;

        profile_fd = $fopen("v30_full8_profile.csv", "w");
        $fdisplay(profile_fd, "metric,value");
        $fdisplay(profile_fd, "total_cycles,%0d", total_cycles);
        $fdisplay(profile_fd, "qk_busy_cycles,%0d", qk_busy_cycles);
        $fdisplay(profile_fd, "online_busy_cycles,%0d", online_busy_cycles);
        $fdisplay(profile_fd, "rope_busy_cycles,%0d", rope_busy_cycles);
        $fdisplay(profile_fd, "score_backpressure_cycles,%0d",
                  score_backpressure_cycles);
        $fdisplay(profile_fd, "context_backpressure_cycles,%0d",
                  context_backpressure_cycles);
        $fdisplay(profile_fd, "context_words,%0d", output_count);
        $fdisplay(profile_fd, "exact_mismatches,%0d", exact_mismatches);
        $fdisplay(profile_fd, "combined_failures,%0d", combined_failures);
        for (index = 0; index < GROUPS; index = index+1)
            $fdisplay(profile_fd, "group_%0d_cycles,%0d", index,
                      group_cycles[index]);
        for (index = 0; index < 22; index = index+1)
            $fdisplay(profile_fd, "online_state_%0d_cycles,%0d", index,
                      state_cycles[index]);
        $fclose(profile_fd);

        $display("[PROFILE] total=%0d qk=%0d online=%0d score_bp=%0d",
                 total_cycles, qk_busy_cycles, online_busy_cycles,
                 score_backpressure_cycles);
        $display("[PROFILE] outputs=%0d exact_mismatch=%0d combined_fail=%0d",
                 output_count, exact_mismatches, combined_failures);
        if (final_failures == 0) begin
            marker_fd = $fopen("v30_full8_profile_pass.txt", "w");
            $fdisplay(marker_fd, "V3.0 FULL8 GOLDEN PROFILE: SIM_PASS");
            $fclose(marker_fd);
            $display("[PASS] V3.0 FULL8 GOLDEN + BASELINE PROFILE");
        end else begin
            $fatal(1, "[FAIL] full8 profile failures=%0d", final_failures);
        end
        $finish;
    end
endmodule
