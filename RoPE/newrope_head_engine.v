`timescale 1ns / 1ps

// ============================================================
// Streaming RoPE head engine
//
// Interface matches tb_rope_head_engine_pipe.v:
//
//   rst_n
//   i_pos
//   i_x_re
//   i_x_im
//   i_valid
//   o_pair_idx
//   o_y_re
//   o_y_im
//   o_valid
//
// Every i_valid input is one BF16 complex pair.
//
// i_pos selects the RoPE cos/sin coefficient.
//
// Default coefficient table:
//
// i_pos = 0 : cos= 1, sin= 0   => (x,y)
// i_pos = 1 : cos= 0, sin= 1   => (-y,x)
// i_pos = 2 : cos=-1, sin= 0   => (-x,-y)
// i_pos = 3 : cos= 0, sin=-1  => (y,-x)
//
// The sequence repeats every four positions.
//
// This is a valid RoPE rotation table with theta = PI/2.
// ============================================================
module rope_head_engine_pipe_default #(
    parameter POS_W      = 8,
    parameter PAIR_IDX_W = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [POS_W-1:0]      i_pos,
    input  wire [15:0]           i_x_re,
    input  wire [15:0]           i_x_im,
    input  wire                  i_valid,

    output wire [PAIR_IDX_W-1:0] o_pair_idx,
    output wire [15:0]           o_y_re,
    output wire [15:0]           o_y_im,
    output wire                  o_valid
);

    localparam [15:0] BF16_ZERO    = 16'h0000;
    localparam [15:0] BF16_ONE     = 16'h3F80;
    localparam [15:0] BF16_NEG_ONE = 16'hBF80;

    reg [PAIR_IDX_W-1:0] pair_counter;

    always @(posedge clk) begin
        if (!rst_n) begin
            pair_counter <= {PAIR_IDX_W{1'b0}};
        end else if (i_valid) begin
            pair_counter <= pair_counter + {{(PAIR_IDX_W-1){1'b0}}, 1'b1};
        end
    end

    function [15:0] rope_cos_default;
        input [POS_W-1:0] pos;
        begin
            case (pos[1:0])
                2'd0: rope_cos_default = BF16_ONE;
                2'd1: rope_cos_default = BF16_ZERO;
                2'd2: rope_cos_default = BF16_NEG_ONE;
                2'd3: rope_cos_default = BF16_ZERO;
                default: rope_cos_default = BF16_ONE;
            endcase
        end
    endfunction

    function [15:0] rope_sin_default;
        input [POS_W-1:0] pos;
        begin
            case (pos[1:0])
                2'd0: rope_sin_default = BF16_ZERO;
                2'd1: rope_sin_default = BF16_ONE;
                2'd2: rope_sin_default = BF16_ZERO;
                2'd3: rope_sin_default = BF16_NEG_ONE;
                default: rope_sin_default = BF16_ZERO;
            endcase
        end
    endfunction

    wire [15:0] cos_value;
    wire [15:0] sin_value;

    assign cos_value = rope_cos_default(i_pos);
    assign sin_value = rope_sin_default(i_pos);


    rope_pair_engine_pipe #(
        .PAIR_IDX_W(PAIR_IDX_W)
    ) u_rope_pair_engine_pipe (
        .clk        (clk),
        .rst_n      (rst_n),

        .i_pair_idx (pair_counter),
        .i_x_re     (i_x_re),
        .i_x_im     (i_x_im),
        .i_cos      (cos_value),
        .i_sin      (sin_value),
        .i_valid    (i_valid),

        .o_pair_idx (o_pair_idx),
        .o_y_re     (o_y_re),
        .o_y_im     (o_y_im),
        .o_valid    (o_valid)
    );

endmodule
