`timescale 1ns/1ps

module fp32_mul_ip #(
    parameter IP_ID = 0
)(
    input         clk,
    input         rst_n,
    input         a_valid,
    output        a_ready,
    input  [31:0] a_data,
    input         b_valid,
    output        b_ready,
    input  [31:0] b_data,
    output        result_valid,
    input         result_ready,
    output [31:0] result_data
);

generate
if (IP_ID == 0) begin : GEN_MUL0
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
end else begin : GEN_MUL2
floating_point_2 u_fp_mul (
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
end
endgenerate
endmodule
