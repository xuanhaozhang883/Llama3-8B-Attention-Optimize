`timescale 1ns/1ps

// Deterministic vector dumper used to compare the archived serial Softmax
// against the interface-compatible Online Softmax implementation.
module tb_softmax_equivalence_vectors;
    localparam int MAX_LEN = 16;
    localparam int ROWS = 6;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic in_valid, in_ready, in_last, in_mask;
    logic [15:0] in_data;
    logic [1:0] in_head;
    logic [3:0] in_row, in_col;
    logic out_valid, out_ready, out_first, out_last;
    logic [15:0] out_data;
    logic [1:0] out_head;
    logic [3:0] out_row, out_col;
    logic busy, row_error, metadata_error;

    integer errors;
    integer expected_row;
    integer expected_col;
    logic row_complete;

    softmax_bf16 #(
        .MAX_LEN(MAX_LEN), .HEAD_W(2), .POS_W(4),
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
            case (index)
                0:  ordered_score = 16'hc080; // -4.00
                1:  ordered_score = 16'hc040; // -3.00
                2:  ordered_score = 16'hc000; // -2.00
                3:  ordered_score = 16'hbf80; // -1.00
                4:  ordered_score = 16'hbf00; // -0.50
                5:  ordered_score = 16'h0000; //  0.00
                6:  ordered_score = 16'h3e80; //  0.25
                7:  ordered_score = 16'h3f00; //  0.50
                8:  ordered_score = 16'h3f40; //  0.75
                9:  ordered_score = 16'h3f80; //  1.00
                10: ordered_score = 16'h3fc0; //  1.50
                11: ordered_score = 16'h4000; //  2.00
                12: ordered_score = 16'h4020; //  2.50
                13: ordered_score = 16'h4040; //  3.00
                14: ordered_score = 16'h4060; //  3.50
                default: ordered_score = 16'h4080; // 4.00
            endcase
        end
    endfunction

    function automatic logic [15:0] score_for(
        input integer row_number,
        input integer col_number
    );
        integer mixed_index;
        begin
            case (row_number)
                0: score_for = ordered_score(col_number);
                1: score_for = ordered_score(MAX_LEN - 1 - col_number);
                2: begin
                    mixed_index = (col_number * 5 + 3) % MAX_LEN;
                    score_for = ordered_score(mixed_index);
                end
                3: score_for = (col_number[0]) ? 16'h4040 : 16'hbf80;
                4: score_for = 16'h3f80;
                default: begin
                    case (col_number)
                        0: score_for = 16'h4080;
                        1: score_for = 16'hc080;
                        2: score_for = 16'h4000;
                        3: score_for = 16'hbf00;
                        4: score_for = 16'h40a0;
                        5: score_for = 16'hc000;
                        6: score_for = 16'h3f00;
                        7: score_for = 16'h4040;
                        8: score_for = 16'h0000;
                        9: score_for = 16'h40c0;
                        10: score_for = 16'hbf80;
                        11: score_for = 16'h4020;
                        12: score_for = 16'h3f80;
                        13: score_for = 16'hc040;
                        14: score_for = 16'h4060;
                        default: score_for = 16'h3e80;
                    endcase
                end
            endcase
        end
    endfunction

    function automatic logic mask_for(
        input integer row_number,
        input integer col_number
    );
        begin
            case (row_number)
                2: mask_for = ((col_number % 3) == 0);
                4: mask_for = col_number[0];
                5: mask_for = (col_number == 0) ||
                              (col_number == 7) ||
                              (col_number == 15);
                default: mask_for = 1'b0;
            endcase
        end
    endfunction

    task automatic send_row(input integer row_number);
        integer col_number;
        begin
            wait (!busy);
            expected_row = row_number;
            expected_col = 0;
            row_complete = 1'b0;
            for (col_number = 0; col_number < MAX_LEN; col_number = col_number + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data = score_for(row_number, col_number);
                in_last = (col_number == MAX_LEN - 1);
                in_mask = mask_for(row_number, col_number);
                in_head = 2'd1;
                in_row = row_number[3:0];
                in_col = col_number[3:0];
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

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            $display("EQ_VECTOR r=%0d c=%0d data=%04h first=%0b last=%0b",
                     out_row, out_col, out_data, out_first, out_last);
            if (out_head != 2'd1 || out_row != expected_row[3:0] ||
                out_col != expected_col[3:0]) begin
                $display("ERROR: equivalence metadata mismatch");
                errors = errors + 1;
            end
            if ((expected_col == 0) != out_first ||
                (expected_col == MAX_LEN - 1) != out_last) begin
                $display("ERROR: equivalence boundary mismatch");
                errors = errors + 1;
            end
            if (mask_for(expected_row, expected_col) && out_data !== 16'h0000) begin
                $display("ERROR: masked output is nonzero");
                errors = errors + 1;
            end
            expected_col = expected_col + 1;
            if (out_last)
                row_complete = 1'b1;
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
        expected_row = 0;
        expected_col = 0;
        row_complete = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        for (integer row_number = 0; row_number < ROWS; row_number = row_number + 1)
            send_row(row_number);

        if (row_error || metadata_error) begin
            $display("ERROR: unexpected DUT status row_error=%0b metadata_error=%0b",
                     row_error, metadata_error);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("EQ_VECTOR_TEST: PASS");
        else
            $display("EQ_VECTOR_TEST: FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $display("EQ_VECTOR_TEST: TIMEOUT");
        $finish;
    end
endmodule
