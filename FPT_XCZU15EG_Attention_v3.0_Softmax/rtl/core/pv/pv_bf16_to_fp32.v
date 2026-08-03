`timescale 1ns/1ps

module pv_bf16_to_fp32 (
    input  wire [15:0] bf16_in,
    output wire [31:0] fp32_out
);
    // BF16 and FP32 share sign/exponent/top mantissa bits.
    assign fp32_out = {bf16_in, 16'h0000};
endmodule
