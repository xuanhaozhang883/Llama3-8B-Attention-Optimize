`timescale 1ns/1ps

// One-beat elastic AXI4-Stream loopback used by the Stage 4 DMA bring-up.
// TDATA, TKEEP and TLAST are preserved without interpretation.
module axis_dma_loopback #(
    parameter int DATA_W = 128
) (
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [DATA_W-1:0]     s_axis_tdata,
    input  logic [DATA_W/8-1:0]   s_axis_tkeep,
    input  logic                  s_axis_tlast,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,

    output logic [DATA_W-1:0]     m_axis_tdata,
    output logic [DATA_W/8-1:0]   m_axis_tkeep,
    output logic                  m_axis_tlast,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready
);
    logic hold_valid;
    logic [DATA_W-1:0] hold_data;
    logic [DATA_W/8-1:0] hold_keep;
    logic hold_last;

    assign s_axis_tready = !hold_valid || m_axis_tready;
    assign m_axis_tvalid = hold_valid;
    assign m_axis_tdata  = hold_data;
    assign m_axis_tkeep  = hold_keep;
    assign m_axis_tlast  = hold_last;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            hold_valid <= 1'b0;
            hold_data  <= '0;
            hold_keep  <= '0;
            hold_last  <= 1'b0;
        end else if (s_axis_tready) begin
            hold_valid <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                hold_data <= s_axis_tdata;
                hold_keep <= s_axis_tkeep;
                hold_last <= s_axis_tlast;
            end
        end
    end
endmodule
