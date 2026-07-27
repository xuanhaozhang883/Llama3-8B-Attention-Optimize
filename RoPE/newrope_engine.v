`timescale 1ns / 1ps

// ============================================================
// RoPE BF16 complex-pair pipeline
//
// y_re = x_re * cos - x_im * sin
// y_im = x_re * sin + x_im * cos
//
// Latency: 2 clocks from i_valid to o_valid.
// ============================================================
module rope_pair_engine_pipe #(
    parameter PAIR_IDX_W = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [PAIR_IDX_W-1:0] i_pair_idx,
    input  wire [15:0]           i_x_re,
    input  wire [15:0]           i_x_im,
    input  wire [15:0]           i_cos,
    input  wire [15:0]           i_sin,
    input  wire                  i_valid,

    output reg  [PAIR_IDX_W-1:0] o_pair_idx,
    output reg  [15:0]           o_y_re,
    output reg  [15:0]           o_y_im,
    output reg                   o_valid
);

    // --------------------------------------------------------
    // Stage 1 registers: input capture
    // --------------------------------------------------------
    reg                  valid_s1;
    reg [PAIR_IDX_W-1:0] pair_idx_s1;

    reg [15:0] x_re_s1;
    reg [15:0] x_im_s1;
    reg [15:0] cos_s1;
    reg [15:0] sin_s1;

    // --------------------------------------------------------
    // Stage 2 registers: multiplication results
    // --------------------------------------------------------
    reg                  valid_s2;
    reg [PAIR_IDX_W-1:0] pair_idx_s2;

    reg [15:0] re_cos_s2;
    reg [15:0] im_sin_s2;
    reg [15:0] re_sin_s2;
    reg [15:0] im_cos_s2;

    // --------------------------------------------------------
    // Combinational BF16 multiplication results from stage 1
    // --------------------------------------------------------
    wire [15:0] re_cos_mul;
    wire [15:0] im_sin_mul;
    wire [15:0] re_sin_mul;
    wire [15:0] im_cos_mul;

    bf16_mul u_mul_re_cos (
        .a(x_re_s1),
        .b(cos_s1),
        .y(re_cos_mul)
    );

    bf16_mul u_mul_im_sin (
        .a(x_im_s1),
        .b(sin_s1),
        .y(im_sin_mul)
    );

    bf16_mul u_mul_re_sin (
        .a(x_re_s1),
        .b(sin_s1),
        .y(re_sin_mul)
    );

    bf16_mul u_mul_im_cos (
        .a(x_im_s1),
        .b(cos_s1),
        .y(im_cos_mul)
    );

    // --------------------------------------------------------
    // Combinational BF16 add/sub results from stage 2
    // --------------------------------------------------------
    wire [15:0] y_re_addsub;
    wire [15:0] y_im_addsub;

    // y_re = re_cos - im_sin
    bf16_addsub u_addsub_re (
        .a  (re_cos_s2),
        .b  (im_sin_s2),
        .sub(1'b1),
        .y  (y_re_addsub)
    );

    // y_im = re_sin + im_cos
    bf16_addsub u_addsub_im (
        .a  (re_sin_s2),
        .b  (im_cos_s2),
        .sub(1'b0),
        .y  (y_im_addsub)
    );

    // --------------------------------------------------------
    // Pipeline registers
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s1    <= 1'b0;
            valid_s2    <= 1'b0;
            o_valid     <= 1'b0;

            pair_idx_s1 <= {PAIR_IDX_W{1'b0}};
            pair_idx_s2 <= {PAIR_IDX_W{1'b0}};
            o_pair_idx  <= {PAIR_IDX_W{1'b0}};

            x_re_s1     <= 16'h0000;
            x_im_s1     <= 16'h0000;
            cos_s1      <= 16'h0000;
            sin_s1      <= 16'h0000;

            re_cos_s2   <= 16'h0000;
            im_sin_s2   <= 16'h0000;
            re_sin_s2   <= 16'h0000;
            im_cos_s2   <= 16'h0000;

            o_y_re      <= 16'h0000;
            o_y_im      <= 16'h0000;
        end else begin
            // -----------------------------
            // Stage 1: capture input pair
            // -----------------------------
            valid_s1 <= i_valid;

            if (i_valid) begin
                pair_idx_s1 <= i_pair_idx;
                x_re_s1     <= i_x_re;
                x_im_s1     <= i_x_im;
                cos_s1      <= i_cos;
                sin_s1      <= i_sin;
            end

            // -----------------------------
            // Stage 2: register products
            // -----------------------------
            valid_s2 <= valid_s1;

            if (valid_s1) begin
                pair_idx_s2 <= pair_idx_s1;

                re_cos_s2 <= re_cos_mul;
                im_sin_s2 <= im_sin_mul;
                re_sin_s2 <= re_sin_mul;
                im_cos_s2 <= im_cos_mul;
            end

            // -----------------------------
            // Output stage: add/sub products
            // -----------------------------
            o_valid <= valid_s2;

            if (valid_s2) begin
                o_pair_idx <= pair_idx_s2;
                o_y_re     <= y_re_addsub;
                o_y_im     <= y_im_addsub;
            end
        end
    end

endmodule
