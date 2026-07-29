`timescale 1ns/1ps

// Packs a scalar BF16 Context stream into an AXI4-Stream DMA word.
module axis_bf16_packer #(
    parameter int AXIS_DATA_W = 128
) (
    input  logic                       aclk,
    input  logic                       aresetn,
    input  logic                       frame_clear,

    input  logic [15:0]                s_bf16_data,
    input  logic                       s_bf16_last,
    input  logic                       s_bf16_valid,
    output logic                       s_bf16_ready,

    output logic [AXIS_DATA_W-1:0]     m_axis_tdata,
    output logic [AXIS_DATA_W/8-1:0]   m_axis_tkeep,
    output logic                       m_axis_tlast,
    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,

    output logic [31:0]                output_beats,
    output logic                       frame_done_pulse
);
    localparam int LANES = AXIS_DATA_W / 16;
    localparam int LANE_W = (LANES <= 1) ? 1 : $clog2(LANES);

    logic [AXIS_DATA_W-1:0] data_reg;
    logic [AXIS_DATA_W/8-1:0] keep_reg;
    logic last_reg;
    logic valid_reg;
    logic [LANE_W-1:0] lane_index;
    logic frame_active;

    initial begin
        if ((AXIS_DATA_W < 16) || ((AXIS_DATA_W % 16) != 0))
            $error("axis_bf16_packer: AXIS_DATA_W must be a multiple of 16");
    end

    assign s_bf16_ready = !valid_reg;
    assign m_axis_tdata = data_reg;
    assign m_axis_tkeep = keep_reg;
    assign m_axis_tlast = last_reg;
    assign m_axis_tvalid = valid_reg;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            data_reg <= '0;
            keep_reg <= '0;
            last_reg <= 1'b0;
            valid_reg <= 1'b0;
            lane_index <= '0;
            output_beats <= '0;
            frame_done_pulse <= 1'b0;
            frame_active <= 1'b0;
        end else if (frame_clear) begin
            data_reg <= '0;
            keep_reg <= '0;
            last_reg <= 1'b0;
            valid_reg <= 1'b0;
            lane_index <= '0;
            frame_done_pulse <= 1'b0;
            frame_active <= 1'b0;
        end else begin
            frame_done_pulse <= 1'b0;

            if (valid_reg && m_axis_tready) begin
                valid_reg <= 1'b0;
                data_reg <= '0;
                keep_reg <= '0;
                if (last_reg)
                    frame_done_pulse <= 1'b1;
                last_reg <= 1'b0;
                output_beats <= output_beats + 1'b1;
            end

            if (s_bf16_valid && s_bf16_ready) begin
                if (!frame_active) begin
                    output_beats <= '0;
                    frame_active <= 1'b1;
                end
                data_reg[lane_index*16 +: 16] <= s_bf16_data;
                keep_reg[lane_index*2 +: 2] <= 2'b11;
                if (s_bf16_last || (lane_index == LANES-1)) begin
                    valid_reg <= 1'b1;
                    last_reg <= s_bf16_last;
                    if (s_bf16_last)
                        frame_active <= 1'b0;
                    lane_index <= '0;
                end else begin
                    lane_index <= lane_index + 1'b1;
                end
            end
        end
    end
endmodule
