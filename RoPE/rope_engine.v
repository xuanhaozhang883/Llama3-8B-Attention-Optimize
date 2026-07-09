`timescale 1ns / 1ps

module rope_pair_engine(
    input  wire [15:0] i_x_re,
    input  wire [15:0] i_x_im,
    input  wire [15:0] i_sin,
    input  wire [15:0] i_cos,
    output wire [15:0] o_y_re,
    output wire [15:0] o_y_im
);

    wire [15:0] mul_re_cos;
    wire [15:0] mul_im_sin;
    wire [15:0] mul_re_sin;
    wire [15:0] mul_im_cos;

    bf16_mul u_mul_re_cos (
        .a(i_x_re),
        .b(i_cos),
        .y(mul_re_cos)
    );

    bf16_mul u_mul_im_sin (
        .a(i_x_im),
        .b(i_sin),
        .y(mul_im_sin)
    );

    bf16_mul u_mul_re_sin (
        .a(i_x_re),
        .b(i_sin),
        .y(mul_re_sin)
    );

    bf16_mul u_mul_im_cos (
        .a(i_x_im),
        .b(i_cos),
        .y(mul_im_cos)
    );

    // y_re = x_re*cos - x_im*sin
    bf16_addsub u_sub_re (
        .a(mul_re_cos),
        .b(mul_im_sin),
        .sub(1'b1),
        .y(o_y_re)
    );

    // y_im = x_re*sin + x_im*cos
    bf16_addsub u_add_im (
        .a(mul_re_sin),
        .b(mul_im_cos),
        .sub(1'b0),
        .y(o_y_im)
    );

endmodule
