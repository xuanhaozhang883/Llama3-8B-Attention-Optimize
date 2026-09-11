`timescale 1ns/1ps

// Three-row round-robin stream proving score/exp issue II=1 while preserving
// strict per-row key order.  The single iterative reciprocal intentionally
// serializes the three row endings; its busy counter must explain that tail.
module tb_cats_r4_row_softmax_accuracy_interleave;
    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic counter_clear = 0;
    logic row_valid = 0;
    logic row_ready;
    logic [15:0] row_epoch = 0;
    logic [2:0] row_group = 0;
    logic [4:0] row_global_q_head = 0;
    logic [6:0] row_index = 0;
    logic [1:0] row_slot_id = 0;
    logic [1:0] row_numeric_mode = 0;
    logic [15:0] row_max_bf16 = 0;
    logic score_valid = 0;
    logic score_ready;
    logic [15:0] score_epoch = 0;
    logic [2:0] score_group = 0;
    logic [4:0] score_global_q_head = 0;
    logic [6:0] score_row = 0;
    logic [1:0] score_slot_id = 0;
    logic [1:0] score_numeric_mode = 0;
    logic [6:0] score_key = 0;
    logic [15:0] score_bf16 = 0;
    logic score_last = 0;
    logic weight_valid;
    logic weight_ready = 1;
    logic [15:0] weight_epoch;
    logic [2:0] weight_group;
    logic [4:0] weight_global_q_head;
    logic [6:0] weight_row;
    logic [1:0] weight_slot_id;
    logic [1:0] weight_numeric_mode;
    logic [6:0] weight_key;
    logic [31:0] weight_fp32;
    logic weight_last;
    logic done_valid;
    logic done_ready = 1;
    logic [15:0] done_epoch;
    logic [2:0] done_group;
    logic [4:0] done_global_q_head;
    logic [6:0] done_row;
    logic [1:0] done_slot_id;
    logic [1:0] done_numeric_mode;
    logic [31:0] done_sum_fp32;
    logic [31:0] done_inv_sum_fp32;
    logic done_error;
    logic [3:0] done_error_code;
    logic [6:0] done_bad_key;
    logic [63:0] rows_issue;
    logic [63:0] rows_result;
    logic [63:0] rows_commit;
    logic [63:0] exp_issue;
    logic [63:0] exp_result;
    logic [63:0] exp_commit;
    logic [63:0] sum_issue;
    logic [63:0] sum_result;
    logic [63:0] sum_commit;
    logic [63:0] reciprocal_issue;
    logic [63:0] reciprocal_result;
    logic [63:0] reciprocal_commit;
    logic [63:0] protocol_error_count;
    logic [63:0] numeric_error_count;
    logic [63:0] exp_stall_cycles;
    logic [63:0] sum_stall_cycles;
    logic [63:0] reciprocal_busy_stall_cycles;
    logic [63:0] reciprocal_output_stall_cycles;
    logic error_sticky;

    integer cycle_count = 0;
    integer score_count = 0;
    integer weight_count = 0;
    integer done_count = 0;
    integer first_score_cycle = -1;
    integer last_score_cycle = -1;
    logic measure_enable = 0;
    logic post_clear = 0;

    always #5 clk = ~clk;
    cats_r4_row_softmax_accuracy dut (.*);

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "timeout scores=%0d weights=%0d done=%0d",
            score_count, weight_count, done_count);
    end

    always @(posedge clk) begin
        integer expected_slot;
        integer expected_key;
        if (rst_n)
            cycle_count = cycle_count + 1;
        if (post_clear && weight_valid && weight_epoch == 16'hDEAD)
            $fatal(1, "old-epoch weight escaped after clear");
        if (post_clear && done_valid && done_epoch == 16'hDEAD)
            $fatal(1, "old-epoch completion escaped after clear");
        if (rst_n && measure_enable && score_valid && score_ready) begin
            if (first_score_cycle < 0)
                first_score_cycle = cycle_count;
            last_score_cycle = cycle_count;
            score_count = score_count + 1;
        end
        if (rst_n && measure_enable && weight_valid && weight_ready) begin
            expected_slot = weight_count % 3;
            expected_key = weight_count / 3;
            if (weight_epoch != 16'h1EAF ||
                weight_global_q_head != expected_slot ||
                weight_row != 127 || weight_slot_id != expected_slot ||
                weight_numeric_mode != 1 || weight_key != expected_key ||
                weight_fp32 != 32'h3F800000 ||
                weight_last != (expected_key == 127))
                $fatal(1,
                    "interleave weight mismatch n=%0d slot=%0d key=%0d data=%h",
                    weight_count, weight_slot_id, weight_key, weight_fp32);
            weight_count = weight_count + 1;
        end
        if (rst_n && measure_enable && done_valid && done_ready) begin
            if (done_slot_id != done_count || done_global_q_head != done_count ||
                done_row != 127 || done_numeric_mode != 1 || done_error ||
                done_error_code != 0 || done_sum_fp32 != 32'h43000000 ||
                done_inv_sum_fp32 != 32'h3C000000)
                $fatal(1,
                    "interleave done mismatch n=%0d slot=%0d sum=%h inv=%h error=%0d",
                    done_count, done_slot_id, done_sum_fp32,
                    done_inv_sum_fp32, done_error);
            done_count = done_count + 1;
        end
    end

    task automatic send_row(input integer slot);
        begin
            @(negedge clk);
            row_valid = 1;
            row_epoch = 16'h1EAF;
            row_group = 0;
            row_global_q_head = slot;
            row_index = 127;
            row_slot_id = slot;
            row_numeric_mode = 1;
            row_max_bf16 = 16'h0000;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 0;
        end
    endtask

    initial begin
        integer item;
        integer slot;
        integer key;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // Clear a partially consumed old-epoch row, then prove that neither
        // its weight nor completion can appear in the new epoch.
        @(negedge clk);
        row_valid = 1;
        row_epoch = 16'hDEAD;
        row_group = 0;
        row_global_q_head = 0;
        row_index = 127;
        row_slot_id = 0;
        row_numeric_mode = 1;
        row_max_bf16 = 0;
        do @(posedge clk); while (!row_ready);
        @(negedge clk);
        row_valid = 0;
        score_valid = 1;
        score_epoch = 16'hDEAD;
        score_group = 0;
        score_global_q_head = 0;
        score_row = 127;
        score_slot_id = 0;
        score_numeric_mode = 1;
        score_key = 0;
        score_bf16 = 0;
        score_last = 0;
        do @(posedge clk); while (!score_ready);
        @(negedge clk);
        score_valid = 0;
        clear = 1;
        @(posedge clk);
        @(negedge clk);
        clear = 0;
        counter_clear = 1;
        @(posedge clk);
        @(negedge clk);
        counter_clear = 0;
        post_clear = 1;
        repeat (3) @(posedge clk);
        if (weight_valid || done_valid || dut.slot_active != 0)
            $fatal(1, "clear did not discard partial row state");
        measure_enable = 1;

        send_row(0);
        send_row(1);
        send_row(2);

        for (item = 0; item < 384; item = item + 1) begin
            slot = item % 3;
            key = item / 3;
            @(negedge clk);
            score_valid = 1;
            score_epoch = 16'h1EAF;
            score_group = 0;
            score_global_q_head = slot;
            score_row = 127;
            score_slot_id = slot;
            score_numeric_mode = 1;
            score_key = key;
            score_bf16 = 16'h0000;
            score_last = key == 127;
            do @(posedge clk); while (!score_ready);
        end
        @(negedge clk);
        score_valid = 0;

        wait (done_count == 3);
        repeat (3) @(posedge clk);
        if (score_count != 384 || weight_count != 384 ||
            rows_issue != 3 || rows_result != 3 || rows_commit != 3 ||
            exp_issue != 384 || exp_result != 384 || exp_commit != 384 ||
            sum_issue != 384 || sum_result != 384 || sum_commit != 384 ||
            reciprocal_issue != 3 || reciprocal_result != 3 ||
            reciprocal_commit != 3)
            $fatal(1,
                "interleave counter closure scores=%0d weights=%0d rows=%0d/%0d/%0d exp=%0d/%0d/%0d sum=%0d/%0d/%0d reciprocal=%0d/%0d/%0d",
                score_count, weight_count, rows_issue, rows_result,
                rows_commit, exp_issue, exp_result, exp_commit,
                sum_issue, sum_result, sum_commit, reciprocal_issue,
                reciprocal_result, reciprocal_commit);
        if (last_score_cycle - first_score_cycle != 383)
            $fatal(1,
                "score issue did not sustain II=1 first=%0d last=%0d count=%0d",
                first_score_cycle, last_score_cycle, score_count);
        if (protocol_error_count != 0 || numeric_error_count != 0 ||
            error_sticky || reciprocal_busy_stall_cycles == 0)
            $fatal(1,
                "interleave error/stall mismatch protocol=%0d numeric=%0d sticky=%0d reciprocal_busy=%0d",
                protocol_error_count, numeric_error_count, error_sticky,
                reciprocal_busy_stall_cycles);

        $display(
            "CATS-R4 Accuracy interleave PASS rows=%0d scores=%0d issue_span=%0d II=1 reciprocal_busy_stalls=%0d exp_stalls=%0d sum_stalls=%0d",
            rows_commit, score_count, last_score_cycle-first_score_cycle,
            reciprocal_busy_stall_cycles, exp_stall_cycles, sum_stall_cycles);
        $finish;
    end
endmodule
