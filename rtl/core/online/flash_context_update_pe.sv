`timescale 1ns/1ps

// One row/feature Context-Fusion processing element.
//
// Update mode preserves the v3.1 arithmetic order exactly:
//   p0 = alpha * old_O
//   pk = weight[k-1] * V[k-1], k=1..TILE
//   result = (((p0+p1)+p2)+p3)+p4
//
// The multiplier is a rate-one pipelined AXI IP.  All five independent
// products are therefore issued consecutively instead of waiting for each
// result before issuing the next.  The single adder is intentionally reused in
// the original left-to-right order so this throughput optimization does not
// change floating-point association.  Normalize mode issues only p0.
module flash_context_update_pe #(
    parameter int TILE=4
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic start,
    input  logic normalize,
    input  logic [31:0] alpha_fp32,
    input  logic [31:0] old_o_fp32,
    input  logic [TILE*16-1:0] weights_bf16,
    input  logic [TILE*16-1:0] values_bf16,
    output logic ready,

    output logic result_valid,
    input  logic result_ready,
    output logic [31:0] result_fp32
);
    localparam int PRODUCT_COUNT = TILE+1;
    localparam int PRODUCT_W = (PRODUCT_COUNT <= 1) ? 1 :
                               $clog2(PRODUCT_COUNT);
    localparam int KEY_W = (TILE <= 1) ? 1 : $clog2(TILE+1);

    typedef enum logic [2:0] {
        ST_IDLE, ST_MUL_STREAM, ST_ADD_SEND, ST_ADD_WAIT, ST_OUTPUT
    } state_t;
    state_t state;

    logic normalize_reg;
    logic [TILE*16-1:0] weights_reg;
    logic [TILE*16-1:0] values_reg;
    logic [PRODUCT_W-1:0] mul_send_index;
    logic [PRODUCT_W-1:0] mul_recv_index;
    logic [KEY_W-1:0] add_product_index;
    logic [31:0] products [0:PRODUCT_COUNT-1];
    logic [31:0] accumulator;

    logic [31:0] mul_a_data;
    logic [31:0] mul_b_data;
    logic mul_a_valid, mul_a_ready;
    logic mul_b_valid, mul_b_ready;
    logic mul_result_valid, mul_result_ready;
    logic [31:0] mul_result_data;

    logic [31:0] add_a_data;
    logic [31:0] add_b_data;
    logic add_a_valid, add_a_ready;
    logic add_b_valid, add_b_ready;
    logic add_result_valid, add_result_ready;
    logic [31:0] add_result_data;

    assign ready = (state == ST_IDLE);
    assign mul_result_ready = (state == ST_MUL_STREAM);
    assign add_result_ready = (state == ST_ADD_WAIT);

    pv_fp32_mul_ip u_mul (
        .clk, .rst_n,
        .a_valid(mul_a_valid), .a_ready(mul_a_ready), .a_data(mul_a_data),
        .b_valid(mul_b_valid), .b_ready(mul_b_ready), .b_data(mul_b_data),
        .result_valid(mul_result_valid), .result_ready(mul_result_ready),
        .result_data(mul_result_data)
    );

    pv_fp32_add_ip u_add (
        .clk, .rst_n,
        .a_valid(add_a_valid), .a_ready(add_a_ready), .a_data(add_a_data),
        .b_valid(add_b_valid), .b_ready(add_b_ready), .b_data(add_b_data),
        .result_valid(add_result_valid), .result_ready(add_result_ready),
        .result_data(add_result_data)
    );

    always_ff @(posedge clk) begin : p_streamed_mac
        integer reset_product;
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            normalize_reg <= 1'b0;
            weights_reg <= '0;
            values_reg <= '0;
            mul_send_index <= '0;
            mul_recv_index <= '0;
            add_product_index <= '0;
            accumulator <= '0;
            mul_a_data <= '0;
            mul_b_data <= '0;
            mul_a_valid <= 1'b0;
            mul_b_valid <= 1'b0;
            add_a_data <= '0;
            add_b_data <= '0;
            add_a_valid <= 1'b0;
            add_b_valid <= 1'b0;
            result_valid <= 1'b0;
            result_fp32 <= '0;
            for (reset_product = 0; reset_product < PRODUCT_COUNT;
                 reset_product = reset_product + 1)
                products[reset_product] <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    result_valid <= 1'b0;
                    mul_a_valid <= 1'b0;
                    mul_b_valid <= 1'b0;
                    add_a_valid <= 1'b0;
                    add_b_valid <= 1'b0;
                    if (start && ready) begin
                        normalize_reg <= normalize;
                        weights_reg <= weights_bf16;
                        values_reg <= values_bf16;
                        mul_send_index <= '0;
                        mul_recv_index <= '0;
                        mul_a_data <= alpha_fp32;
                        mul_b_data <= old_o_fp32;
                        mul_a_valid <= 1'b1;
                        mul_b_valid <= 1'b1;
                        state <= ST_MUL_STREAM;
                    end
                end

                ST_MUL_STREAM: begin
                    // Advance the input item only after both independent AXI
                    // operand channels have accepted the current product.
                    if (mul_a_valid && mul_a_ready)
                        mul_a_valid <= 1'b0;
                    if (mul_b_valid && mul_b_ready)
                        mul_b_valid <= 1'b0;
                    if ((!mul_a_valid || mul_a_ready) &&
                        (!mul_b_valid || mul_b_ready)) begin
                        if (!normalize_reg &&
                            ($unsigned(mul_send_index) < PRODUCT_COUNT-1)) begin
                            mul_send_index <= mul_send_index + 1'b1;
                            mul_a_data <= {
                                weights_reg[mul_send_index*16 +: 16], 16'd0
                            };
                            mul_b_data <= {
                                values_reg[mul_send_index*16 +: 16], 16'd0
                            };
                            mul_a_valid <= 1'b1;
                            mul_b_valid <= 1'b1;
                        end
                    end

                    if (mul_result_valid && mul_result_ready) begin
                        products[mul_recv_index] <= mul_result_data;
                        if (normalize_reg) begin
                            result_fp32 <= mul_result_data;
                            result_valid <= 1'b1;
                            state <= ST_OUTPUT;
                        end else if ($unsigned(mul_recv_index) ==
                                     PRODUCT_COUNT-1) begin
                            // Products 0 and 1 are already registered when the
                            // final ordered result arrives from the multiplier.
                            accumulator <= products[0];
                            add_product_index <= 1;
                            add_a_data <= products[0];
                            add_b_data <= products[1];
                            add_a_valid <= 1'b1;
                            add_b_valid <= 1'b1;
                            state <= ST_ADD_SEND;
                        end else begin
                            mul_recv_index <= mul_recv_index + 1'b1;
                        end
                    end
                end

                ST_ADD_SEND: begin
                    if (add_a_valid && add_a_ready)
                        add_a_valid <= 1'b0;
                    if (add_b_valid && add_b_ready)
                        add_b_valid <= 1'b0;
                    if ((!add_a_valid || add_a_ready) &&
                        (!add_b_valid || add_b_ready))
                        state <= ST_ADD_WAIT;
                end

                ST_ADD_WAIT: if (add_result_valid && add_result_ready) begin
                    accumulator <= add_result_data;
                    if ($unsigned(add_product_index) == PRODUCT_COUNT-1) begin
                        result_fp32 <= add_result_data;
                        result_valid <= 1'b1;
                        state <= ST_OUTPUT;
                    end else begin
                        add_product_index <= add_product_index + 1'b1;
                        add_a_data <= add_result_data;
                        add_b_data <= products[add_product_index+1'b1];
                        add_a_valid <= 1'b1;
                        add_b_valid <= 1'b1;
                        state <= ST_ADD_SEND;
                    end
                end

                ST_OUTPUT: if (result_valid && result_ready) begin
                    result_valid <= 1'b0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    logic [31:0] unused_accumulator;
    assign unused_accumulator = accumulator;

    initial begin
        if (TILE != 4)
            $error("flash_context_update_pe: current implementation requires TILE=4");
    end
endmodule
