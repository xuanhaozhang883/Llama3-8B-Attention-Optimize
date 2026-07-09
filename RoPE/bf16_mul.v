`timescale 1ns / 1ps

module bf16_mul(
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] y
);

    reg sign_a, sign_b, sign_y;
    reg [7:0] exp_a, exp_b;
    reg [6:0] frac_a, frac_b;

    reg [7:0] mant_a;
    reg [7:0] mant_b;
    reg [15:0] mant_mul;

    integer exp_y;
    reg [6:0] frac_y;

    always @(*) begin
        sign_a = a[15];
        sign_b = b[15];
        exp_a  = a[14:7];
        exp_b  = b[14:7];
        frac_a = a[6:0];
        frac_b = b[6:0];

        sign_y = sign_a ^ sign_b;

        // zero handling
        if ((a[14:0] == 15'd0) || (b[14:0] == 15'd0)) begin
            y = 16'h0000;
        end
        // simple inf/nan handling
        else if (exp_a == 8'hFF || exp_b == 8'hFF) begin
            y = {sign_y, 8'hFF, 7'd0};
        end
        else begin
            mant_a = {1'b1, frac_a};
            mant_b = {1'b1, frac_b};

            mant_mul = mant_a * mant_b; // 8x8 => 16 bit
            exp_y = exp_a + exp_b - 127;

            // mant_mul format roughly Q2.14
            // if top bit is 1, value >= 2.0, normalize right
            if (mant_mul[15]) begin
                exp_y = exp_y + 1;
                // round by bit 7
                frac_y = mant_mul[14:8];
                if (mant_mul[7]) begin
                    frac_y = frac_y + 1'b1;
                end
            end else begin
                frac_y = mant_mul[13:7];
                if (mant_mul[6]) begin
                    frac_y = frac_y + 1'b1;
                end
            end

            if (exp_y <= 0) begin
                y = 16'h0000;
            end else if (exp_y >= 255) begin
                y = {sign_y, 8'hFF, 7'd0};
            end else begin
                y = {sign_y, exp_y[7:0], frac_y};
            end
        end
    end

endmodule

