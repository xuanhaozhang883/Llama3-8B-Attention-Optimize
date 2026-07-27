`timescale 1ns / 1ps

// ============================================================
// Combinational RoPE BF16 complex-pair engine
//
// y_re = x_re * cos - x_im * sin
// y_im = x_re * sin + x_im * cos
// ============================================================
module rope_pair_engine (
    input  wire [15:0] i_x_re,
    input  wire [15:0] i_x_im,
    input  wire [15:0] i_cos,
    input  wire [15:0] i_sin,

    output wire [15:0] o_y_re,
    output wire [15:0] o_y_im
);

    wire [15:0] re_cos;
    wire [15:0] im_sin;
    wire [15:0] re_sin;
    wire [15:0] im_cos;

    // x_re * cos
    bf16_mul u_mul_re_cos (
        .a(i_x_re),
        .b(i_cos),
        .y(re_cos)
    );

    // x_im * sin
    bf16_mul u_mul_im_sin (
        .a(i_x_im),
        .b(i_sin),
        .y(im_sin)
    );

    // x_re * sin
    bf16_mul u_mul_re_sin (
        .a(i_x_re),
        .b(i_sin),
        .y(re_sin)
    );

    // x_im * cos
    bf16_mul u_mul_im_cos (
        .a(i_x_im),
        .b(i_cos),
        .y(im_cos)
    );

    // y_re = x_re*cos - x_im*sin
    bf16_addsub u_addsub_re (
        .a  (re_cos),
        .b  (im_sin),
        .sub(1'b1),
        .y  (o_y_re)
    );

    // y_im = x_re*sin + x_im*cos
    bf16_addsub u_addsub_im (
        .a  (re_sin),
        .b  (im_cos),
        .sub(1'b0),
        .y  (o_y_im)
    );

endmodule
