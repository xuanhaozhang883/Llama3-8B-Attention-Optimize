`timescale 1ns / 1ps

module rope_head_engine #(
    parameter POS_WIDTH = 13,
    parameter NUM_PAIR  = 64,
    parameter ROM_DEPTH = 524288
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    input  wire [POS_WIDTH-1:0] i_pos,

    input  wire [15:0] i_x_re,
    input  wire [15:0] i_x_im,
    input  wire        i_valid,

    output reg  [5:0]  o_pair_idx,
    output reg  [15:0] o_y_re,
    output reg  [15:0] o_y_im,
    output reg         o_valid,
    output reg         done
);

    reg running;
    reg [5:0] pair_idx;

    reg [15:0] sin_rom [0:ROM_DEPTH-1];
    reg [15:0] cos_rom [0:ROM_DEPTH-1];

    wire [18:0] rom_addr;
    wire [15:0] sin_val;
    wire [15:0] cos_val;

    wire [15:0] pair_y_re;
    wire [15:0] pair_y_im;

    assign rom_addr = {i_pos, pair_idx};
    assign sin_val = sin_rom[rom_addr];
    assign cos_val = cos_rom[rom_addr];

    initial begin
        $readmemh("sin_bf16_all.hex", sin_rom);
        $readmemh("cos_bf16_all.hex", cos_rom);
    end

    rope_pair_engine u_rope_pair (
        .i_x_re(i_x_re),
        .i_x_im(i_x_im),
        .i_sin(sin_val),
        .i_cos(cos_val),
        .o_y_re(pair_y_re),
        .o_y_im(pair_y_im)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running    <= 1'b0;
            pair_idx   <= 6'd0;
            o_pair_idx <= 6'd0;
            o_y_re     <= 16'd0;
            o_y_im     <= 16'd0;
            o_valid    <= 1'b0;
            done       <= 1'b0;
        end else begin
            o_valid <= 1'b0;
            done    <= 1'b0;

            if (start) begin
                running  <= 1'b1;
                pair_idx <= 6'd0;
            end else if (running && i_valid) begin
                o_pair_idx <= pair_idx;
                o_y_re     <= pair_y_re;
                o_y_im     <= pair_y_im;
                o_valid    <= 1'b1;

                if (pair_idx == NUM_PAIR - 1) begin
                    running  <= 1'b0;
                    pair_idx <= 6'd0;
                    done     <= 1'b1;
                end else begin
                    pair_idx <= pair_idx + 1'b1;
                end
            end
        end
    end

endmodule
