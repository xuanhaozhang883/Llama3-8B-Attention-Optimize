`timescale 1ns/1ps

module tb_cats_r4_b3_pv_controller;
    localparam int JOBS = 64;

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

    logic pv_stalled, weight_stalled, v_stalled;
    logic out_stalled, release_stalled;
    logic [98:0] pv_hold_token;
    logic [41:0] weight_hold_payload;
    logic [12:0] v_hold_payload;
    logic [555:0] out_hold_payload;
    logic [34:0] release_hold_token;

    cats_r4_b3_pv_controller dut (.*);

    // Every externally visible ready/valid payload must remain stable while
    // stalled.  These checks cover input, service requests, Context output,
    // and the final weight release independently.
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            pv_stalled <= 0;
            weight_stalled <= 0;
            v_stalled <= 0;
            out_stalled <= 0;
            release_stalled <= 0;
        end else begin
            if (pv_stalled &&
                (!pv_row_valid ||
                 {pv_row_epoch,pv_row_group,pv_row_global_q_head,
                  pv_row_row,pv_row_slot_id,pv_row_numeric_mode,
                  pv_row_sum_fp32,pv_row_inv_sum_fp32} != pv_hold_token))
                $fatal(1, "stalled pv_row payload changed");
            if (weight_stalled &&
                (!weight_rd_req_valid ||
                 {weight_rd_req_epoch,weight_rd_req_group,
                  weight_rd_req_global_q_head,weight_rd_req_row,
                  weight_rd_req_slot_id,weight_rd_req_numeric_mode,
                  weight_rd_req_key} != weight_hold_payload))
                $fatal(1, "stalled weight request payload changed");
            if (v_stalled &&
                (!v_req_valid ||
                 {v_req_context_tag,v_req_key,v_req_feature_block} !=
                    v_hold_payload))
                $fatal(1, "stalled V request payload changed");
            if (out_stalled &&
                (!out_valid ||
                 {out_epoch,out_seq,out_global_q_head,out_row,
                  out_feature_block,out_data_bf16,out_row_last,
                  out_tensor_last} != out_hold_payload))
                $fatal(1, "stalled Context output payload changed");
            if (release_stalled &&
                (!weight_release_valid ||
                 {weight_release_epoch,weight_release_group,
                  weight_release_global_q_head,weight_release_row,
                  weight_release_slot_id,weight_release_numeric_mode} !=
                    release_hold_token))
                $fatal(1, "stalled release payload changed");

            pv_stalled <= pv_row_valid && !pv_row_ready;
            weight_stalled <= weight_rd_req_valid && !weight_rd_req_ready;
            v_stalled <= v_req_valid && !v_req_ready;
            out_stalled <= out_valid && !out_ready;
            release_stalled <= weight_release_valid &&
                               !weight_release_ready;
            if (pv_row_valid && !pv_row_ready)
                pv_hold_token <=
                    {pv_row_epoch,pv_row_group,pv_row_global_q_head,
                     pv_row_row,pv_row_slot_id,pv_row_numeric_mode,
                     pv_row_sum_fp32,pv_row_inv_sum_fp32};
            if (weight_rd_req_valid && !weight_rd_req_ready)
                weight_hold_payload <=
                    {weight_rd_req_epoch,weight_rd_req_group,
                     weight_rd_req_global_q_head,weight_rd_req_row,
                     weight_rd_req_slot_id,weight_rd_req_numeric_mode,
                     weight_rd_req_key};
            if (v_req_valid && !v_req_ready)
                v_hold_payload <=
                    {v_req_context_tag,v_req_key,v_req_feature_block};
            if (out_valid && !out_ready)
                out_hold_payload <=
                    {out_epoch,out_seq,out_global_q_head,out_row,
                     out_feature_block,out_data_bf16,out_row_last,
                     out_tensor_last};
            if (weight_release_valid && !weight_release_ready)
                release_hold_token <=
                    {weight_release_epoch,weight_release_group,
                     weight_release_global_q_head,weight_release_row,
                     weight_release_slot_id,weight_release_numeric_mode};
        end
    end

    logic [31:0] lfsr;
    integer input_seed;
    always_ff @(posedge clk) begin
        if (!rst_n || clear)
            lfsr <= 32'hb300_2026 ^ input_seed;
        else
            lfsr <= {lfsr[30:0],
                     lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    end

    logic w0_valid, w1_valid;
    logic [15:0] w0_epoch, w1_epoch;
    logic [2:0] w0_group, w1_group;
    logic [4:0] w0_head, w1_head;
    logic [6:0] w0_row, w1_row, w0_key, w1_key;
    logic [1:0] w0_slot, w1_slot, w0_mode, w1_mode;

    assign weight_rd_req_ready = lfsr[0] || lfsr[7];
    assign weight_rd_rsp_valid = w1_valid;
    assign weight_rd_rsp_epoch = w1_epoch;
    assign weight_rd_rsp_group = w1_group;
    assign weight_rd_rsp_global_q_head = w1_head;
    assign weight_rd_rsp_row = w1_row;
    assign weight_rd_rsp_slot_id = w1_slot;
    assign weight_rd_rsp_numeric_mode = w1_mode;
    assign weight_rd_rsp_key = w1_key;
    assign weight_rd_rsp_mask = 1'b0;
    assign weight_rd_rsp_data = w1_mode == 0 ?
                                32'h0000_3f80 : 32'h3f80_0000;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            w0_valid <= 0;
            w1_valid <= 0;
        end else begin
            w1_valid <= w0_valid;
            w1_epoch <= w0_epoch;
            w1_group <= w0_group;
            w1_head <= w0_head;
            w1_row <= w0_row;
            w1_slot <= w0_slot;
            w1_mode <= w0_mode;
            w1_key <= w0_key;
            w0_valid <= weight_rd_req_valid && weight_rd_req_ready;
            if (weight_rd_req_valid && weight_rd_req_ready) begin
                w0_epoch <= weight_rd_req_epoch;
                w0_group <= weight_rd_req_group;
                w0_head <= weight_rd_req_global_q_head;
                w0_row <= weight_rd_req_row;
                w0_slot <= weight_rd_req_slot_id;
                w0_mode <= weight_rd_req_numeric_mode;
                w0_key <= weight_rd_req_key;
            end
        end
    end

    logic vjob_active [0:JOBS-1];
    logic [3:0] vjob_context [0:JOBS-1];
    integer vjob_delay [0:JOBS-1];
    integer v_free, v_ready_job;
    integer model_index;

    always_comb begin
        v_free = -1;
        v_ready_job = -1;
        for (model_index = 0; model_index < JOBS; model_index++) begin
            if (v_free < 0 && !vjob_active[model_index])
                v_free = model_index;
            if (v_ready_job < 0 && vjob_active[model_index] &&
                vjob_delay[model_index] == 0)
                v_ready_job = model_index;
        end
    end
    assign v_req_ready = (lfsr[2] || lfsr[9]) && v_free >= 0;
    assign v_rsp_valid = v_ready_job >= 0;
    assign v_rsp_context_tag = v_ready_job >= 0 ?
                               vjob_context[v_ready_job] : 0;
    assign v_rsp_vec_bf16 = {32{16'h3f80}};

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            for (model_index = 0; model_index < JOBS; model_index++) begin
                vjob_active[model_index] <= 0;
                vjob_delay[model_index] <= 0;
            end
        end else begin
            for (model_index = 0; model_index < JOBS; model_index++)
                if (vjob_active[model_index] && vjob_delay[model_index] > 0)
                    vjob_delay[model_index] <= vjob_delay[model_index] - 1;
            if (v_rsp_valid)
                vjob_active[v_ready_job] <= 0;
            if (v_req_valid && v_req_ready) begin
                vjob_active[v_free] <= 1;
                vjob_context[v_free] <= v_req_context_tag;
                vjob_delay[v_free] <= 1 + lfsr[5:3];
            end
        end
    end

    logic macjob_active [0:JOBS-1];
    logic [3:0] macjob_context [0:JOBS-1];
    logic [6:0] macjob_key [0:JOBS-1];
    logic macjob_last [0:JOBS-1];
    integer macjob_delay [0:JOBS-1];
    integer mac_free, mac_ready_job;
    logic mac_hold_valid;
    logic [3:0] mac_hold_context;
    logic [6:0] mac_hold_key;
    logic mac_hold_last;

    always_comb begin
        mac_free = -1;
        mac_ready_job = -1;
        for (model_index = 0; model_index < JOBS; model_index++) begin
            if (mac_free < 0 && !macjob_active[model_index])
                mac_free = model_index;
            if (mac_ready_job < 0 && macjob_active[model_index] &&
                macjob_delay[model_index] == 0)
                mac_ready_job = model_index;
        end
    end
    assign mac_ready = (lfsr[4] || lfsr[11]) && mac_free >= 0;
    assign mac_rsp_valid = mac_hold_valid;
    assign mac_rsp_context_tag = mac_hold_context;
    assign mac_rsp_key = mac_hold_key;
    assign mac_rsp_last = mac_hold_last;
    assign mac_rsp_accum_fp32 = {32{32'h3f80_0000}};

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            mac_hold_valid <= 0;
            for (model_index = 0; model_index < JOBS; model_index++) begin
                macjob_active[model_index] <= 0;
                macjob_delay[model_index] <= 0;
            end
        end else begin
            for (model_index = 0; model_index < JOBS; model_index++)
                if (macjob_active[model_index] &&
                    macjob_delay[model_index] > 0)
                    macjob_delay[model_index] <=
                        macjob_delay[model_index] - 1;
            if (mac_hold_valid && mac_rsp_ready)
                mac_hold_valid <= 0;
            if (!mac_hold_valid && mac_ready_job >= 0) begin
                mac_hold_valid <= 1;
                mac_hold_context <= macjob_context[mac_ready_job];
                mac_hold_key <= macjob_key[mac_ready_job];
                mac_hold_last <= macjob_last[mac_ready_job];
                macjob_active[mac_ready_job] <= 0;
            end
            if (mac_valid && mac_ready) begin
                macjob_active[mac_free] <= 1;
                macjob_context[mac_free] <= mac_context_tag;
                macjob_key[mac_free] <= mac_key;
                macjob_last[mac_free] <= mac_last;
                macjob_delay[mac_free] <= 2 + lfsr[15:12];
                if (mac_first != (mac_key == 0))
                    $fatal(1, "mac first/key mismatch");
                if (mac_numeric_mode > 1)
                    $fatal(1, "illegal mode reached MAC");
            end
        end
    end

    logic normjob_active [0:JOBS-1];
    logic [3:0] normjob_context [0:JOBS-1];
    integer normjob_delay [0:JOBS-1];
    integer norm_free, norm_ready_job;

    always_comb begin
        norm_free = -1;
        norm_ready_job = -1;
        for (model_index = 0; model_index < JOBS; model_index++) begin
            if (norm_free < 0 && !normjob_active[model_index])
                norm_free = model_index;
            if (norm_ready_job < 0 && normjob_active[model_index] &&
                normjob_delay[model_index] == 0)
                norm_ready_job = model_index;
        end
    end
    assign norm_ready = (lfsr[6] || lfsr[17]) && norm_free >= 0;
    assign norm_rsp_valid = norm_ready_job >= 0;
    assign norm_rsp_context_tag = norm_ready_job >= 0 ?
                                  normjob_context[norm_ready_job] : 0;
    assign norm_rsp_context_bf16 =
        {32{16'h3f80 + {12'd0,norm_rsp_context_tag}}};

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            for (model_index = 0; model_index < JOBS; model_index++) begin
                normjob_active[model_index] <= 0;
                normjob_delay[model_index] <= 0;
            end
        end else begin
            for (model_index = 0; model_index < JOBS; model_index++)
                if (normjob_active[model_index] &&
                    normjob_delay[model_index] > 0)
                    normjob_delay[model_index] <=
                        normjob_delay[model_index] - 1;
            if (norm_rsp_valid && norm_rsp_ready)
                normjob_active[norm_ready_job] <= 0;
            if (norm_valid && norm_ready) begin
                normjob_active[norm_free] <= 1;
                normjob_context[norm_free] <= norm_context_tag;
                normjob_delay[norm_free] <= 1 + lfsr[20:18];
            end
        end
    end

    assign out_ready = lfsr[8] && lfsr[22];
    assign weight_release_ready = lfsr[10] && lfsr[23];

    integer expected_row [0:2];
    integer expected_head [0:2];
    integer output_row_index, output_block_index;
    logic [15:0] expected_lane;
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            output_row_index <= 0;
            output_block_index <= 0;
        end else if (out_valid && out_ready) begin
            if (out_epoch != 16'd9 ||
                out_global_q_head != expected_head[output_row_index] ||
                out_row != expected_row[output_row_index] ||
                out_feature_block != output_block_index ||
                out_seq != expected_head[output_row_index]*128 +
                           expected_row[output_row_index])
                $fatal(1, "output token/order mismatch row=%0d block=%0d",
                       output_row_index, output_block_index);
            expected_lane = 16'h3f80 +
                            (out_global_q_head == 0 ? output_block_index :
                             out_global_q_head*4 + output_block_index);
            if (out_data_bf16 != {32{expected_lane}})
                $fatal(1, "output data/context mismatch");
            if (out_row_last != (output_block_index == 3))
                $fatal(1, "row_last mismatch");
            if (out_tensor_last)
                $fatal(1, "unexpected tensor_last");
            if (output_block_index == 3) begin
                output_block_index <= 0;
                output_row_index <= output_row_index + 1;
            end else begin
                output_block_index <= output_block_index + 1;
            end
        end
    end

    task automatic send_row(
        input [4:0] head,
        input [6:0] row_value,
        input [1:0] slot,
        input [1:0] mode,
        input [31:0] sum,
        input [31:0] inv
    );
        begin
            @(negedge clk);
            pv_row_valid = 1;
            pv_row_epoch = 16'd9;
            pv_row_group = head[4:2];
            pv_row_global_q_head = head;
            pv_row_row = row_value;
            pv_row_slot_id = slot;
            pv_row_numeric_mode = mode;
            pv_row_sum_fp32 = sum;
            pv_row_inv_sum_fp32 = inv;
            do @(posedge clk); while (!pv_row_ready);
            @(negedge clk);
            pv_row_valid = 0;
        end
    endtask

    integer timeout;
    initial begin
        input_seed = 7;
        if (!$value$plusargs("SEED=%d", input_seed))
            input_seed = 7;
        pv_row_valid = 0;
        pv_row_epoch = 0;
        pv_row_group = 0;
        pv_row_global_q_head = 0;
        pv_row_row = 0;
        pv_row_slot_id = 0;
        pv_row_numeric_mode = 0;
        pv_row_sum_fp32 = 0;
        pv_row_inv_sum_fp32 = 0;
        expected_row[0] = 0;
        expected_row[1] = 1;
        expected_row[2] = 3;
        expected_head[0] = 0;
        expected_head[1] = 1;
        expected_head[2] = 2;

        repeat (5) @(posedge clk);
        rst_n = 1;

        // Abort a long row while weight/V work is in flight.  All local
        // services observe clear, so no old-epoch response may leak into the
        // following three-slot run.
        send_row(31, 127, 0, 1, 32'h4300_0000, 32'h3c00_0000);
        timeout = 0;
        while (v_requests < 4 && timeout < 1000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == 1000)
            $fatal(1, "timeout preparing mid-flight clear");
        @(negedge clk);
        clear = 1;
        repeat (2) @(negedge clk);
        clear = 0;
        @(posedge clk);
        if (pv_rows_accepted != 0 || weight_rd_requests != 0 ||
            v_requests != 0 || pv_mac_commit != 0 || context_words != 0 ||
            rows_released != 0 || error_sticky || weight_rd_req_valid ||
            v_req_valid || out_valid || weight_release_valid)
            $fatal(1, "mid-flight clear did not discard B3 state");

        send_row(0, 0, 0, 1, 32'h3f80_0000, 32'h3f80_0000);
        send_row(1, 1, 1, 0, 32'h4000_0000, 32'h3f00_0000);
        send_row(2, 3, 2, 1, 32'h4080_0000, 32'h3e80_0000);

        timeout = 0;
        while (rows_released != 3 && timeout < 20000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == 20000)
            $fatal(1, "timeout waiting for three PV rows");
        if (pv_rows_accepted != 3 || weight_rd_requests != 7 ||
            weight_rd_responses != 7 || weight_rd_consumes != 7 ||
            v_requests != 28 || v_responses != 28 || v_consumes != 28 ||
            pv_mac_issue != 896 || pv_mac_result != 896 ||
            pv_mac_commit != 896 || context_words != 384 ||
            rows_released != 3 || protocol_error_count != 0 ||
            numeric_error_count != 0 || epoch_drop_count != 0 ||
            error_sticky)
            $fatal(1,
                "counter mismatch rows=%0d w=%0d/%0d/%0d v=%0d/%0d/%0d pv=%0d/%0d/%0d out=%0d rel=%0d err=%0d/%0d/%0d",
                pv_rows_accepted, weight_rd_requests, weight_rd_responses,
                weight_rd_consumes, v_requests, v_responses, v_consumes,
                pv_mac_issue, pv_mac_result, pv_mac_commit, context_words,
                rows_released, protocol_error_count, numeric_error_count,
                epoch_drop_count);
        if (output_row_index != 3 || output_block_index != 0)
            $fatal(1, "output checker did not see three complete rows");

        $display("B3 protocol stress before counter_clear raw_stalls=%0d output_stalls=%0d",
                 raw_scoreboard_stalls, output_stall_cycles);

        @(negedge clk);
        counter_clear = 1;
        @(negedge clk);
        counter_clear = 0;
        @(posedge clk);
        if (pv_rows_accepted != 0 || pv_mac_commit != 0 ||
            context_words != 0 || error_sticky)
            $fatal(1, "counter_clear failed at quiescence");

        // counter_clear deliberately preserves transaction epoch ownership.
        // A stale row must be counted and rejected until global clear.
        @(negedge clk);
        pv_row_valid = 1;
        pv_row_epoch = 16'd10;
        pv_row_group = 0;
        pv_row_global_q_head = 0;
        pv_row_row = 0;
        pv_row_slot_id = 0;
        pv_row_numeric_mode = 1;
        pv_row_sum_fp32 = 32'h3f80_0000;
        pv_row_inv_sum_fp32 = 32'h3f80_0000;
        do @(posedge clk); while (!pv_row_ready);
        @(negedge clk);
        pv_row_valid = 0;
        @(posedge clk);
        if (!error_sticky || epoch_drop_count != 1 ||
            protocol_error_count != 0 || numeric_error_count != 0 ||
            pv_rows_accepted != 0)
            $fatal(1, "stale epoch row was not isolated");

        @(negedge clk);
        clear = 1;
        repeat (2) @(negedge clk);
        clear = 0;
        @(posedge clk);
        if (error_sticky || epoch_drop_count != 0 || !pv_row_ready)
            $fatal(1, "global clear did not recover stale epoch state");

        $display("PASS B3 PV controller seed=%0d rows=3 weights=7 v_vectors=28 pv_macs=896 context_words=384 midflight_clear=1 stale_epoch=1 payload_stability=1",
                 input_seed);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "global timeout");
    end
endmodule
