`timescale 1ns/1ps

module fp32_to_bf16(
    input  [31:0] fp32_in,
    output [15:0] bf16_out
);
    wire round_bit     = fp32_in[15];
    wire sticky_bit    = |fp32_in[14:0];
    wire lsb_of_result = fp32_in[16];
    wire round_up      = round_bit && (sticky_bit || lsb_of_result);
    wire [16:0] rounded = {1'b0, fp32_in[31:16]} + round_up;
    assign bf16_out = rounded[15:0];
endmodule
