`timescale 1ns/1ps

module tb_cats_r4_row_softmax_accuracy;
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
    logic weight_ready = 0;
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
    logic done_ready = 0;
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

    logic [31:0] expected_weight [0:9];
    logic [1:0] expected_weight_slot [0:9];
    logic [6:0] expected_weight_key [0:9];
    logic expected_weight_last [0:9];
    logic [31:0] expected_sum [0:4];
    logic [31:0] expected_inv [0:4];
    logic [1:0] expected_done_slot [0:4];
    logic expected_done_error [0:4];
    logic [3:0] expected_done_code [0:4];
    integer weight_count = 0;
    integer done_count = 0;
    integer ready_cycle = 0;

    always #5 clk = ~clk;

    cats_r4_row_softmax_accuracy dut (.*);

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1,
            "timeout weights=%0d done=%0d active=%b closing=%b row_vr=%0d%0d row_slot=%0d score_vr=%0d%0d score_slot=%0d exp_in=%0d%0d exp_out=%0d add_out=%0d recip_out=%0d",
            weight_count,done_count,dut.slot_active,dut.slot_closing,
            row_valid,row_ready,row_slot_id,score_valid,score_ready,score_slot_id,
            dut.exp_in_valid,dut.exp_in_ready,dut.exp_out_valid,
            dut.add_out_valid,dut.reciprocal_out_valid);
    end

    always @(negedge clk) begin
        ready_cycle = ready_cycle+1;
        weight_ready = (ready_cycle % 5) != 0;
        done_ready = (ready_cycle % 7) != 0;
    end

    always @(posedge clk) begin
        if (rst_n && !clear && weight_valid && weight_ready) begin
            if (weight_count >= 10)
                $fatal(1, "unexpected extra weight");
            if (weight_fp32 != expected_weight[weight_count] ||
                weight_slot_id != expected_weight_slot[weight_count] ||
                weight_key != expected_weight_key[weight_count] ||
                weight_last != expected_weight_last[weight_count] ||
                weight_numeric_mode != 2'd1)
                $fatal(1,
                    "weight mismatch index=%0d slot=%0d key=%0d data=%h last=%0d",
                    weight_count,weight_slot_id,weight_key,weight_fp32,weight_last);
            weight_count = weight_count+1;
        end
        if (rst_n && !clear && done_valid && done_ready) begin
            if (done_count >= 5)
                $fatal(1, "unexpected extra completion");
            if (done_slot_id != expected_done_slot[done_count] ||
                done_sum_fp32 != expected_sum[done_count] ||
                done_inv_sum_fp32 != expected_inv[done_count] ||
                done_error != expected_done_error[done_count] ||
                done_error_code != expected_done_code[done_count] ||
                done_numeric_mode != 2'd1)
                $fatal(1,
                    "done mismatch index=%0d slot=%0d sum=%h inv=%h error=%0d code=%0d",
                    done_count,done_slot_id,done_sum_fp32,
                    done_inv_sum_fp32,done_error,done_error_code);
            done_count = done_count+1;
        end
    end

    task automatic send_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [15:0] maximum
    );
        begin
            @(negedge clk);
            row_valid = 1'b1;
            row_epoch = epoch;
            row_group = head[4:2];
            row_global_q_head = head;
            row_index = row;
            row_slot_id = slot;
            row_numeric_mode = 2'd1;
            row_max_bf16 = maximum;
            do begin
                @(posedge clk);
            end while (!row_ready);
            @(negedge clk);
            row_valid = 1'b0;
        end
    endtask

    task automatic send_score(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [6:0] key,
        input logic [15:0] score,
        input logic last
    );
        begin
            @(negedge clk);
            score_valid = 1'b1;
            score_epoch = epoch;
            score_group = head[4:2];
            score_global_q_head = head;
            score_row = row;
            score_slot_id = slot;
            score_numeric_mode = 2'd1;
            score_key = key;
            score_bf16 = score;
            score_last = last;
            do begin
                @(posedge clk);
            end while (!score_ready);
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    initial begin
        expected_weight[0] = 32'h3F800000;
        expected_weight[1] = 32'h3F800000;
        expected_weight[2] = 32'h3F800000;
        expected_weight[3] = 32'h3F800000;
        expected_weight[4] = 32'h3EBC5C7D;
        expected_weight[5] = 32'h39016AF8;
        expected_weight[6] = 32'h00000000;
        expected_weight[7] = 32'h3F800000;
        expected_weight[8] = 32'h3F800000;
        expected_weight[9] = 32'h00000000;
        expected_weight_slot[0] = 0;
        expected_weight_slot[1] = 1;
        expected_weight_slot[2] = 1;
        expected_weight_slot[3] = 2;
        expected_weight_slot[4] = 2;
        expected_weight_slot[5] = 2;
        expected_weight_slot[6] = 2;
        expected_weight_slot[7] = 0;
        expected_weight_slot[8] = 0;
        expected_weight_slot[9] = 1;
        expected_weight_key[0] = 0;
        expected_weight_key[1] = 0;
        expected_weight_key[2] = 1;
        expected_weight_key[3] = 0;
        expected_weight_key[4] = 1;
        expected_weight_key[5] = 2;
        expected_weight_key[6] = 3;
        expected_weight_key[7] = 0;
        expected_weight_key[8] = 1;
        expected_weight_key[9] = 0;
        expected_weight_last[0] = 1;
        expected_weight_last[1] = 0;
        expected_weight_last[2] = 1;
        expected_weight_last[3] = 0;
        expected_weight_last[4] = 0;
        expected_weight_last[5] = 0;
        expected_weight_last[6] = 1;
        expected_weight_last[7] = 0;
        expected_weight_last[8] = 1;
        expected_weight_last[9] = 1;

        expected_done_slot[0] = 0;
        expected_sum[0] = 32'h3F800000;
        expected_inv[0] = 32'h3F800000;
        expected_done_error[0] = 0;
        expected_done_code[0] = 0;
        expected_done_slot[1] = 1;
        expected_sum[1] = 32'h40000000;
        expected_inv[1] = 32'h3F000000;
        expected_done_error[1] = 0;
        expected_done_code[1] = 0;
        expected_done_slot[2] = 2;
        expected_sum[2] = 32'h3FAF1B2A;
        expected_inv[2] = 32'h3F3B21DB;
        expected_done_error[2] = 0;
        expected_done_code[2] = 0;
        expected_done_slot[3] = 0;
        expected_sum[3] = 32'h40000000;
        expected_inv[3] = 32'h3F000000;
        expected_done_error[3] = 1;
        expected_done_code[3] = 1;
        expected_done_slot[4] = 1;
        expected_sum[4] = 32'h00000000;
        expected_inv[4] = 32'h00000000;
        expected_done_error[4] = 1;
        expected_done_code[4] = 2;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        send_row(16'h10,5'd0,7'd0,2'd0,16'h0000);
        send_row(16'h10,5'd1,7'd1,2'd1,16'h3F80);
        send_row(16'h10,5'd2,7'd3,2'd2,16'h0000);
        send_score(16'h10,5'd0,7'd0,2'd0,7'd0,16'h0000,1'b1);
        send_score(16'h10,5'd1,7'd1,2'd1,7'd0,16'h3F80,1'b0);
        send_score(16'h10,5'd1,7'd1,2'd1,7'd1,16'h3F80,1'b1);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd0,16'h0000,1'b0);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd1,16'hBF80,1'b0);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd2,16'hC110,1'b0);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd3,16'hC2D0,1'b1);
        wait (done_count == 3);

        // Wrong first last is drained to the expected row length and errors.
        send_row(16'h20,5'd0,7'd1,2'd0,16'h0000);
        send_score(16'h20,5'd0,7'd1,2'd0,7'd0,16'h0000,1'b1);
        send_score(16'h20,5'd0,7'd1,2'd0,7'd1,16'h0000,1'b1);
        wait (done_count == 4);

        // Non-finite row max/score is a numeric error, not a mode change.
        send_row(16'h30,5'd1,7'd0,2'd1,16'h7F80);
        send_score(16'h30,5'd1,7'd0,2'd1,7'd0,16'h7F80,1'b1);
        wait (done_count == 5);
        repeat (3) @(posedge clk);

        if (weight_count != 10 || rows_issue != 5 || rows_result != 5 ||
            rows_commit != 5 || exp_issue != 10 || exp_result != 10 ||
            exp_commit != 10 || sum_issue != 10 || sum_result != 10 ||
            sum_commit != 10 || reciprocal_issue != 5 ||
            reciprocal_result != 5 || reciprocal_commit != 5)
            $fatal(1,
                "counter closure rows=%0d/%0d/%0d exp=%0d/%0d/%0d sum=%0d/%0d/%0d recip=%0d/%0d/%0d",
                rows_issue,rows_result,rows_commit,
                exp_issue,exp_result,exp_commit,
                sum_issue,sum_result,sum_commit,
                reciprocal_issue,reciprocal_result,reciprocal_commit);
        if (protocol_error_count != 1 || numeric_error_count != 3 ||
            !error_sticky)
            $fatal(1, "error counters protocol=%0d numeric=%0d sticky=%0d",
                protocol_error_count,numeric_error_count,error_sticky);

        $display(
            "CATS-R4 Accuracy row core PASS rows=%0d weights=%0d protocol=%0d numeric=%0d exp_stall=%0d sum_stall=%0d",
            rows_commit,weight_count,protocol_error_count,numeric_error_count,
            exp_stall_cycles,sum_stall_cycles
        );
        $finish;
    end
endmodule
