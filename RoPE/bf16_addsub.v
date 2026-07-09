`timescale 1ns / 1ps

module bf16_addsub(
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire        sub,
    output reg  [15:0] y
);

    reg [15:0] b_eff;

    reg sign_a, sign_b;
    reg [7:0] exp_a, exp_b;
    reg [6:0] frac_a, frac_b;

    reg [7:0] mant_a;
    reg [7:0] mant_b;
    reg [8:0] mant_a_ext;
    reg [8:0] mant_b_ext;

    reg [7:0] exp_big;
    reg sign_big;
    reg sign_small;
    reg [8:0] mant_big;
    reg [8:0] mant_small;
    reg [8:0] mant_res;
    reg sign_res;
    reg [7:0] exp_res;
    integer shift;
    integer i;

    always @(*) begin
        b_eff = {b[15] ^ sub, b[14:0]};

        sign_a = a[15];
        sign_b = b_eff[15];
        exp_a  = a[14:7];
        exp_b  = b_eff[14:7];
        frac_a = a[6:0];
        frac_b = b_eff[6:0];

        // zero cases
        if (a[14:0] == 15'd0) begin
            y = b_eff;
        end else if (b_eff[14:0] == 15'd0) begin
            y = a;
        end else begin
            mant_a = {1'b1, frac_a};
            mant_b = {1'b1, frac_b};

            mant_a_ext = {1'b0, mant_a};
            mant_b_ext = {1'b0, mant_b};

            // align exponent
            if (exp_a >= exp_b) begin
                exp_big = exp_a;
                shift = exp_a - exp_b;
                sign_big = sign_a;
                sign_small = sign_b;
                mant_big = mant_a_ext;
                if (shift >= 9)
                    mant_small = 9'd0;
                else
                    mant_small = mant_b_ext >> shift;
            end else begin
                exp_big = exp_b;
                shift = exp_b - exp_a;
                sign_big = sign_b;
                sign_small = sign_a;
                mant_big = mant_b_ext;
                if (shift >= 9)
                    mant_small = 9'd0;
                else
                    mant_small = mant_a_ext >> shift;
            end

            exp_res = exp_big;

            if (sign_big == sign_small) begin
                mant_res = mant_big + mant_small;
                sign_res = sign_big;

                if (mant_res[8]) begin
                    mant_res = mant_res >> 1;
                    exp_res = exp_res + 1'b1;
                end
            end else begin
                if (mant_big >= mant_small) begin
                    mant_res = mant_big - mant_small;
                    sign_res = sign_big;
                end else begin
                    mant_res = mant_small - mant_big;
                    sign_res = sign_small;
                end

                // normalize left
                for (i = 0; i < 8; i = i + 1) begin
                    if (mant_res[7] == 1'b0 && mant_res != 9'd0 && exp_res > 0) begin
                        mant_res = mant_res << 1;
                        exp_res = exp_res - 1'b1;
                    end
                end
            end

            if (mant_res == 9'd0) begin
                y = 16'h0000;
            end else if (exp_res == 8'hFF) begin
                y = {sign_res, 8'hFF, 7'd0};
            end else begin
                y = {sign_res, exp_res, mant_res[6:0]};
            end
        end
    end

endmodule
