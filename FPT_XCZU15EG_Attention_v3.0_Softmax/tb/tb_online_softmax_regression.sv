`timescale 1ns/1ps

module tb_online_softmax_regression;
    localparam int MAX_LEN = 8;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic in_valid, in_ready, in_last, in_mask;
    logic [15:0] in_data;
    logic [1:0] in_head;
    logic [2:0] in_row, in_col;
    logic out_valid, out_ready, out_first, out_last;
    logic [15:0] out_data;
    logic [1:0] out_head;
    logic [2:0] out_row, out_col;
    logic busy, row_error, metadata_error;

    integer cycle_count;
    integer errors;
    integer expected_kind;
    integer output_count;
    integer probability_sum_q15;
    logic row_complete;
    logic stalled_last_cycle;
    logic [15:0] stalled_data;
    logic [2:0] stalled_col;
    logic stalled_first, stalled_last;

    softmax_bf16 #(
        .MAX_LEN(MAX_LEN), .HEAD_W(2), .POS_W(3),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_data, .in_last, .in_mask,
        .in_head, .in_row, .in_col,
        .out_valid, .out_ready, .out_data, .out_first, .out_last,
        .out_head, .out_row, .out_col,
        .busy, .row_error, .metadata_error
    );

    function automatic integer bf16_probability_to_q15(input logic [15:0] value);
        integer significand;
        integer shift;
        begin
            if (value[14:7] == 0) begin
                bf16_probability_to_q15 = 0;
            end else begin
                significand = 128 + value[6:0];
                shift = value[14:7] - 119;
                if (shift >= 0)
                    bf16_probability_to_q15 = significand << shift;
                else
                    bf16_probability_to_q15 = significand >> (-shift);
            end
        end
    endfunction

    function automatic logic [15:0] increasing_score(input integer col);
        begin
            case (col)
                0: increasing_score = 16'h0000;
                1: increasing_score = 16'h3f80;
                2: increasing_score = 16'h4000;
                3: increasing_score = 16'h4040;
                4: increasing_score = 16'h4080;
                5: increasing_score = 16'h40a0;
                6: increasing_score = 16'h40c0;
                default: increasing_score = 16'h40e0;
            endcase
        end
    endfunction

    task automatic send_row(input integer kind, input logic [2:0] row_number);
        integer col;
        begin
            wait (!busy);
            expected_kind = kind;
            output_count = 0;
            probability_sum_q15 = 0;
            row_complete = 1'b0;
            for (col = 0; col < MAX_LEN; col = col + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_head = 2'd2;
                in_row = row_number;
                in_col = col[2:0];
                in_last = (col == MAX_LEN-1);
                case (kind)
                    0: begin
                        in_data = 16'h3f80;
                        in_mask = (col != 3);
                    end
                    1: begin
                        in_data = 16'h0000;
                        in_mask = (col > 1);
                    end
                    2: begin
                        in_data = increasing_score(col);
                        in_mask = 1'b1;
                    end
                    default: begin
                        in_data = increasing_score(col);
                        in_mask = 1'b0;
                    end
                endcase
                @(posedge clk);
                while (!in_ready)
                    @(posedge clk);
            end
            @(negedge clk);
            in_valid = 1'b0;
            in_last = 1'b0;
            wait (row_complete);
            @(posedge clk);
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n)
            out_ready = 1'b1;
        else
            out_ready = ((cycle_count % 5) != 2);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            stalled_last_cycle <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (stalled_last_cycle) begin
                if (!out_valid || out_data !== stalled_data || out_col !== stalled_col ||
                    out_first !== stalled_first || out_last !== stalled_last) begin
                    $display("ERROR: output changed while backpressured");
                    errors = errors + 1;
                end
            end
            stalled_last_cycle <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                stalled_data <= out_data;
                stalled_col <= out_col;
                stalled_first <= out_first;
                stalled_last <= out_last;
            end

            if (out_valid && out_ready) begin
                if (out_head != 2'd2 || out_col != output_count[2:0]) begin
                    $display("ERROR: metadata mismatch head=%0d col=%0d expected_col=%0d",
                             out_head, out_col, output_count);
                    errors = errors + 1;
                end
                if ((output_count == 0) != out_first ||
                    (output_count == MAX_LEN-1) != out_last) begin
                    $display("ERROR: boundary flag mismatch at output %0d", output_count);
                    errors = errors + 1;
                end

                case (expected_kind)
                    0: if (out_data !== ((output_count == 3) ? 16'h3f80 : 16'h0000)) begin
                        $display("ERROR: one-hot row col=%0d data=%h", output_count, out_data);
                        errors = errors + 1;
                    end
                    1: if (out_data !== ((output_count < 2) ? 16'h3f00 : 16'h0000)) begin
                        $display("ERROR: two-way row col=%0d data=%h", output_count, out_data);
                        errors = errors + 1;
                    end
                    2: begin
                        if (out_data !== 16'h0000 || !row_error) begin
                            $display("ERROR: all-masked row col=%0d data=%h row_error=%0b",
                                     output_count, out_data, row_error);
                            errors = errors + 1;
                        end
                    end
                    default: begin
                        if (row_error) begin
                            $display("ERROR: unexpected row_error on increasing row");
                            errors = errors + 1;
                        end
                    end
                endcase

                probability_sum_q15 = probability_sum_q15 +
                                      bf16_probability_to_q15(out_data);
                output_count = output_count + 1;
                if (out_last) begin
                    if (expected_kind != 2 &&
                        (probability_sum_q15 < 32000 || probability_sum_q15 > 33500)) begin
                        $display("ERROR: probability sum Q15=%0d", probability_sum_q15);
                        errors = errors + 1;
                    end
                    row_complete = 1'b1;
                end
            end
        end
    end

    initial begin
        in_valid = 1'b0;
        in_data = '0;
        in_last = 1'b0;
        in_mask = 1'b0;
        in_head = '0;
        in_row = '0;
        in_col = '0;
        out_ready = 1'b1;
        errors = 0;
        expected_kind = 0;
        output_count = 0;
        probability_sum_q15 = 0;
        row_complete = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        send_row(0, 3'd1);
        send_row(1, 3'd2);
        send_row(2, 3'd3);
        send_row(3, 3'd4);

        if (metadata_error) begin
            $display("ERROR: unexpected metadata_error");
            errors = errors + 1;
        end
        if (errors == 0)
            $display("ONLINE_SOFTMAX_REGRESSION: PASS");
        else
            $display("ONLINE_SOFTMAX_REGRESSION: FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        repeat (3000) @(posedge clk);
        $display("ONLINE_SOFTMAX_REGRESSION: TIMEOUT");
        $finish;
    end
endmodule
