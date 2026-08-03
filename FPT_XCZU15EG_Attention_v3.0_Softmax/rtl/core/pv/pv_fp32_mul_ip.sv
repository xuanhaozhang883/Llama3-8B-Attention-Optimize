`timescale 1ns/1ps

// Wrapper around the same validated Vivado Floating-Point multiplier used by QK.
// Required IP name: floating_point_0
// Configuration:
//   - Multiply, Single precision
//   - AXI4-Stream Blocking
//   - A/B/result TREADY enabled
//   - ACLKEN enabled
//   - ARESETn enabled
module pv_fp32_mul_ip (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        a_valid,
    output logic        a_ready,
    input  logic [31:0] a_data,

    input  logic        b_valid,
    output logic        b_ready,
    input  logic [31:0] b_data,

    output logic        result_valid,
    input  logic        result_ready,
    output logic [31:0] result_data
);

    floating_point_0 u_fp_mul (
        .aclk                 (clk),
        .aclken               (1'b1),
        .aresetn              (rst_n),

        .s_axis_a_tvalid      (a_valid),
        .s_axis_a_tready      (a_ready),
        .s_axis_a_tdata       (a_data),

        .s_axis_b_tvalid      (b_valid),
        .s_axis_b_tready      (b_ready),
        .s_axis_b_tdata       (b_data),

        .m_axis_result_tvalid (result_valid),
        .m_axis_result_tready (result_ready),
        .m_axis_result_tdata  (result_data)
    );

endmodule
