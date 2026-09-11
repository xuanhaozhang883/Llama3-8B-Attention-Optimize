`timescale 1ns/1ps

// Full causal S=128 workload for the B3 protocol/controller layer.
// Arithmetic services are latency-accurate ready/valid stand-ins here; the
// arithmetic RTL and real Vivado IP are verified by separate regressions.
module tb_cats_r4_b3_pv_full_workload;
    localparam int ROWS = 4096;
    localparam int VALID_SCORES = 264192;
    localparam int VECTORS = VALID_SCORES * 4;
    localparam int PV_MACS = VALID_SCORES * 128;
    localparam int CONTEXT_WORDS = ROWS * 128;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic pv_row_valid, pv_row_ready;
    logic [15:0] pv_row_epoch;
    logic [2:0] pv_row_group;
    logic [4:0] pv_row_global_q_head;
    logic [6:0] pv_row_row;
    logic [1:0] pv_row_slot_id, pv_row_numeric_mode;
    logic [31:0] pv_row_sum_fp32, pv_row_inv_sum_fp32;

    logic weight_rd_req_valid, weight_rd_req_ready;
    logic [15:0] weight_rd_req_epoch;
    logic [2:0] weight_rd_req_group;
    logic [4:0] weight_rd_req_global_q_head;
    logic [6:0] weight_rd_req_row;
    logic [1:0] weight_rd_req_slot_id, weight_rd_req_numeric_mode;
    logic [6:0] weight_rd_req_key;
    logic weight_rd_rsp_valid;
    logic [15:0] weight_rd_rsp_epoch;
    logic [2:0] weight_rd_rsp_group;
    logic [4:0] weight_rd_rsp_global_q_head;
    logic [6:0] weight_rd_rsp_row;
    logic [1:0] weight_rd_rsp_slot_id, weight_rd_rsp_numeric_mode;
    logic [6:0] weight_rd_rsp_key;
    logic weight_rd_rsp_mask;
    logic [31:0] weight_rd_rsp_data;

    logic v_req_valid, v_req_ready;
    logic [3:0] v_req_context_tag;
    logic [6:0] v_req_key;
    logic [1:0] v_req_feature_block;
    logic v_rsp_valid;
    logic [3:0] v_rsp_context_tag;
    logic [511:0] v_rsp_vec_bf16;

    logic mac_valid, mac_ready;
    logic [3:0] mac_context_tag;
    logic [6:0] mac_key;
    logic mac_first, mac_last;
    logic [1:0] mac_numeric_mode;
    logic [31:0] mac_weight_data;
    logic [511:0] mac_v_vec_bf16;
    logic mac_rsp_valid, mac_rsp_ready;
    logic [3:0] mac_rsp_context_tag;
    logic [6:0] mac_rsp_key;
    logic mac_rsp_last;
    logic [1023:0] mac_rsp_accum_fp32;

    logic norm_valid, norm_ready;
    logic [3:0] norm_context_tag;
    logic [1023:0] norm_numerator_fp32;
    logic [31:0] norm_inv_sum_fp32;
    logic norm_rsp_valid, norm_rsp_ready;
    logic [3:0] norm_rsp_context_tag;
    logic [511:0] norm_rsp_context_bf16;

    logic out_valid, out_ready;
    logic [15:0] out_epoch;
    logic [11:0] out_seq;
    logic [4:0] out_global_q_head;
    logic [6:0] out_row;
    logic [1:0] out_feature_block;
    logic [511:0] out_data_bf16;
    logic out_row_last, out_tensor_last;

    logic weight_release_valid, weight_release_ready;
    logic [15:0] weight_release_epoch;
    logic [2:0] weight_release_group;
    logic [4:0] weight_release_global_q_head;
    logic [6:0] weight_release_row;
    logic [1:0] weight_release_slot_id, weight_release_numeric_mode;

    logic [63:0] pv_rows_accepted, weight_rd_requests;
    logic [63:0] weight_rd_responses, weight_rd_consumes;
    logic [63:0] v_requests, v_responses, v_consumes;
    logic [63:0] pv_mac_issue, pv_mac_result, pv_mac_commit;
    logic [63:0] context_words, rows_released;
    logic [63:0] raw_scoreboard_stalls, weight_stall_cycles;
    logic [63:0] v_stall_cycles, mac_stall_cycles, output_stall_cycles;
    logic [63:0] protocol_error_count, numeric_error_count;
    logic [63:0] epoch_drop_count;
    logic error_sticky;

    cats_r4_b3_pv_controller dut (.*);

    logic [31:0] lfsr;
    always_ff @(posedge clk) begin
        if (!rst_n || clear)
            lfsr <= 32'hb3f0_4096;
        else
            lfsr <= {lfsr[30:0],
                     lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    end

    // One-cycle scalar-weight service.  Both numeric-mode encodings carry 1.0.
    assign weight_rd_req_ready = 1'b1;
    assign weight_rd_rsp_mask = 1'b0;
    assign weight_rd_rsp_data = weight_rd_rsp_numeric_mode == 0 ?
                                32'h0000_3f80 : 32'h3f80_0000;
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            weight_rd_rsp_valid <= 1'b0;
        end else begin
            weight_rd_rsp_valid <= weight_rd_req_valid &&
                                   weight_rd_req_ready;
            if (weight_rd_req_valid && weight_rd_req_ready) begin
                weight_rd_rsp_epoch <= weight_rd_req_epoch;
                weight_rd_rsp_group <= weight_rd_req_group;
                weight_rd_rsp_global_q_head <=
                    weight_rd_req_global_q_head;
                weight_rd_rsp_row <= weight_rd_req_row;
                weight_rd_rsp_slot_id <= weight_rd_req_slot_id;
                weight_rd_rsp_numeric_mode <= weight_rd_req_numeric_mode;
                weight_rd_rsp_key <= weight_rd_req_key;
            end
        end
    end

    // One-cycle V, MAC, and normalization services.  The controller allows
    // only one outstanding request per context, so tags are sufficient.
    assign v_req_ready = 1'b1;
    assign v_rsp_vec_bf16 = {32{16'h3f80}};
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            v_rsp_valid <= 1'b0;
        end else begin
            v_rsp_valid <= v_req_valid && v_req_ready;
            if (v_req_valid && v_req_ready)
                v_rsp_context_tag <= v_req_context_tag;
        end
    end

    assign mac_ready = 1'b1;
    assign mac_rsp_accum_fp32 = {32{32'h3f80_0000}};
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            mac_rsp_valid <= 1'b0;
        end else if (mac_rsp_valid && !mac_rsp_ready) begin
            mac_rsp_valid <= mac_rsp_valid;
        end else begin
            mac_rsp_valid <= mac_valid && mac_ready;
            if (mac_valid && mac_ready) begin
                mac_rsp_context_tag <= mac_context_tag;
                mac_rsp_key <= mac_key;
                mac_rsp_last <= mac_last;
            end
        end
    end

    assign norm_ready = 1'b1;
    assign norm_rsp_context_bf16 = {32{16'h3f80}};
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            norm_rsp_valid <= 1'b0;
        end else begin
            norm_rsp_valid <= norm_valid && norm_ready;
            if (norm_valid && norm_ready)
                norm_rsp_context_tag <= norm_context_tag;
        end
    end

    // Exercise sustained output/release backpressure without making runtime
    // depend strongly on a random seed.
    assign out_ready = lfsr[0] || lfsr[3];
    assign weight_release_ready = lfsr[1] || lfsr[5];

    integer slot_weight_next [0:2];
    integer context_v_next [0:11];
    integer context_mac_next [0:11];
    logic slot_in_use [0:2];
    integer output_seq, output_block, release_seq;
    integer accepted_rows;
    integer check_index;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            accepted_rows <= 0;
            output_seq <= 0;
            output_block <= 0;
            release_seq <= 0;
            for (check_index = 0; check_index < 3; check_index++) begin
                slot_in_use[check_index] <= 1'b0;
                slot_weight_next[check_index] <= 0;
            end
            for (check_index = 0; check_index < 12; check_index++) begin
                context_v_next[check_index] <= 0;
                context_mac_next[check_index] <= 0;
            end
        end else begin
            if (pv_row_valid && pv_row_ready) begin
                if (pv_row_slot_id != accepted_rows % 3 ||
                    pv_row_global_q_head != accepted_rows / 128 ||
                    pv_row_row != accepted_rows % 128 ||
                    pv_row_group != (accepted_rows / 128) / 4 ||
                    pv_row_numeric_mode != accepted_rows % 2 ||
                    slot_in_use[pv_row_slot_id])
                    $fatal(1, "full workload row token/slot mismatch seq=%0d",
                           accepted_rows);
                slot_in_use[pv_row_slot_id] <= 1'b1;
                slot_weight_next[pv_row_slot_id] <= 0;
                for (check_index = 0; check_index < 4; check_index++) begin
                    context_v_next[pv_row_slot_id*4+check_index] <= 0;
                    context_mac_next[pv_row_slot_id*4+check_index] <= 0;
                end
                accepted_rows <= accepted_rows + 1;
            end

            if (weight_rd_req_valid && weight_rd_req_ready) begin
                if (!slot_in_use[weight_rd_req_slot_id] ||
                    weight_rd_req_key !=
                        slot_weight_next[weight_rd_req_slot_id] ||
                    weight_rd_req_key > weight_rd_req_row ||
                    weight_rd_req_group !=
                        weight_rd_req_global_q_head[4:2])
                    $fatal(1, "full workload weight order/token mismatch");
                slot_weight_next[weight_rd_req_slot_id] <=
                    slot_weight_next[weight_rd_req_slot_id] + 1;
            end

            if (v_req_valid && v_req_ready) begin
                if (v_req_context_tag >= 12 ||
                    v_req_feature_block != v_req_context_tag[1:0] ||
                    v_req_key != context_v_next[v_req_context_tag])
                    $fatal(1, "full workload V context/key mismatch");
                context_v_next[v_req_context_tag] <=
                    context_v_next[v_req_context_tag] + 1;
            end

            if (mac_valid && mac_ready) begin
                if (mac_context_tag >= 12 ||
                    mac_key != context_mac_next[mac_context_tag] ||
                    mac_first != (mac_key == 0) ||
                    mac_last != (mac_key ==
                        dut.slot_row[mac_context_tag[3:2]]))
                    $fatal(1, "full workload MAC context/key mismatch");
                context_mac_next[mac_context_tag] <=
                    context_mac_next[mac_context_tag] + 1;
            end

            if (out_valid && out_ready) begin
                if (out_epoch != 16'd77 || out_seq != output_seq ||
                    out_global_q_head != output_seq / 128 ||
                    out_row != output_seq % 128 ||
                    out_feature_block != output_block ||
                    out_data_bf16 != {32{16'h3f80}} ||
                    out_row_last != (output_block == 3) ||
                    out_tensor_last !=
                        (output_seq == ROWS-1 && output_block == 3))
                    $fatal(1,
                        "full workload output mismatch seq=%0d block=%0d",
                        output_seq, output_block);
                if (output_block == 3) begin
                    output_block <= 0;
                    output_seq <= output_seq + 1;
                end else begin
                    output_block <= output_block + 1;
                end
            end

            if (weight_release_valid && weight_release_ready) begin
                if (weight_release_epoch != 16'd77 ||
                    weight_release_global_q_head != release_seq / 128 ||
                    weight_release_row != release_seq % 128 ||
                    weight_release_group != (release_seq / 128) / 4 ||
                    weight_release_slot_id != release_seq % 3 ||
                    weight_release_numeric_mode != release_seq % 2 ||
                    !slot_in_use[weight_release_slot_id])
                    $fatal(1, "full workload release mismatch seq=%0d",
                           release_seq);
                slot_in_use[weight_release_slot_id] <= 1'b0;
                release_seq <= release_seq + 1;
            end
        end
    end

    task automatic send_row(input integer row_sequence);
        integer slot;
        begin
            slot = row_sequence % 3;
            while (slot_in_use[slot])
                @(posedge clk);
            @(negedge clk);
            pv_row_valid = 1'b1;
            pv_row_epoch = 16'd77;
            pv_row_global_q_head = row_sequence / 128;
            pv_row_group = (row_sequence / 128) / 4;
            pv_row_row = row_sequence % 128;
            pv_row_slot_id = slot;
            pv_row_numeric_mode = row_sequence % 2;
            pv_row_sum_fp32 = 32'h3f80_0000;
            pv_row_inv_sum_fp32 = 32'h3f80_0000;
            do @(negedge clk); while (!pv_row_ready);
            pv_row_valid = 1'b0;
        end
    endtask

    integer row_sequence;
    integer timeout;
    initial begin
        pv_row_valid = 1'b0;
        pv_row_epoch = '0;
        pv_row_group = '0;
        pv_row_global_q_head = '0;
        pv_row_row = '0;
        pv_row_slot_id = '0;
        pv_row_numeric_mode = '0;
        pv_row_sum_fp32 = '0;
        pv_row_inv_sum_fp32 = '0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        for (row_sequence = 0; row_sequence < ROWS; row_sequence++)
            send_row(row_sequence);

        timeout = 0;
        while (rows_released != ROWS && timeout < 2000000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == 2000000)
            $fatal(1, "full workload timeout released=%0d", rows_released);
        if (pv_rows_accepted != ROWS ||
            weight_rd_requests != VALID_SCORES ||
            weight_rd_responses != VALID_SCORES ||
            weight_rd_consumes != VALID_SCORES ||
            v_requests != VECTORS || v_responses != VECTORS ||
            v_consumes != VECTORS || pv_mac_issue != PV_MACS ||
            pv_mac_result != PV_MACS || pv_mac_commit != PV_MACS ||
            context_words != CONTEXT_WORDS || rows_released != ROWS ||
            output_seq != ROWS || output_block != 0 ||
            release_seq != ROWS || protocol_error_count != 0 ||
            numeric_error_count != 0 || epoch_drop_count != 0 ||
            error_sticky)
            $fatal(1,
                "full counters rows=%0d w=%0d/%0d/%0d v=%0d/%0d/%0d pv=%0d/%0d/%0d out=%0d rel=%0d err=%0d/%0d/%0d",
                pv_rows_accepted, weight_rd_requests, weight_rd_responses,
                weight_rd_consumes, v_requests, v_responses, v_consumes,
                pv_mac_issue, pv_mac_result, pv_mac_commit, context_words,
                rows_released, protocol_error_count, numeric_error_count,
                epoch_drop_count);

        $display("PASS B3 full workload rows=%0d weights=%0d V=%0d PV_MAC=%0d Context=%0d releases=%0d output_stalls=%0d",
                 ROWS, VALID_SCORES, VECTORS, PV_MACS, CONTEXT_WORDS,
                 rows_released, output_stall_cycles);
        $finish;
    end

    initial begin
        #300000000;
        $fatal(1, "full workload global timeout");
    end
endmodule
