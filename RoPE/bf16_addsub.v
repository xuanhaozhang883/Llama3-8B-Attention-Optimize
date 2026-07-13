`timescale 1ns / 1ps

// IEEE-754 BF16 add/subtract, round-to-nearest-even (RNE).
// Three low bits are carried as guard/round/sticky information while the
// operands are aligned.  This avoids the truncation error in the old design.
module bf16_addsub(
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire        sub,
    output reg  [15:0] y
);

    localparam [15:0] BF16_QNAN = 16'h7FC0;

    reg [15:0] b_eff;
    reg [7:0]  exp_a;
    reg [7:0]  exp_b;
    reg [6:0]  frac_a;
    reg [6:0]  frac_b;
    reg [7:0]  mant_a;
    reg [7:0]  mant_b;
    reg [10:0] mant_big;
    reg [10:0] mant_small;
    reg [11:0] mant_res;
    reg [10:0] source_ext;
    reg [8:0]  rounded_mant;
    reg [7:0]  exponent_field;
    reg        sign_a;
    reg        sign_b;
    reg        sign_big;
    reg        sign_small;
    reg        sign_res;
    reg        guard_bit;
    reg        sticky_bit;

    integer exponent_a;
    integer exponent_b;
    integer exponent_res;
    integer shift_amount;
    integer i;

    always @(*) begin
        b_eff = {b[15] ^ sub, b[14:0]};
        sign_a = a[15];
        sign_b = b_eff[15];
        exp_a = a[14:7];
        exp_b = b_eff[14:7];
        frac_a = a[6:0];
        frac_b = b_eff[6:0];

        mant_a = 8'd0;
        mant_b = 8'd0;
        mant_big = 11'd0;
        mant_small = 11'd0;
        mant_res = 12'd0;
        source_ext = 11'd0;
        rounded_mant = 9'd0;
        exponent_field = 8'd0;
        sign_big = 1'b0;
        sign_small = 1'b0;
        sign_res = 1'b0;
        guard_bit = 1'b0;
        sticky_bit = 1'b0;
        exponent_a = 0;
        exponent_b = 0;
        exponent_res = 0;
        shift_amount = 0;
        y = 16'h0000;

        if ((exp_a == 8'hFF && frac_a != 7'd0) ||
            (exp_b == 8'hFF && frac_b != 7'd0)) begin
            y = BF16_QNAN;
        end else if ((exp_a == 8'hFF && frac_a == 7'd0) &&
                     (exp_b == 8'hFF && frac_b == 7'd0)) begin
            if (sign_a != sign_b)
                y = BF16_QNAN;
            else
                y = {sign_a, 8'hFF, 7'd0};
        end else if (exp_a == 8'hFF && frac_a == 7'd0) begin
            y = {sign_a, 8'hFF, 7'd0};
        end else if (exp_b == 8'hFF && frac_b == 7'd0) begin
            y = {sign_b, 8'hFF, 7'd0};
        end else if ((exp_a == 8'd0 && frac_a == 7'd0) &&
                     (exp_b == 8'd0 && frac_b == 7'd0)) begin
            // Round-to-nearest-even chooses +0 for exact cancellation.
            y = 16'h0000;
        end else if (exp_a == 8'd0 && frac_a == 7'd0) begin
            y = b_eff;
        end else if (exp_b == 8'd0 && frac_b == 7'd0) begin
            y = a;
        end else begin
            exponent_a = (exp_a == 8'd0) ? -126 : (exp_a - 127);
            exponent_b = (exp_b == 8'd0) ? -126 : (exp_b - 127);
            mant_a = (exp_a == 8'd0) ? {1'b0, frac_a} : {1'b1, frac_a};
            mant_b = (exp_b == 8'd0) ? {1'b0, frac_b} : {1'b1, frac_b};

            // Keep three low bits for guard, round and sticky information.
            if (exponent_a >= exponent_b) begin
                exponent_res = exponent_a;
                shift_amount = exponent_a - exponent_b;
                sign_big = sign_a;
                sign_small = sign_b;
                mant_big = {3'd0, mant_a} << 3;
                source_ext = {3'd0, mant_b} << 3;
            end else begin
                exponent_res = exponent_b;
                shift_amount = exponent_b - exponent_a;
                sign_big = sign_b;
                sign_small = sign_a;
                mant_big = {3'd0, mant_b} << 3;
                source_ext = {3'd0, mant_a} << 3;
            end

            if (shift_amount == 0) begin
                mant_small = source_ext;
            end else if (shift_amount >= 11) begin
                mant_small = (source_ext != 11'd0) ? 11'd1 : 11'd0;
            end else begin
                mant_small = source_ext >> shift_amount;
                sticky_bit = 1'b0;
                for (i = 0; i < 11; i = i + 1)
                    if (i < shift_amount && source_ext[i])
                        sticky_bit = 1'b1;
                if (sticky_bit)
                    mant_small[0] = 1'b1;
            end

            if (sign_big == sign_small) begin
                mant_res = {1'b0, mant_big} + {1'b0, mant_small};
                sign_res = sign_big;
                if (mant_res >= 12'd2048) begin
                    sticky_bit = mant_res[0];
                    mant_res = mant_res >> 1;
                    if (sticky_bit)
                        mant_res[0] = 1'b1;
                    exponent_res = exponent_res + 1;
                end
            end else begin
                if (mant_big > mant_small) begin
                    mant_res = mant_big - mant_small;
                    sign_res = sign_big;
                end else if (mant_small > mant_big) begin
                    mant_res = mant_small - mant_big;
                    sign_res = sign_small;
                end else begin
                    mant_res = 12'd0;
                    sign_res = 1'b0;
                end

                // Normalize after subtraction, but do not shift below the
                // minimum normal exponent; that range is encoded as BF16
                // subnormal output below.
                for (i = 0; i < 16; i = i + 1)
                    if (mant_res != 12'd0 && mant_res < 12'd1024 &&
                        exponent_res > -126) begin
                        mant_res = mant_res << 1;
                        exponent_res = exponent_res - 1;
                    end
            end

            if (mant_res == 12'd0) begin
                y = 16'h0000;
            end else if (exponent_res > 127) begin
                y = {sign_res, 8'hFF, 7'd0};
            end else begin
                rounded_mant = mant_res >> 3;
                guard_bit = mant_res[2];
                sticky_bit = mant_res[1] || mant_res[0];
                if (guard_bit && (sticky_bit || rounded_mant[0]))
                    rounded_mant = rounded_mant + 1'b1;

                if (exponent_res > -126 ||
                    (exponent_res == -126 && mant_res >= 12'd1024)) begin
                    if (rounded_mant >= 9'd256) begin
                        rounded_mant = 9'd128;
                        exponent_res = exponent_res + 1;
                    end
                    if (exponent_res > 127)
                        y = {sign_res, 8'hFF, 7'd0};
                    else begin
                        exponent_field = exponent_res + 127;
                        y = {sign_res, exponent_field, rounded_mant[6:0]};
                    end
                end else if (rounded_mant >= 9'd128) begin
                    // A rounded subnormal can become the minimum normal.
                    y = {sign_res, 8'h01, 7'd0};
                end else begin
                    y = {sign_res, 8'h00, rounded_mant[6:0]};
                end
            end
        end
    end

endmodule
