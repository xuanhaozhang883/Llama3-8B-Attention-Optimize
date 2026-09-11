`timescale 1ns/1ps

module tb_cats_r4_row_softmax_compatibility_numeric;
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
    logic weight_ready = 1'b1;
    logic [15:0] weight_epoch;
    logic [3:0] weight_context_tag;
    logic [4:0] weight_global_q_head;
    logic [6:0] weight_row;
    logic [6:0] weight_key;
    logic [15:0] weight_bf16;
    logic weight_last;
    logic done_valid;
    logic done_ready = 1'b1;
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

    logic [15:0] exp_mem [0:512];
    integer weight_count = 0;
    integer done_count = 0;
    integer cycle_count = 0;
    integer score_issue_count = 0;
    integer last_score_issue_cycle = -1;
    logic [22:0] expected_sum;
    logic [30:0] expected_reciprocal;

    initial $readmemh("mem/exp_lut_q15.mem", exp_mem);

    cats_r4_row_softmax_compatibility #(
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);

    function automatic logic [15:0] q15_to_bf16(
        input logic [15:0] q15_value
    );
        integer msb_index;
        integer shift_left;
        integer k;
        logic [31:0] normalized;
        logic [6:0] fraction7;
        logic [7:0] rounded_fraction;
        logic [7:0] exponent_biased;
        begin
            if (q15_value == 0) begin
                q15_to_bf16 = 0;
            end else begin
                msb_index = 0;
                for (k = 0; k < 16; k = k + 1)
                    if (q15_value[k]) msb_index = k;
                shift_left = 15-msb_index;
                exponent_biased = msb_index + 112;
                normalized = {16'd0, q15_value} << shift_left;
                fraction7 = normalized[14:8];
                rounded_fraction = {1'b0, fraction7};
                if (normalized[7] && (|normalized[6:0] || fraction7[0]))
                    rounded_fraction = rounded_fraction + 1'b1;
                if (rounded_fraction[7]) begin
                    exponent_biased = exponent_biased + 1'b1;
                    q15_to_bf16 = {1'b0, exponent_biased, 7'd0};
                end else begin
                    q15_to_bf16 = {1'b0, exponent_biased,
                                   rounded_fraction[6:0]};
                end
            end
        end
    endfunction

    task automatic send_score_burst;
        integer key_number;
        begin
            @(negedge clk);
            score_valid = 1'b1;
            for (key_number = 0; key_number < 3; key_number = key_number + 1) begin
                score_key = key_number[6:0];
                case (key_number)
                    0: score_bf16 = 16'h0000; // 0.0, delta=1
                    1: score_bf16 = 16'h3F80; // late +1.0 global max
                    default: score_bf16 = 16'hC100; // -8.0, delta=9
                endcase
                score_last = (key_number == 2);
                do @(posedge clk); while (!score_ready);
                if (key_number != 2)
                    @(negedge clk);
            end
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (rst_n && score_valid && score_ready) begin
            if (score_issue_count != 0 &&
                cycle_count != last_score_issue_cycle + 1)
                $fatal(1, "steady exp issue II exceeded one cycle");
            last_score_issue_cycle <= cycle_count;
            score_issue_count <= score_issue_count + 1;
        end
        if (rst_n && weight_valid && weight_ready) begin
            if (weight_epoch !== 7 || weight_context_tag !== 2 ||
                weight_global_q_head !== 5 || weight_row !== 2 ||
                weight_key !== weight_count)
                $fatal(1, "numeric weight metadata mismatch");
            case (weight_count)
                0: if (weight_bf16 !== q15_to_bf16(exp_mem[64]) || weight_last)
                    $fatal(1, "delta=1 weight mismatch");
                1: if (weight_bf16 !== 16'h3F80 || weight_last)
                    $fatal(1, "late global maximum weight mismatch");
                2: if (weight_bf16 !== 0 || !weight_last)
                    $fatal(1, "delta=9 cutoff mismatch");
                default: $fatal(1, "extra numeric weight");
            endcase
            weight_count <= weight_count + 1;
        end
        if (rst_n && done_valid && done_ready) begin
            if (done_epoch !== 7 || done_context_tag !== 2 ||
                done_global_q_head !== 5 || done_row !== 2 || done_error ||
                done_sum_q15 !== expected_sum ||
                done_reciprocal_q30 !== expected_reciprocal)
                $fatal(1, "numeric row completion mismatch");
            done_count <= done_count + 1;
        end
    end

    initial begin
        row_valid = 0;
        row_epoch = 7;
        row_context_tag = 2;
        row_global_q_head = 5;
        row_index = 2;
        row_key_count = 3;
        row_max_bf16 = 16'h3F80; // +1.0, supplied before the late maximum.
        score_valid = 0;
        score_epoch = 7;
        score_context_tag = 2;
        score_global_q_head = 5;
        score_row = 2;
        score_key = 0;
        score_bf16 = 0;
        score_mask = 0;
        score_last = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        expected_sum = exp_mem[64] + 23'd32768;
        expected_reciprocal = 46'd35184372088832 / expected_sum;

        @(negedge clk);
        row_valid = 1;
        do @(posedge clk); while (!row_ready);
        @(negedge clk);
        row_valid = 0;

        send_score_burst();

        wait (done_count == 1);
        repeat (3) @(posedge clk);
        if (weight_count != 3 || rows_issue != 1 || rows_result != 1 ||
            rows_commit != 1 || exp_issue != 3 || exp_result != 3 ||
            exp_commit != 3 || weight_issue != 3 || weight_result != 3 ||
            weight_commit != 3 || sum_issue != 3 || sum_result != 3 ||
            sum_commit != 3 || reciprocal_issue != 1 ||
            reciprocal_result != 1 || reciprocal_commit != 1 ||
            protocol_error_sticky || protocol_error_count != 0 ||
            score_issue_count != 3)
            $fatal(1, "numeric counter closure mismatch");
        $display("CATS_R4_ROW_SOFTMAX_COMPATIBILITY_NUMERIC_TEST: PASS sum=%0d reciprocal=%0d exp_issue_ii=1",
                 done_sum_q15, done_reciprocal_q30);
        $finish;
    end
endmodule
