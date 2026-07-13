`timescale 1ns/1ps

// ============================================================================
// qk_result_scaler
// ----------------------------------------------------------------------------
// Shared post-processing unit for one raw FP32 QK dot product:
//     score = raw_sum * 1/sqrt(128)
// followed by FP32 -> BF16 round-to-nearest-even conversion.
//
// One shared scaler is intentionally used for the entire tile to save DSPs.
// ============================================================================
module qk_result_scaler #(
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] raw_sum_fp32,

    output logic        out_valid,
    input  logic        out_ready,
    output logic [15:0] score_bf16,
    output logic [31:0] scaled_fp32_debug
);

    typedef enum logic [1:0] {
        S_IDLE     = 2'd0,
        S_MUL_WAIT = 2'd1,
        S_OUT      = 2'd2
    } state_t;

    state_t state;

    logic [31:0] raw_sum_reg;
    logic [31:0] scaled_fp32_reg;

    logic        mul_a_valid;
    logic        mul_a_ready;
    logic        mul_b_valid;
    logic        mul_b_ready;
    logic        mul_result_valid;
    logic        mul_result_ready;
    logic [31:0] mul_result_data;

    assign in_ready         = (state == S_IDLE);
    assign mul_result_ready = (state == S_MUL_WAIT);
    assign scaled_fp32_debug = scaled_fp32_reg;

    fp32_mul_ip #(.IP_ID(2)) u_scale_mul (
        .clk          (clk),
        .rst_n        (rst_n),
        .a_valid      (mul_a_valid),
        .a_ready      (mul_a_ready),
        .a_data       (raw_sum_reg),
        .b_valid      (mul_b_valid),
        .b_ready      (mul_b_ready),
        .b_data       (SCALE_FP32),
        .result_valid (mul_result_valid),
        .result_ready (mul_result_ready),
        .result_data  (mul_result_data)
    );

    fp32_to_bf16 u_fp32_to_bf16 (
        .fp32_in  (scaled_fp32_reg),
        .bf16_out (score_bf16)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            raw_sum_reg       <= 32'h00000000;
            scaled_fp32_reg   <= 32'h00000000;
            out_valid         <= 1'b0;
            mul_a_valid       <= 1'b0;
            mul_b_valid       <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    out_valid   <= 1'b0;
                    mul_a_valid <= 1'b0;
                    mul_b_valid <= 1'b0;

                    if (in_valid && in_ready) begin
                        raw_sum_reg <= raw_sum_fp32;
                        mul_a_valid <= 1'b1;
                        mul_b_valid <= 1'b1;
                        state       <= S_MUL_WAIT;
                    end
                end

                S_MUL_WAIT: begin
                    if (mul_a_valid && mul_a_ready)
                        mul_a_valid <= 1'b0;

                    if (mul_b_valid && mul_b_ready)
                        mul_b_valid <= 1'b0;

                    if (mul_result_valid && mul_result_ready) begin
                        scaled_fp32_reg <= mul_result_data;
                        out_valid       <= 1'b1;
                        mul_a_valid     <= 1'b0;
                        mul_b_valid     <= 1'b0;
                        state           <= S_OUT;
                    end
                end

                S_OUT: begin
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
