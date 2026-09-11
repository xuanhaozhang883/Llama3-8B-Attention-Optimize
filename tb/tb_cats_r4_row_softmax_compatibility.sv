`timescale 1ns/1ps

module tb_cats_r4_row_softmax_compatibility;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    always #5 clk = ~clk;

    logic row_valid;
    logic row_ready;
    logic [15:0] row_epoch;
    logic [3:0] row_context_tag;
    logic [4:0] row_global_q_head;
    logic [6:0] row_index;
    logic [7:0] row_key_count;
    logic [15:0] row_max_bf16;
    logic score_valid;
    logic score_ready;
    logic [15:0] score_epoch;
    logic [3:0] score_context_tag;
    logic [4:0] score_global_q_head;
    logic [6:0] score_row;
    logic [6:0] score_key;
    logic [15:0] score_bf16;
    logic score_mask;
    logic score_last;
    logic weight_valid;
    logic weight_ready;
    logic [15:0] weight_epoch;
    logic [3:0] weight_context_tag;
    logic [4:0] weight_global_q_head;
    logic [6:0] weight_row;
    logic [6:0] weight_key;
    logic [15:0] weight_bf16;
    logic weight_last;
    logic done_valid;
    logic done_ready;
    logic [15:0] done_epoch;
    logic [3:0] done_context_tag;
    logic [4:0] done_global_q_head;
    logic [6:0] done_row;
    logic [22:0] done_sum_q15;
    logic [30:0] done_reciprocal_q30;
    logic [31:0] done_reciprocal_fp32;
    logic done_error;
    logic [63:0] rows_issue;
    logic [63:0] rows_result;
    logic [63:0] rows_commit;
    logic [63:0] exp_issue;
    logic [63:0] exp_result;
    logic [63:0] exp_commit;
    logic [63:0] weight_issue;
    logic [63:0] weight_result;
    logic [63:0] weight_commit;
    logic [63:0] sum_issue;
    logic [63:0] sum_result;
    logic [63:0] sum_commit;
    logic [63:0] reciprocal_issue;
    logic [63:0] reciprocal_result;
    logic [63:0] reciprocal_commit;
    logic [63:0] output_stall_cycles;
    logic [63:0] reciprocal_busy_stall_cycles;
    logic [63:0] protocol_error_count;
    logic [63:0] numeric_special_count;
    logic protocol_error_sticky;

    integer cycles = 0;
    integer ready_seed = 32'h42B2C0DE;
    integer weight_count = 0;
    integer done_count = 0;
    logic post_clear_phase = 1'b0;
    logic weight_was_stalled = 1'b0;
    logic done_was_stalled = 1'b0;
    logic [64:0] held_weight;
    logic [159:0] held_weight_meta;
    logic [118:0] held_done;

    cats_r4_row_softmax_compatibility #(
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);

    task automatic send_row(
        input logic [15:0] epoch,
        input logic [3:0] tag,
        input logic [4:0] head,
        input logic [6:0] row_number,
        input logic [7:0] keys,
        input logic [15:0] maximum
    );
        begin
            @(negedge clk);
            row_epoch = epoch;
            row_context_tag = tag;
            row_global_q_head = head;
            row_index = row_number;
            row_key_count = keys;
            row_max_bf16 = maximum;
            row_valid = 1'b1;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 1'b0;
        end
    endtask

    task automatic send_score(
        input logic [15:0] epoch,
        input logic [3:0] tag,
        input logic [4:0] head,
        input logic [6:0] row_number,
        input logic [6:0] key_number,
        input logic [15:0] value,
        input logic is_last
    );
        begin
            @(negedge clk);
            score_epoch = epoch;
            score_context_tag = tag;
            score_global_q_head = head;
            score_row = row_number;
            score_key = key_number;
            score_bf16 = value;
            score_mask = 1'b0;
            score_last = is_last;
            score_valid = 1'b1;
            do @(posedge clk); while (!score_ready);
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            cycles <= 0;
            weight_ready <= 1'b0;
            done_ready <= 1'b0;
            weight_was_stalled <= 1'b0;
            done_was_stalled <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            // Deterministic sparse readiness guarantees multi-cycle stalls
            // while still making forward progress.
            weight_ready <= ((cycles % 4) == 3) &&
                            (($urandom(ready_seed) & 3) != 0);
            done_ready <= ((cycles % 5) == 4) &&
                          (($urandom(ready_seed) & 3) != 0);
            if (cycles > 3000)
                $fatal(1, "B2 compatibility timeout");

            if (weight_was_stalled) begin
                if (!weight_valid ||
                    {weight_bf16, weight_last, weight_key, weight_row,
                     weight_global_q_head, weight_context_tag, weight_epoch}
                    !== held_weight_meta)
                    $fatal(1, "weight payload changed while stalled");
            end
            weight_was_stalled <= weight_valid && !weight_ready;
            if (weight_valid && !weight_ready)
                held_weight_meta <=
                    {weight_bf16, weight_last, weight_key, weight_row,
                     weight_global_q_head, weight_context_tag, weight_epoch};

            if (done_was_stalled) begin
                if (!done_valid ||
                    {done_error, done_reciprocal_fp32,
                     done_reciprocal_q30, done_sum_q15, done_row,
                     done_global_q_head, done_context_tag, done_epoch}
                    !== held_done)
                    $fatal(1, "done payload changed while stalled");
            end
            done_was_stalled <= done_valid && !done_ready;
            if (done_valid && !done_ready)
                held_done <=
                    {done_error, done_reciprocal_fp32,
                     done_reciprocal_q30, done_sum_q15, done_row,
                     done_global_q_head, done_context_tag, done_epoch};

            if (weight_valid && weight_ready) begin
                if (weight_global_q_head !== 5'd0 ||
                    weight_bf16 !== 16'h3F80)
                    $fatal(1, "unexpected weight payload index=%0d", weight_count);
                if (post_clear_phase) begin
                    if (weight_epoch !== 16'd3 ||
                        weight_context_tag !== 0 || weight_row !== 0 ||
                        weight_key !== 0 || !weight_last)
                        $fatal(1, "post-clear weight metadata mismatch");
                end else begin
                    if (weight_epoch !== 16'd1)
                        $fatal(1, "pre-clear weight epoch mismatch");
                    case (weight_count)
                        0: if (weight_context_tag !== 0 || weight_row !== 3 ||
                               weight_key !== 0 || weight_last)
                            $fatal(1, "weight[0] metadata mismatch");
                        1: if (weight_context_tag !== 1 || weight_row !== 1 ||
                               weight_key !== 0 || weight_last)
                            $fatal(1, "weight[1] metadata mismatch");
                        2: if (weight_context_tag !== 0 || weight_row !== 3 ||
                               weight_key !== 1 || weight_last)
                            $fatal(1, "weight[2] metadata mismatch");
                        3: if (weight_context_tag !== 1 || weight_row !== 1 ||
                               weight_key !== 1 || !weight_last)
                            $fatal(1, "weight[3] metadata mismatch");
                        4: if (weight_context_tag !== 0 || weight_row !== 3 ||
                               weight_key !== 2 || weight_last)
                            $fatal(1, "weight[4] metadata mismatch");
                        5: if (weight_context_tag !== 0 || weight_row !== 3 ||
                               weight_key !== 3 || !weight_last)
                            $fatal(1, "weight[5] metadata mismatch");
                        default: $fatal(1, "unexpected extra weight");
                    endcase
                end
                weight_count <= weight_count + 1;
            end

            if (done_valid && done_ready) begin
                if (done_global_q_head !== 0 || done_error)
                    $fatal(1, "unexpected done token");
                if (post_clear_phase) begin
                    if (done_epoch !== 16'd3 || done_context_tag !== 0 ||
                        done_row !== 0 || done_sum_q15 !== 23'd32768 ||
                        done_reciprocal_q30 !== 31'd1073741824 ||
                        done_reciprocal_fp32 !== 32'h3F800000)
                        $fatal(1, "post-clear reciprocal mismatch");
                end else begin
                    if (done_epoch !== 16'd1)
                        $fatal(1, "pre-clear done epoch mismatch");
                    case (done_count)
                        0: begin
                            if (done_context_tag !== 1 || done_row !== 1 ||
                                done_sum_q15 !== 23'd65536 ||
                                done_reciprocal_q30 !== 31'd536870912 ||
                                done_reciprocal_fp32 !== 32'h3F000000)
                                $fatal(1, "row1 reciprocal mismatch");
                        end
                        1: begin
                            if (done_context_tag !== 0 || done_row !== 3 ||
                                done_sum_q15 !== 23'd131072 ||
                                done_reciprocal_q30 !== 31'd268435456 ||
                                done_reciprocal_fp32 !== 32'h3E800000)
                                $fatal(1, "row3 reciprocal mismatch");
                        end
                        default: $fatal(1, "unexpected extra done");
                    endcase
                end
                done_count <= done_count + 1;
            end
        end
    end

    initial begin
        row_valid = 1'b0;
        row_epoch = '0;
        row_context_tag = '0;
        row_global_q_head = '0;
        row_index = '0;
        row_key_count = '0;
        row_max_bf16 = '0;
        score_valid = 1'b0;
        score_epoch = '0;
        score_context_tag = '0;
        score_global_q_head = '0;
        score_row = '0;
        score_key = '0;
        score_bf16 = '0;
        score_mask = 1'b0;
        score_last = 1'b0;
        weight_ready = 1'b0;
        done_ready = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        send_row(1, 0, 0, 3, 4, 16'h3F80);
        send_row(1, 1, 0, 1, 2, 16'h3F80);
        send_score(1, 0, 0, 3, 0, 16'h3F80, 1'b0);
        send_score(1, 1, 0, 1, 0, 16'h3F80, 1'b0);
        send_score(1, 0, 0, 3, 1, 16'h3F80, 1'b0);
        send_score(1, 1, 0, 1, 1, 16'h3F80, 1'b1);
        send_score(1, 0, 0, 3, 2, 16'h3F80, 1'b0);
        send_score(1, 0, 0, 3, 3, 16'h3F80, 1'b1);

        wait (done_count == 2);
        repeat (3) @(posedge clk);
        if (weight_count != 6 || rows_issue != 2 || rows_result != 2 ||
            rows_commit != 2)
            $fatal(1, "row/weight closure mismatch");
        if (exp_issue != 6 || exp_result != 6 || exp_commit != 6 ||
            weight_issue != 6 || weight_result != 6 || weight_commit != 6 ||
            sum_issue != 6 || sum_result != 6 || sum_commit != 6)
            $fatal(1, "exp/weight/sum closure mismatch");
        if (reciprocal_issue != 2 || reciprocal_result != 2 ||
            reciprocal_commit != 2)
            $fatal(1, "reciprocal closure mismatch");
        if (protocol_error_sticky || protocol_error_count != 0 ||
            numeric_special_count != 0)
            $fatal(1, "unexpected error counters");
        if (output_stall_cycles == 0 || reciprocal_busy_stall_cycles == 0)
            $fatal(1, "backpressure paths were not exercised output=%0d reciprocal=%0d",
                   output_stall_cycles, reciprocal_busy_stall_cycles);
        $display("B2_INTERLEAVE_COUNTERS rows=%0d exp=%0d weight=%0d sum=%0d reciprocal=%0d output_stall=%0d reciprocal_stall=%0d",
                 rows_commit, exp_commit, weight_commit, sum_commit,
                 reciprocal_commit, output_stall_cycles,
                 reciprocal_busy_stall_cycles);

        // Reset/epoch recovery: clear all active state and counters, then reuse
        // context tag zero under a new epoch.
        weight_count = 0;
        done_count = 0;
        send_row(2, 0, 0, 0, 1, 16'h3F80);
        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        repeat (2) @(posedge clk);
        if (rows_issue != 0 || weight_valid || done_valid)
            $fatal(1, "clear did not reset state/counters");

        post_clear_phase = 1'b1;
        send_row(3, 0, 0, 0, 1, 16'h3F80);
        send_score(3, 0, 0, 0, 0, 16'h3F80, 1'b1);
        wait (done_count == 1);
        repeat (3) @(posedge clk);
        if (rows_issue != 1 || rows_result != 1 || rows_commit != 1 ||
            exp_issue != 1 || exp_result != 1 || exp_commit != 1 ||
            reciprocal_issue != 1 || reciprocal_result != 1 ||
            reciprocal_commit != 1 || protocol_error_sticky)
            $fatal(1, "post-clear closure mismatch");

        $display("CATS_R4_ROW_SOFTMAX_COMPATIBILITY_TEST: PASS post_clear_rows=%0d post_clear_exp=%0d",
                 rows_commit, exp_commit);
        $finish;
    end
endmodule
