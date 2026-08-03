`timescale 1ns/1ps

module tb_softmax_online;
    localparam int MAX_LEN = 128;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic in_valid;
    logic in_ready;
    logic [15:0] in_data;
    logic in_last;
    logic in_mask;
    logic [1:0] in_head;
    logic [6:0] in_row;
    logic [6:0] in_col;

    logic out_valid;
    logic out_ready;
    logic [15:0] out_data;
    logic out_first;
    logic out_last;
    logic [1:0] out_head;
    logic [6:0] out_row;
    logic [6:0] out_col;
    logic busy;
    logic row_error;
    logic metadata_error;

    integer cycle_count;
    integer first_input_cycle;
    integer last_output_cycle;
    integer input_count;
    integer output_count;
    integer errors;

    softmax_bf16 #(
        .MAX_LEN(MAX_LEN),
        .HEAD_W(2),
        .POS_W(7),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_data, .in_last, .in_mask,
        .in_head, .in_row, .in_col,
        .out_valid, .out_ready, .out_data, .out_first, .out_last,
        .out_head, .out_row, .out_col,
        .busy, .row_error, .metadata_error
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            input_count <= 0;
            output_count <= 0;
            first_input_cycle <= -1;
            last_output_cycle <= -1;
        end else begin
            cycle_count <= cycle_count + 1;
            if (in_valid && in_ready) begin
                if (input_count == 0)
                    first_input_cycle <= cycle_count;
                input_count <= input_count + 1;
            end
            if (out_valid && out_ready) begin
                if (out_data !== 16'h3c00) begin
                    $display("ERROR: col=%0d probability=%h expected=3c00", out_col, out_data);
                    errors <= errors + 1;
                end
                if (out_col !== output_count[6:0]) begin
                    $display("ERROR: output column=%0d expected=%0d", out_col, output_count);
                    errors <= errors + 1;
                end
                if ((output_count == 0) != out_first) begin
                    $display("ERROR: out_first mismatch at col=%0d", output_count);
                    errors <= errors + 1;
                end
                if ((output_count == MAX_LEN-1) != out_last) begin
                    $display("ERROR: out_last mismatch at col=%0d", output_count);
                    errors <= errors + 1;
                end
                output_count <= output_count + 1;
                if (out_last)
                    last_output_cycle <= cycle_count;
            end
        end
    end

    initial begin
        in_valid = 1'b0;
        in_data = 16'h0000;
        in_last = 1'b0;
        in_mask = 1'b0;
        in_head = 2'd1;
        in_row = 7'd23;
        in_col = 7'd0;
        out_ready = 1'b1;
        errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        in_valid = 1'b1;
        while (input_count < MAX_LEN) begin
            in_data = 16'h0000;
            in_mask = 1'b0;
            in_col = input_count[6:0];
            in_last = (input_count == MAX_LEN-1);
            @(posedge clk);
        end
        in_valid = 1'b0;
        in_last = 1'b0;

        wait (output_count == MAX_LEN);
        @(posedge clk);
        if (row_error || metadata_error) begin
            $display("ERROR: row_error=%0b metadata_error=%0b", row_error, metadata_error);
            errors = errors + 1;
        end

        $display("SOFTMAX_LATENCY_CYCLES=%0d", last_output_cycle - first_input_cycle + 1);
        if (errors == 0)
            $display("SOFTMAX_ONLINE_TEST: PASS");
        else
            $display("SOFTMAX_ONLINE_TEST: FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $display("SOFTMAX_ONLINE_TEST: TIMEOUT");
        $finish;
    end
endmodule
