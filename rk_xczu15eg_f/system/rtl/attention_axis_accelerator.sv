`timescale 1ns/1ps

// Vivado Block Design module-reference wrapper for a single-GQA production
// accelerator. Control is AXI4-Lite; Q/K/V ingress and Context egress are
// AXI4-Stream interfaces compatible with AXI DMA simple mode.
module attention_axis_accelerator #(
    parameter int AXIS_DATA_W = 128,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int Q_HEADS = 4
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_control:s_axis_qkv:m_axis_context, ASSOCIATED_RESET aresetn" *)
    input  logic                       aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic                       aresetn,

    input  logic [7:0]                 s_axi_control_awaddr,
    input  logic                       s_axi_control_awvalid,
    output logic                       s_axi_control_awready,
    input  logic [31:0]                s_axi_control_wdata,
    input  logic [3:0]                 s_axi_control_wstrb,
    input  logic                       s_axi_control_wvalid,
    output logic                       s_axi_control_wready,
    output logic [1:0]                 s_axi_control_bresp,
    output logic                       s_axi_control_bvalid,
    input  logic                       s_axi_control_bready,
    input  logic [7:0]                 s_axi_control_araddr,
    input  logic                       s_axi_control_arvalid,
    output logic                       s_axi_control_arready,
    output logic [31:0]                s_axi_control_rdata,
    output logic [1:0]                 s_axi_control_rresp,
    output logic                       s_axi_control_rvalid,
    input  logic                       s_axi_control_rready,

    input  logic [AXIS_DATA_W-1:0]     s_axis_qkv_tdata,
    input  logic [AXIS_DATA_W/8-1:0]   s_axis_qkv_tkeep,
    input  logic                       s_axis_qkv_tlast,
    input  logic                       s_axis_qkv_tvalid,
    output logic                       s_axis_qkv_tready,

    output logic [AXIS_DATA_W-1:0]     m_axis_context_tdata,
    output logic [AXIS_DATA_W/8-1:0]   m_axis_context_tkeep,
    output logic                       m_axis_context_tlast,
    output logic                       m_axis_context_tvalid,
    input  logic                       m_axis_context_tready
);
    logic command_start;
    logic command_ready;
    logic engine_busy;
    logic engine_done;
    logic frame_loaded;
    logic protocol_error;
    logic [7:0] error_vector;
    logic [63:0] kernel_cycles;
    logic [63:0] fifo_stall_cycles;
    logic [31:0] input_beats;
    logic [31:0] output_beats;

    attention_axil_control u_control (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_control_awaddr),
        .s_axi_awvalid(s_axi_control_awvalid),
        .s_axi_awready(s_axi_control_awready),
        .s_axi_wdata(s_axi_control_wdata),
        .s_axi_wstrb(s_axi_control_wstrb),
        .s_axi_wvalid(s_axi_control_wvalid),
        .s_axi_wready(s_axi_control_wready),
        .s_axi_bresp(s_axi_control_bresp),
        .s_axi_bvalid(s_axi_control_bvalid),
        .s_axi_bready(s_axi_control_bready),
        .s_axi_araddr(s_axi_control_araddr),
        .s_axi_arvalid(s_axi_control_arvalid),
        .s_axi_arready(s_axi_control_arready),
        .s_axi_rdata(s_axi_control_rdata),
        .s_axi_rresp(s_axi_control_rresp),
        .s_axi_rvalid(s_axi_control_rvalid),
        .s_axi_rready(s_axi_control_rready),
        .command_start_pulse(command_start),
        .command_ready(command_ready),
        .engine_busy(engine_busy),
        .engine_done_pulse(engine_done),
        .frame_loaded(frame_loaded),
        .protocol_error(protocol_error),
        .error_vector(error_vector),
        .kernel_cycles(kernel_cycles),
        .fifo_stall_cycles(fifo_stall_cycles),
        .input_beats(input_beats),
        .output_beats(output_beats)
    );

    attention_axis_single_gqa_engine #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS)
    ) u_engine (
        .aclk(aclk),
        .aresetn(aresetn),
        .command_start(command_start),
        .command_ready(command_ready),
        .busy(engine_busy),
        .done_pulse(engine_done),
        .frame_loaded(frame_loaded),
        .protocol_error(protocol_error),
        .s_axis_tdata(s_axis_qkv_tdata),
        .s_axis_tkeep(s_axis_qkv_tkeep),
        .s_axis_tlast(s_axis_qkv_tlast),
        .s_axis_tvalid(s_axis_qkv_tvalid),
        .s_axis_tready(s_axis_qkv_tready),
        .m_axis_tdata(m_axis_context_tdata),
        .m_axis_tkeep(m_axis_context_tkeep),
        .m_axis_tlast(m_axis_context_tlast),
        .m_axis_tvalid(m_axis_context_tvalid),
        .m_axis_tready(m_axis_context_tready),
        .kernel_cycles(kernel_cycles),
        .fifo_stall_cycles(fifo_stall_cycles),
        .input_beats(input_beats),
        .output_beats(output_beats),
        .error_vector(error_vector)
    );
endmodule
