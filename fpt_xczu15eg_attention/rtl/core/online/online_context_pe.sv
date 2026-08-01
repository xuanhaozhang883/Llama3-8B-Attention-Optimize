`timescale 1ns/1ps

// Persistent FP32 context accumulator used by the fused online-attention path.
// The PE deliberately reuses the already validated floating-point multiplier
// and adder IP wrappers from the legacy PV array.
module online_context_pe (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        clear,
    input  logic        load_acc,
    input  logic [31:0] load_acc_fp32,

    input  logic        op_valid,
    output logic        op_ready,
    // 0: acc <- acc * factor
    // 1: acc <- acc + factor * value
    // 2: result <- acc * factor
    input  logic [1:0]  op_kind,
    input  logic [15:0] factor_bf16,
    input  logic [15:0] value_bf16,

    output logic [31:0] acc_fp32,
    output logic        result_valid,
    input  logic        result_ready,
    output logic [31:0] result_fp32
);
    localparam logic [1:0] OP_SCALE = 2'd0;
    localparam logic [1:0] OP_MAC   = 2'd1;
    localparam logic [1:0] OP_NORM  = 2'd2;

    typedef enum logic [2:0] {
        S_IDLE,
        S_MUL_WAIT,
        S_ADD_SEND,
        S_ADD_WAIT,
        S_RESULT
    } state_t;

    state_t state;
    logic [1:0] op_kind_reg;
    logic [31:0] mul_a_reg;
    logic [31:0] mul_b_reg;
    logic [31:0] product_reg;

    logic mul_a_valid, mul_a_ready;
    logic mul_b_valid, mul_b_ready;
    logic mul_result_valid, mul_result_ready;
    logic [31:0] mul_result_data;

    logic add_a_valid, add_a_ready;
    logic add_b_valid, add_b_ready;
    logic add_result_valid, add_result_ready;
    logic [31:0] add_result_data;

    logic [31:0] factor_fp32;
    logic [31:0] value_fp32;

    assign factor_fp32 = {factor_bf16, 16'h0000};
    assign value_fp32  = {value_bf16, 16'h0000};
    assign op_ready    = (state == S_IDLE);

    assign mul_result_ready = (state == S_MUL_WAIT);
    assign add_result_ready = (state == S_ADD_WAIT);

    pv_fp32_mul_ip u_mul (
        .clk(clk), .rst_n(rst_n),
        .a_valid(mul_a_valid), .a_ready(mul_a_ready), .a_data(mul_a_reg),
        .b_valid(mul_b_valid), .b_ready(mul_b_ready), .b_data(mul_b_reg),
        .result_valid(mul_result_valid),
        .result_ready(mul_result_ready), .result_data(mul_result_data)
    );

    pv_fp32_add_ip u_add (
        .clk(clk), .rst_n(rst_n),
        .a_valid(add_a_valid), .a_ready(add_a_ready), .a_data(acc_fp32),
        .b_valid(add_b_valid), .b_ready(add_b_ready), .b_data(product_reg),
        .result_valid(add_result_valid),
        .result_ready(add_result_ready), .result_data(add_result_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state            <= S_IDLE;
            op_kind_reg      <= OP_SCALE;
            mul_a_reg        <= 32'h0000_0000;
            mul_b_reg        <= 32'h0000_0000;
            product_reg      <= 32'h0000_0000;
            acc_fp32         <= 32'h0000_0000;
            result_valid     <= 1'b0;
            result_fp32      <= 32'h0000_0000;
            mul_a_valid      <= 1'b0;
            mul_b_valid      <= 1'b0;
            add_a_valid      <= 1'b0;
            add_b_valid      <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    mul_a_valid  <= 1'b0;
                    mul_b_valid  <= 1'b0;
                    add_a_valid  <= 1'b0;
                    add_b_valid  <= 1'b0;
                    result_valid <= 1'b0;

                    if (load_acc) begin
                        acc_fp32 <= load_acc_fp32;
                    end else if (op_valid) begin
                        op_kind_reg <= op_kind;
                        mul_a_reg   <= (op_kind == OP_MAC) ? value_fp32
                                                          : acc_fp32;
                        mul_b_reg   <= factor_fp32;
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
                        if (op_kind_reg == OP_MAC) begin
                            product_reg <= mul_result_data;
                            add_a_valid <= 1'b1;
                            add_b_valid <= 1'b1;
                            state       <= S_ADD_SEND;
                        end else if (op_kind_reg == OP_NORM) begin
                            result_fp32  <= mul_result_data;
                            result_valid <= 1'b1;
                            state        <= S_RESULT;
                        end else begin
                            acc_fp32 <= mul_result_data;
                            state    <= S_IDLE;
                        end
                    end
                end

                S_ADD_SEND: begin
                    if (add_a_valid && add_a_ready)
                        add_a_valid <= 1'b0;
                    if (add_b_valid && add_b_ready)
                        add_b_valid <= 1'b0;
                    if ((!add_a_valid || add_a_ready) &&
                        (!add_b_valid || add_b_ready))
                        state <= S_ADD_WAIT;
                end

                S_ADD_WAIT: begin
                    if (add_result_valid && add_result_ready) begin
                        acc_fp32 <= add_result_data;
                        state    <= S_IDLE;
                    end
                end

                S_RESULT: begin
                    if (result_valid && result_ready) begin
                        result_valid <= 1'b0;
                        state        <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if ((OP_SCALE == OP_MAC) || (OP_SCALE == OP_NORM) ||
            (OP_MAC == OP_NORM))
            $error("online_context_pe: opcode definitions overlap");
    end
endmodule
