`timescale 1ns/1ps

// Full-length, continuous-row vector dumper.  The archive comparison script
// runs this same testbench once with the archived Softmax and once with the
// corrected implementation, then compares every transferred output bitwise.
module tb_softmax_equivalence_full_rows;
    localparam int MAX_LEN = 128;
    localparam int ROWS = 8;
    localparam int EXPECTED_OUTPUTS = MAX_LEN * ROWS;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic in_valid, in_ready, in_last, in_mask;
    logic [15:0] in_data;
    logic [1:0] in_head;
    logic [6:0] in_row, in_col;
    logic out_valid, out_ready, out_first, out_last;
    logic [15:0] out_data;
    logic [1:0] out_head;
    logic [6:0] out_row, out_col;
    logic busy, row_error, metadata_error;

    integer errors;
    integer output_count;
    integer expected_row;
    integer expected_col;

    softmax_bf16 #(
        .MAX_LEN(MAX_LEN), .HEAD_W(2), .POS_W(7),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_data, .in_last, .in_mask,
        .in_head, .in_row, .in_col,
        .out_valid, .out_ready, .out_data, .out_first, .out_last,
        .out_head, .out_row, .out_col,
        .busy, .row_error, .metadata_error
    );

    function automatic logic [15:0] ordered_score(input integer index);
        begin
            case (index & 15)
                0: ordered_score = 16'hc080;
                1: ordered_score = 16'hc040;
                2: ordered_score = 16'hc000;
                3: ordered_score = 16'hbf80;
                4: ordered_score = 16'hbf00;
                5: ordered_score = 16'h0000;
                6: ordered_score = 16'h3e80;
                7: ordered_score = 16'h3f00;
                8: ordered_score = 16'h3f40;
                9: ordered_score = 16'h3f80;
                10: ordered_score = 16'h3fc0;
                11: ordered_score = 16'h4000;
                12: ordered_score = 16'h4020;
                13: ordered_score = 16'h4040;
                14: ordered_score = 16'h4060;
                default: ordered_score = 16'h4080;
            endcase
        end
    endfunction

    function automatic logic [15:0] score_for(
        input integer row_number,
        input integer col_number
    );
        integer index;
        begin
            case (row_number)
                0: index = col_number;
                1: index = 15 - col_number;
                2: index = col_number * 5 + 3;
                3: index = col_number[0] ? 13 : 3;
                4: index = 9;
                5: index = col_number * 11 + (col_number >> 2) + row_number;
                6: index = (col_number == 1 || col_number == 126) ? 15 :
                           (col_number * 7 + 2);
                default: index = col_number * 13 + (col_number >> 1) + 5;
            endcase
            score_for = ordered_score(index);
        end
    endfunction

    function automatic logic mask_for(
        input integer row_number,
        input integer col_number
    );
        begin
            case (row_number)
                0: mask_for = 1'b0;
                1: mask_for = ((col_number % 3) == 0);
                2: mask_for = (col_number > 2);
                3: mask_for = col_number[0];
                4: mask_for = !((col_number == 0) ||
                                (col_number == 7) ||
                                (col_number == 127));
                5: mask_for = 1'b0;
                6: mask_for = ((col_number % 5) == 0);
                default: mask_for = (col_number > 63);
            endcase
        end
    endfunction

    task automatic send_beat(input integer row_number, input integer col_number);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_data = score_for(row_number, col_number);
            in_last = (col_number == MAX_LEN-1);
            in_mask = mask_for(row_number, col_number);
            in_head = row_number[1:0];
            in_row = row_number[6:0];
            in_col = col_number[6:0];
            @(posedge clk);
            while (!in_ready)
                @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            expected_row = output_count / MAX_LEN;
            expected_col = output_count % MAX_LEN;
            $display("EQ_FULL r=%0d c=%0d data=%04h first=%0b last=%0b row_error=%0b metadata_error=%0b",
                     out_row, out_col, out_data, out_first, out_last,
                     row_error, metadata_error);
            if (out_head !== expected_row[1:0] ||
                out_row !== expected_row[6:0] ||
                out_col !== expected_col[6:0]) begin
                $display("ERROR: full equivalence metadata mismatch at output %0d",
                         output_count);
                errors = errors + 1;
            end
            if (out_first !== (expected_col == 0) ||
                out_last !== (expected_col == MAX_LEN-1) ||
                row_error || metadata_error) begin
                $display("ERROR: full equivalence status mismatch at output %0d",
                         output_count);
                errors = errors + 1;
            end
            if (mask_for(expected_row, expected_col) && out_data !== 16'h0000) begin
                $display("ERROR: masked output is nonzero at output %0d", output_count);
                errors = errors + 1;
            end
            output_count = output_count + 1;
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
        output_count = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        for (integer row_number = 0; row_number < ROWS; row_number = row_number + 1)
            for (integer col_number = 0; col_number < MAX_LEN; col_number = col_number + 1)
                send_beat(row_number, col_number);

        @(negedge clk);
        in_valid = 1'b0;
        in_last = 1'b0;
        wait (output_count == EXPECTED_OUTPUTS);
        repeat (2) @(posedge clk);

        if (errors == 0)
            $display("EQ_FULL_TEST: PASS outputs=%0d", output_count);
        else
            $display("EQ_FULL_TEST: FAIL errors=%0d outputs=%0d", errors, output_count);
        $finish;
    end

    initial begin
        repeat (50000) @(posedge clk);
        $display("EQ_FULL_TEST: TIMEOUT outputs=%0d", output_count);
        $finish;
    end
endmodule
