module bf16_to_fp32(
    input  [15:0] bf16_in,
    output [31:0] fp32_out
);
    assign fp32_out = {bf16_in, 16'b0};
endmodule
