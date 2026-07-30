`timescale 1ns / 1ps

// IEEE-754 BF16 multiply, round-to-nearest-even (RNE).
// The datapath remains integer-only and synthesizable.  In particular, a
// rounding carry from 1.1111111 to 10.0000000 increments the exponent.
module bf16_mul(
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] y
);

    localparam [15:0] BF16_QNAN = 16'h7FC0;

    reg        sign_y;
    reg [7:0]  exp_a;
    reg [7:0]  exp_b;
    reg [6:0]  frac_a;
    reg [6:0]  frac_b;
    reg [7:0]  mant_a;
    reg [7:0]  mant_b;
    reg [15:0] mant_product;
    reg [15:0] work_value;
    reg [8:0]  rounded_mant;
    reg [7:0]  exponent_field;
    reg        guard_bit;
    reg        sticky_bit;

    integer exponent_a;
    integer exponent_b;
    integer exponent_y;
    integer leading_one;
    integer shift_amount;
    integer subnormal_power;
    integer i;

    always @(*) begin
        exp_a = a[14:7];
        exp_b = b[14:7];
        frac_a = a[6:0];
        frac_b = b[6:0];
        sign_y = a[15] ^ b[15];

        mant_a = 8'd0;
        mant_b = 8'd0;
        mant_product = 16'd0;
        work_value = 16'd0;
        rounded_mant = 9'd0;
        exponent_field = 8'd0;
        guard_bit = 1'b0;
        sticky_bit = 1'b0;
        exponent_a = 0;
        exponent_b = 0;
        exponent_y = 0;
        leading_one = 0;
        shift_amount = 0;
        subnormal_power = 0;
        y = 16'h0000;

        // NaN takes precedence.  A single canonical quiet NaN keeps the
        // module deterministic and avoids treating a NaN as infinity.
        if ((exp_a == 8'hFF && frac_a != 7'd0) ||
            (exp_b == 8'hFF && frac_b != 7'd0)) begin
            y = BF16_QNAN;
        end else if (((exp_a == 8'hFF && frac_a == 7'd0) &&
                     (exp_b == 8'd0 && frac_b == 7'd0)) ||
                     ((exp_b == 8'hFF && frac_b == 7'd0) &&
                     (exp_a == 8'd0 && frac_a == 7'd0))) begin
            // IEEE-754 defines zero multiplied by infinity as NaN.
            y = BF16_QNAN;
        end else if ((exp_a == 8'hFF && frac_a == 7'd0) ||
                     (exp_b == 8'hFF && frac_b == 7'd0)) begin
            y = {sign_y, 8'hFF, 7'd0};
        end else if ((exp_a == 8'd0 && frac_a == 7'd0) ||
                     (exp_b == 8'd0 && frac_b == 7'd0)) begin
            y = {sign_y, 15'd0};
        end else begin
            // A finite BF16 number is mantissa * 2^(unbiased_exponent - 7).
            // Subnormals have no hidden leading one and use exponent -126.
            exponent_a = (exp_a == 8'd0) ? -126 : (exp_a - 127);
            exponent_b = (exp_b == 8'd0) ? -126 : (exp_b - 127);
            mant_a = (exp_a == 8'd0) ? {1'b0, frac_a} : {1'b1, frac_a};
            mant_b = (exp_b == 8'd0) ? {1'b0, frac_b} : {1'b1, frac_b};
            // The 16-bit destination retains the exact 8-bit by 8-bit
            // significand product without introducing a wider datapath.
            mant_product = mant_a * mant_b;

            // Locate the leading one in the exact 16-bit integer product.
            for (i = 0; i < 16; i = i + 1)
                if (mant_product[i])
                    leading_one = i;

            exponent_y = exponent_a + exponent_b - 14 + leading_one;

            if (exponent_y > 127) begin
                y = {sign_y, 8'hFF, 7'd0};
            end else if (exponent_y >= -126) begin
                // Retain eight significand bits (hidden one plus fraction)
                // and round all discarded bits using RNE.
                shift_amount = leading_one - 7;
                if (shift_amount <= 0) begin
                    rounded_mant = mant_product << (-shift_amount);
                end else begin
                    work_value = mant_product;
                    rounded_mant = work_value >> shift_amount;
                    guard_bit = work_value[shift_amount - 1];
                    sticky_bit = 1'b0;
                    for (i = 0; i < 16; i = i + 1)
                        if (i < (shift_amount - 1) && mant_product[i])
                            sticky_bit = 1'b1;
                    if (guard_bit && (sticky_bit || rounded_mant[0]))
                        rounded_mant = rounded_mant + 1'b1;
                end

                // Critical case: 0x7F rounded upward becomes 0x80 with an
                // exponent increment, never a wrapped zero fraction.
                if (rounded_mant >= 9'd256) begin
                    rounded_mant = 9'd128;
                    exponent_y = exponent_y + 1;
                end

                if (exponent_y > 127)
                    y = {sign_y, 8'hFF, 7'd0};
                else begin
                    exponent_field = exponent_y + 127;
                    y = {sign_y, exponent_field, rounded_mant[6:0]};
                end
            end else begin
                // Convert the exact product to a BF16 subnormal fraction,
                // whose unit is 2^-133, and round it with the same RNE rule.
                subnormal_power = exponent_a + exponent_b + 119;
                if (subnormal_power >= 0) begin
                    rounded_mant = mant_product << subnormal_power;
                end else begin
                    shift_amount = -subnormal_power;
                    work_value = mant_product;
                    if (shift_amount >= 16) begin
                        rounded_mant = 9'd0;
                    end else begin
                        rounded_mant = work_value >> shift_amount;
                        guard_bit = work_value[shift_amount - 1];
                        sticky_bit = 1'b0;
                        for (i = 0; i < 16; i = i + 1)
                            if (i < (shift_amount - 1) && mant_product[i])
                                sticky_bit = 1'b1;
                        if (guard_bit && (sticky_bit || rounded_mant[0]))
                            rounded_mant = rounded_mant + 1'b1;
                    end
                end

                if (rounded_mant >= 9'd128)
                    y = {sign_y, 8'h01, 7'd0};
                else
                    y = {sign_y, 8'h00, rounded_mant[6:0]};
            end
        end
    end

endmodule
