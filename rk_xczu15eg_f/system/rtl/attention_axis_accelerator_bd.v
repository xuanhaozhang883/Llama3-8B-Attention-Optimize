`timescale 1ns/1ps

// Verilog module-reference shell for Vivado Block Design. The production
// implementation remains in attention_axis_accelerator.sv.
module attention_axis_accelerator_bd #(
    parameter integer AXIS_DATA_W = 128,
    parameter integer SEQ_LEN = 128,
    parameter integer HEAD_DIM = 128,
    parameter integer Q_HEADS = 4
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_control:s_axis_qkv:m_axis_context, ASSOCIATED_RESET aresetn, FREQ_HZ 96968727" *)
    input  wire                       aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                       aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control AWADDR" *)
    input  wire [7:0]                 s_axi_control_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control AWVALID" *)
    input  wire                       s_axi_control_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control AWREADY" *)
    output wire                       s_axi_control_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WDATA" *)
    input  wire [31:0]                s_axi_control_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WSTRB" *)
    input  wire [3:0]                 s_axi_control_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WVALID" *)
    input  wire                       s_axi_control_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control WREADY" *)
    output wire                       s_axi_control_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control BRESP" *)
    output wire [1:0]                 s_axi_control_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control BVALID" *)
    output wire                       s_axi_control_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control BREADY" *)
    input  wire                       s_axi_control_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control ARADDR" *)
    input  wire [7:0]                 s_axi_control_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control ARVALID" *)
    input  wire                       s_axi_control_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control ARREADY" *)
    output wire                       s_axi_control_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RDATA" *)
    output wire [31:0]                s_axi_control_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RRESP" *)
    output wire [1:0]                 s_axi_control_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RVALID" *)
    output wire                       s_axi_control_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_control RREADY" *)
    input  wire                       s_axi_control_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_qkv TDATA" *)
    input  wire [AXIS_DATA_W-1:0]     s_axis_qkv_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_qkv TKEEP" *)
    input  wire [AXIS_DATA_W/8-1:0]   s_axis_qkv_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_qkv TLAST" *)
    input  wire                       s_axis_qkv_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_qkv TVALID" *)
    input  wire                       s_axis_qkv_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_qkv TREADY" *)
    output wire                       s_axis_qkv_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_context TDATA" *)
    output wire [AXIS_DATA_W-1:0]     m_axis_context_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_context TKEEP" *)
    output wire [AXIS_DATA_W/8-1:0]   m_axis_context_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_context TLAST" *)
    output wire                       m_axis_context_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_context TVALID" *)
    output wire                       m_axis_context_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_context TREADY" *)
    input  wire                       m_axis_context_tready
);
    attention_axis_accelerator #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS)
    ) u_accelerator (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_control_awaddr(s_axi_control_awaddr),
        .s_axi_control_awvalid(s_axi_control_awvalid),
        .s_axi_control_awready(s_axi_control_awready),
        .s_axi_control_wdata(s_axi_control_wdata),
        .s_axi_control_wstrb(s_axi_control_wstrb),
        .s_axi_control_wvalid(s_axi_control_wvalid),
        .s_axi_control_wready(s_axi_control_wready),
        .s_axi_control_bresp(s_axi_control_bresp),
        .s_axi_control_bvalid(s_axi_control_bvalid),
        .s_axi_control_bready(s_axi_control_bready),
        .s_axi_control_araddr(s_axi_control_araddr),
        .s_axi_control_arvalid(s_axi_control_arvalid),
        .s_axi_control_arready(s_axi_control_arready),
        .s_axi_control_rdata(s_axi_control_rdata),
        .s_axi_control_rresp(s_axi_control_rresp),
        .s_axi_control_rvalid(s_axi_control_rvalid),
        .s_axi_control_rready(s_axi_control_rready),
        .s_axis_qkv_tdata(s_axis_qkv_tdata),
        .s_axis_qkv_tkeep(s_axis_qkv_tkeep),
        .s_axis_qkv_tlast(s_axis_qkv_tlast),
        .s_axis_qkv_tvalid(s_axis_qkv_tvalid),
        .s_axis_qkv_tready(s_axis_qkv_tready),
        .m_axis_context_tdata(m_axis_context_tdata),
        .m_axis_context_tkeep(m_axis_context_tkeep),
        .m_axis_context_tlast(m_axis_context_tlast),
        .m_axis_context_tvalid(m_axis_context_tvalid),
        .m_axis_context_tready(m_axis_context_tready)
    );
endmodule
