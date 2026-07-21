`timescale 1ns/1ps

// ============================================================
// qk_dot_product_bf16_serial_fixed.v
// 计算一个 128 维 BF16 Q/K scaled dot product：
// score = sum(q[d] * k[d]) * (1/sqrt(128))
//
// 修复点：AXI4-Stream 的 A、B 输入通道可以在不同周期握手，
// 因此分别维护 A/B 的 tvalid，不能要求两个 tready 同周期为 1。
// ============================================================
module qk_dot_product_bf16_serial #(
    parameter integer HEAD_DIM = 128,
    parameter [31:0] SCALE_FP32 = 32'h3DB504F3
)(
    input              clk,
    input              rst_n,

    input              start,
    output             busy,

    input              in_valid,
    output             in_ready,
    input      [15:0]  q_data,
    input      [15:0]  k_data,

    output reg         out_valid,
    input              out_ready,
    output     [15:0]  score_bf16,
    output reg [31:0]  score_fp32_debug
);

localparam [3:0] S_IDLE       = 4'd0;
localparam [3:0] S_ACCEPT     = 4'd1;
localparam [3:0] S_MUL_WAIT   = 4'd2;
localparam [3:0] S_ADD_SEND   = 4'd3;
localparam [3:0] S_ADD_WAIT   = 4'd4;
localparam [3:0] S_SCALE_SEND = 4'd5;
localparam [3:0] S_SCALE_WAIT = 4'd6;
localparam [3:0] S_OUT        = 4'd7;

reg [3:0] state;
reg [8:0] cnt;
reg [31:0] acc_fp32;
reg [31:0] product_fp32;
reg [31:0] q_fp32_reg;
reg [31:0] k_fp32_reg;
reg [31:0] scaled_fp32;

wire [31:0] q_fp32_wire;
wire [31:0] k_fp32_wire;

bf16_to_fp32 u_q_conv(
    .bf16_in(q_data),
    .fp32_out(q_fp32_wire)
);

bf16_to_fp32 u_k_conv(
    .bf16_in(k_data),
    .fp32_out(k_fp32_wire)
);

assign busy     = (state != S_IDLE);
assign in_ready = (state == S_ACCEPT);

// ---------------- Q * K multiplier ----------------
reg  mul_a_valid;
reg  mul_b_valid;
wire mul_a_ready;
wire mul_b_ready;
wire mul_result_valid;
wire [31:0] mul_result_data;

fp32_mul_ip #(.IP_ID(0)) u_mul (
    .clk(clk),
    .rst_n(rst_n),
    .a_valid(mul_a_valid),
    .a_ready(mul_a_ready),
    .a_data(q_fp32_reg),
    .b_valid(mul_b_valid),
    .b_ready(mul_b_ready),
    .b_data(k_fp32_reg),
    .result_valid(mul_result_valid),
    .result_ready(1'b1),
    .result_data(mul_result_data)
);

// ---------------- FP32 accumulator adder ----------------
reg  add_a_valid;
reg  add_b_valid;
wire add_a_ready;
wire add_b_ready;
wire add_result_valid;
wire [31:0] add_result_data;

fp32_add_ip u_add (
    .clk(clk),
    .rst_n(rst_n),
    .a_valid(add_a_valid),
    .a_ready(add_a_ready),
    .a_data(acc_fp32),
    .b_valid(add_b_valid),
    .b_ready(add_b_ready),
    .b_data(product_fp32),
    .result_valid(add_result_valid),
    .result_ready(1'b1),
    .result_data(add_result_data)
);

// ---------------- Scaling multiplier ----------------
reg  scale_a_valid;
reg  scale_b_valid;
wire scale_a_ready;
wire scale_b_ready;
wire scale_result_valid;
wire [31:0] scale_result_data;

fp32_mul_ip #(.IP_ID(2)) u_scale_mul (
    .clk(clk),
    .rst_n(rst_n),
    .a_valid(scale_a_valid),
    .a_ready(scale_a_ready),
    .a_data(acc_fp32),
    .b_valid(scale_b_valid),
    .b_ready(scale_b_ready),
    .b_data(SCALE_FP32),
    .result_valid(scale_result_valid),
    .result_ready(1'b1),
    .result_data(scale_result_data)
);

fp32_to_bf16 u_out_conv(
    .fp32_in(scaled_fp32),
    .bf16_out(score_bf16)
);

always @(posedge clk) begin
    if (!rst_n) begin
        state              <= S_IDLE;
        cnt                <= 9'd0;
        acc_fp32           <= 32'h00000000;
        product_fp32       <= 32'h00000000;
        q_fp32_reg         <= 32'h00000000;
        k_fp32_reg         <= 32'h00000000;
        scaled_fp32        <= 32'h00000000;
        score_fp32_debug   <= 32'h00000000;
        out_valid          <= 1'b0;
        mul_a_valid        <= 1'b0;
        mul_b_valid        <= 1'b0;
        add_a_valid        <= 1'b0;
        add_b_valid        <= 1'b0;
        scale_a_valid      <= 1'b0;
        scale_b_valid      <= 1'b0;
    end else begin
        case (state)
            S_IDLE: begin
                out_valid     <= 1'b0;
                mul_a_valid   <= 1'b0;
                mul_b_valid   <= 1'b0;
                add_a_valid   <= 1'b0;
                add_b_valid   <= 1'b0;
                scale_a_valid <= 1'b0;
                scale_b_valid <= 1'b0;

                if (start) begin
                    cnt      <= 9'd0;
                    acc_fp32 <= 32'h00000000;
                    state    <= S_ACCEPT;
                end
            end

            S_ACCEPT: begin
                if (in_valid && in_ready) begin
                    q_fp32_reg   <= q_fp32_wire;
                    k_fp32_reg   <= k_fp32_wire;
                    mul_a_valid  <= 1'b1;
                    mul_b_valid  <= 1'b1;
                    state        <= S_MUL_WAIT;
                end
            end

            S_MUL_WAIT: begin
                // 两个 AXIS 输入通道分别握手、分别撤销 valid。
                if (mul_a_valid && mul_a_ready)
                    mul_a_valid <= 1'b0;
                if (mul_b_valid && mul_b_ready)
                    mul_b_valid <= 1'b0;

                if (mul_result_valid) begin
                    product_fp32 <= mul_result_data;
                    add_a_valid  <= 1'b1;
                    add_b_valid  <= 1'b1;
                    state        <= S_ADD_SEND;
                end
            end

            S_ADD_SEND: begin
                if (add_a_valid && add_a_ready)
                    add_a_valid <= 1'b0;
                if (add_b_valid && add_b_ready)
                    add_b_valid <= 1'b0;

                // 当前周期完成最后一个尚未完成的握手，或之前已经完成。
                if ((!add_a_valid || add_a_ready) &&
                    (!add_b_valid || add_b_ready)) begin
                    state <= S_ADD_WAIT;
                end
            end

            S_ADD_WAIT: begin
                if (add_result_valid) begin
                    acc_fp32 <= add_result_data;
                    if (cnt == HEAD_DIM-1) begin
                        scale_a_valid <= 1'b1;
                        scale_b_valid <= 1'b1;
                        state         <= S_SCALE_SEND;
                    end else begin
                        cnt   <= cnt + 1'b1;
                        state <= S_ACCEPT;
                    end
                end
            end

            S_SCALE_SEND: begin
                if (scale_a_valid && scale_a_ready)
                    scale_a_valid <= 1'b0;
                if (scale_b_valid && scale_b_ready)
                    scale_b_valid <= 1'b0;

                if ((!scale_a_valid || scale_a_ready) &&
                    (!scale_b_valid || scale_b_ready)) begin
                    state <= S_SCALE_WAIT;
                end
            end

            S_SCALE_WAIT: begin
                if (scale_result_valid) begin
                    scaled_fp32      <= scale_result_data;
                    score_fp32_debug <= scale_result_data;
                    out_valid        <= 1'b1;
                    state            <= S_OUT;
                end
            end

            S_OUT: begin
                if (out_valid && out_ready) begin
                    out_valid <= 1'b0;
                    state     <= S_IDLE;
                end
            end

            default: begin
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
