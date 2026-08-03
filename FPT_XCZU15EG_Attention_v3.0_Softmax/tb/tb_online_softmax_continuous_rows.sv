`timescale 1ns/1ps

module tb_online_softmax_continuous_rows;
    localparam int ROW_LEN = 128;
    localparam int ROWS = 4;
    localparam int TOTAL_BEATS = ROW_LEN * ROWS;

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

    integer cycles;
    integer input_count;
    integer output_count;
    logic feeding, launch;
    logic stalled_last_cycle;
    logic [15:0] stalled_data;
    logic [1:0] stalled_head;
    logic [6:0] stalled_row, stalled_col;
    logic stalled_first, stalled_last;

    assign in_valid = feeding;
    assign in_data = 16'h0000;
    assign in_mask = 1'b0;
    assign in_last = (in_col == ROW_LEN-1);

    softmax_bf16 #(
        .MAX_LEN(ROW_LEN), .HEAD_W(2), .POS_W(7),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_data, .in_last, .in_mask,
        .in_head, .in_row, .in_col,
        .out_valid, .out_ready, .out_data, .out_first, .out_last,
        .out_head, .out_row, .out_col,
        .busy, .row_error, .metadata_error
    );

    always @(negedge clk) begin
        if (!rst_n)
            out_ready = 1'b1;
        else
            out_ready = !((cycles % 31) >= 7 && (cycles % 31) <= 15);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cycles <= 0;
            input_count <= 0;
            output_count <= 0;
            feeding <= 1'b0;
            in_head <= 2'd2;
            in_row <= '0;
            in_col <= '0;
            stalled_last_cycle <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            if (launch)
                feeding <= 1'b1;

            if (stalled_last_cycle) begin
                if (!out_valid || out_data !== stalled_data ||
                    out_head !== stalled_head || out_row !== stalled_row ||
                    out_col !== stalled_col || out_first !== stalled_first ||
                    out_last !== stalled_last)
                    $fatal(1, "Output changed while backpressured");
            end
            stalled_last_cycle <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                stalled_data <= out_data;
                stalled_head <= out_head;
                stalled_row <= out_row;
                stalled_col <= out_col;
                stalled_first <= out_first;
                stalled_last <= out_last;
            end

            if (metadata_error)
                $fatal(1, "metadata_error after input=%0d output=%0d", input_count, output_count);
            if (row_error)
                $fatal(1, "Unexpected row_error");

            if (in_valid && in_ready) begin
                input_count <= input_count + 1;
                if (in_col == ROW_LEN-1) begin
                    in_col <= '0;
                    if (in_row == ROWS-1)
                        feeding <= 1'b0;
                    else
                        in_row <= in_row + 1'b1;
                end else begin
                    in_col <= in_col + 1'b1;
                end
            end

            if (out_valid && out_ready) begin
                if (out_head != 2'd2 ||
                    out_row != (output_count / ROW_LEN) ||
                    out_col != (output_count % ROW_LEN) ||
                    out_first != ((output_count % ROW_LEN) == 0) ||
                    out_last != ((output_count % ROW_LEN) == ROW_LEN-1))
                    $fatal(1, "Output metadata mismatch at beat %0d: h/r/c=%0d/%0d/%0d first/last=%0b/%0b",
                           output_count, out_head, out_row, out_col,
                           out_first, out_last);

                output_count <= output_count + 1;
                if (output_count == TOTAL_BEATS-1) begin
                    if (input_count != TOTAL_BEATS)
                        $fatal(1, "Input count mismatch: %0d", input_count);
                    $display("CONTINUOUS_ROWS_TEST: PASS input=%0d output=%0d",
                             input_count, output_count + 1);
                    $finish;
                end
            end

            if (cycles > 1000000)
                $fatal(1, "Continuous-row timeout input=%0d output=%0d",
                       input_count, output_count);
        end
    end

    initial begin
        out_ready = 1'b1;
        launch = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        launch = 1'b1;
        @(negedge clk);
        launch = 1'b0;
    end
endmodule
