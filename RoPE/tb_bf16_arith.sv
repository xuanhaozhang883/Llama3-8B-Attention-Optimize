`timescale 1ns / 1ps

// Directed unit tests for the BF16 arithmetic used by RoPE.  This testbench
// is intentionally small: it catches the former rounding-carry bug before a
// full Q/K vector simulation is run.
module tb_bf16_arith;
    reg [15:0] mul_a;
    reg [15:0] mul_b;
    wire [15:0] mul_y;
    reg [15:0] add_a;
    reg [15:0] add_b;
    reg        add_sub;
    wire [15:0] add_y;
    integer failures;

    bf16_mul u_mul (.a(mul_a), .b(mul_b), .y(mul_y));
    bf16_addsub u_add (.a(add_a), .b(add_b), .sub(add_sub), .y(add_y));

    task automatic check_mul;
        input [15:0] a_in;
        input [15:0] b_in;
        input [15:0] expected;
        begin
            mul_a = a_in;
            mul_b = b_in;
            #1;
            if (mul_y !== expected) begin
                $display("MUL FAIL: %04h * %04h got=%04h expected=%04h", a_in, b_in, mul_y, expected);
                failures = failures + 1;
            end
        end
    endtask

    task automatic check_add;
        input [15:0] a_in;
        input [15:0] b_in;
        input        sub_in;
        input [15:0] expected;
        begin
            add_a = a_in;
            add_b = b_in;
            add_sub = sub_in;
            #1;
            if (add_y !== expected) begin
                $display("ADD FAIL: %04h %s %04h got=%04h expected=%04h", a_in,
                         sub_in ? "-" : "+", b_in, add_y, expected);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        failures = 0;
        mul_a = 16'd0;
        mul_b = 16'd0;
        add_a = 16'd0;
        add_b = 16'd0;
        add_sub = 1'b0;

        // Regression cases for the former fraction-overflow/exponent bug.
        check_mul(16'hBE01, 16'h3F7E, 16'hBE00);
        check_mul(16'hBD84, 16'h3F78, 16'hBD80);
        check_mul(16'h3F80, 16'h3F80, 16'h3F80);
        check_mul(16'h0001, 16'h3F80, 16'h0001);
        check_mul(16'h0001, 16'h3F00, 16'h0000);
        check_mul(16'h0000, 16'h7F80, 16'h7FC0);

        // RNE tie cases and important addition edge cases.
        check_add(16'h3F80, 16'h3B80, 1'b0, 16'h3F80);
        check_add(16'h3F81, 16'h3B80, 1'b0, 16'h3F82);
        check_add(16'h3F80, 16'h3F80, 1'b0, 16'h4000);
        check_add(16'h3F80, 16'h3F80, 1'b1, 16'h0000);
        check_add(16'h0001, 16'h0001, 1'b0, 16'h0002);
        check_add(16'h7F80, 16'h7F80, 1'b1, 16'h7FC0);

        if (failures == 0)
            $display("BF16_ARITH_TEST: PASS");
        else
            $display("BF16_ARITH_TEST: FAIL (%0d failures)", failures);
        $finish;
    end
endmodule
