`timescale 1ns/1ps

// ============================================================================
// pv_systolic_pe
// ----------------------------------------------------------------------------
// One stallable BF16 processing element for P x V.
//
// Per valid systolic step:
//   acc_fp32 <- (first ? 0.0 : acc_fp32)
//                + FP32(p_bf16) * FP32(v_bf16)
//
// The multiplier result is rounded to FP32 before the FP32 add. This is the
// same arithmetic order used by the validated QK baseline and by the supplied
// PV golden data.
// ============================================================================
module pv_systolic_pe (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        tile_clear,

    input  logic        step_start,
    input  logic        data_valid,
    input  logic        first,
    input  logic        last,
    input  logic [15:0] p_bf16,
    input  logic [15:0] v_bf16,

    output logic        ready,
    output logic        result_valid,
    output logic [31:0] result_fp32
);

    typedef enum logic [2:0] {
        S_IDLE     = 3'd0,
        S_MUL_WAIT = 3'd1,
        S_ADD_SEND = 3'd2,
        S_ADD_WAIT = 3'd3
    } state_t;

    state_t state;

    logic [31:0] p_fp32_reg;
    logic [31:0] v_fp32_reg;
    logic [31:0] product_fp32_reg;
    logic [31:0] add_a_data_reg;
    logic [31:0] acc_fp32;
    logic        first_reg;
    logic        last_reg;

    logic [31:0] p_fp32_wire;
    logic [31:0] v_fp32_wire;

    pv_bf16_to_fp32 u_p_bf16_to_fp32 (
        .bf16_in  (p_bf16),
        .fp32_out (p_fp32_wire)
    );

    pv_bf16_to_fp32 u_v_bf16_to_fp32 (
        .bf16_in  (v_bf16),
        .fp32_out (v_fp32_wire)
    );

    assign ready = (state == S_IDLE);

    logic        mul_a_valid;
    logic        mul_a_ready;
    logic        mul_b_valid;
    logic        mul_b_ready;
    logic        mul_result_valid;
    logic        mul_result_ready;
    logic [31:0] mul_result_data;

    assign mul_result_ready = (state == S_MUL_WAIT);

    pv_fp32_mul_ip u_mul (
        .clk          (clk),
        .rst_n        (rst_n),
        .a_valid      (mul_a_valid),
        .a_ready      (mul_a_ready),
        .a_data       (p_fp32_reg),
        .b_valid      (mul_b_valid),
        .b_ready      (mul_b_ready),
        .b_data       (v_fp32_reg),
        .result_valid (mul_result_valid),
        .result_ready (mul_result_ready),
        .result_data  (mul_result_data)
    );

    logic        add_a_valid;
    logic        add_a_ready;
    logic        add_b_valid;
    logic        add_b_ready;
    logic        add_result_valid;
    logic        add_result_ready;
    logic [31:0] add_result_data;

    assign add_result_ready = (state == S_ADD_WAIT);

    pv_fp32_add_ip u_add (
        .clk          (clk),
        .rst_n        (rst_n),
        .a_valid      (add_a_valid),
        .a_ready      (add_a_ready),
        .a_data       (add_a_data_reg),
        .b_valid      (add_b_valid),
        .b_ready      (add_b_ready),
        .b_data       (product_fp32_reg),
        .result_valid (add_result_valid),
        .result_ready (add_result_ready),
        .result_data  (add_result_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            p_fp32_reg       <= 32'h00000000;
            v_fp32_reg       <= 32'h00000000;
            product_fp32_reg <= 32'h00000000;
            add_a_data_reg   <= 32'h00000000;
            acc_fp32         <= 32'h00000000;
            first_reg        <= 1'b0;
            last_reg         <= 1'b0;
            result_valid     <= 1'b0;
            result_fp32      <= 32'h00000000;
            mul_a_valid      <= 1'b0;
            mul_b_valid      <= 1'b0;
            add_a_valid      <= 1'b0;
            add_b_valid      <= 1'b0;
        end else if (tile_clear) begin
            state            <= S_IDLE;
            p_fp32_reg       <= 32'h00000000;
            v_fp32_reg       <= 32'h00000000;
            product_fp32_reg <= 32'h00000000;
            add_a_data_reg   <= 32'h00000000;
            acc_fp32         <= 32'h00000000;
            first_reg        <= 1'b0;
            last_reg         <= 1'b0;
            result_valid     <= 1'b0;
            result_fp32      <= 32'h00000000;
            mul_a_valid      <= 1'b0;
            mul_b_valid      <= 1'b0;
            add_a_valid      <= 1'b0;
            add_b_valid      <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    mul_a_valid <= 1'b0;
                    mul_b_valid <= 1'b0;
                    add_a_valid <= 1'b0;
                    add_b_valid <= 1'b0;

                    if (step_start && data_valid) begin
                        p_fp32_reg  <= p_fp32_wire;
                        v_fp32_reg  <= v_fp32_wire;
                        first_reg   <= first;
                        last_reg    <= last;
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
                        product_fp32_reg <= mul_result_data;
                        add_a_data_reg   <= first_reg ? 32'h00000000
                                                      : acc_fp32;
                        add_a_valid      <= 1'b1;
                        add_b_valid      <= 1'b1;
                        state            <= S_ADD_SEND;
                    end
                end

                S_ADD_SEND: begin
                    if (add_a_valid && add_a_ready)
                        add_a_valid <= 1'b0;

                    if (add_b_valid && add_b_ready)
                        add_b_valid <= 1'b0;

                    if ((!add_a_valid || add_a_ready) &&
                        (!add_b_valid || add_b_ready)) begin
                        state <= S_ADD_WAIT;
                    end
                end

                S_ADD_WAIT: begin
                    if (add_result_valid && add_result_ready) begin
                        acc_fp32 <= add_result_data;

                        if (last_reg) begin
                            result_fp32  <= add_result_data;
                            result_valid <= 1'b1;
                        end

                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
