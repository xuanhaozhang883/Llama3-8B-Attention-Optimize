`timescale 1ns/1ps

// CATS-R4 A2 local checkpoint: parallel score scale and BF16 formatter.
//
// A score commit arrives as one raw FP32 vector.  The formatter applies the
// frozen 1/sqrt(128) FP32 scale through the project's Floating Point IP and
// emits both scaled FP32 debug values and round-to-nearest-even BF16 values.
// It is intentionally a standalone service while the engine's score slab
// ownership contract is still being completed.
module cats_r4_qk_score_formatter #(
    parameter int LANES = 32,
    parameter logic [31:0] SCALE_FP32 = 32'h3DB5_04F3
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic counter_clear,

    input logic in_valid,
    output logic in_ready,
    input logic [15:0] in_epoch,
    input logic [2:0] in_group,
    input logic [4:0] in_global_q_head,
    input logic [6:0] in_row,
    input logic [1:0] in_key_block,
    input logic [3:0] in_context_tag,
    input logic [LANES-1:0] in_lane_valid,
    input logic [LANES*32-1:0] in_raw_fp32,

    output logic out_valid,
    input logic out_ready,
    output logic [15:0] out_epoch,
    output logic [2:0] out_group,
    output logic [4:0] out_global_q_head,
    output logic [6:0] out_row,
    output logic [1:0] out_key_block,
    output logic [3:0] out_context_tag,
    output logic [LANES-1:0] out_lane_valid,
    output logic [LANES*32-1:0] out_scaled_fp32,
    output logic [LANES*16-1:0] out_score_bf16,

    output logic [63:0] scale_requests_accepted,
    output logic [63:0] scale_products_completed,
    output logic [63:0] score_format_transfers,
    output logic [63:0] protocol_errors,
    output logic protocol_error_sticky
);
    typedef enum logic [1:0] {
        ST_IDLE     = 2'd0,
        ST_MUL_SEND = 2'd1,
        ST_MUL_WAIT = 2'd2,
        ST_OUT      = 2'd3
    } state_t;

    state_t state;

    logic [15:0] epoch_reg;
    logic [2:0] group_reg;
    logic [4:0] head_reg;
    logic [6:0] row_reg;
    logic [1:0] key_block_reg;
    logic [3:0] context_reg;
    logic [LANES-1:0] lane_valid_reg;
    logic [LANES*32-1:0] raw_fp32_reg;
    logic [LANES*32-1:0] scaled_fp32_reg;
    logic [LANES*16-1:0] converted_bf16;

    logic [LANES-1:0] mul_send_valid;
    logic [LANES-1:0] mul_result_seen;
    logic [LANES-1:0] mul_a_ready;
    logic [LANES-1:0] mul_b_ready;
    logic [LANES-1:0] mul_result_valid;
    logic [LANES-1:0] mul_result_ready;
    logic [LANES*32-1:0] mul_result_data;
    logic [LANES-1:0] mul_result_fire;
    logic all_mul_inputs_sent;
    logic all_mul_results_seen;

    integer lane;

    function automatic [6:0] count_lanes(input logic [LANES-1:0] value);
        integer index;
        begin
            count_lanes = 0;
            for (index = 0; index < LANES; index = index + 1)
                count_lanes = count_lanes + value[index];
        end
    endfunction

    assign in_ready = (state == ST_IDLE) && !protocol_error_sticky;
    assign out_valid = (state == ST_OUT);
    assign out_epoch = epoch_reg;
    assign out_group = group_reg;
    assign out_global_q_head = head_reg;
    assign out_row = row_reg;
    assign out_key_block = key_block_reg;
    assign out_context_tag = context_reg;
    assign out_lane_valid = lane_valid_reg;
    assign out_scaled_fp32 = scaled_fp32_reg;

    always_comb begin
        out_score_bf16 = '0;
        for (lane = 0; lane < LANES; lane = lane + 1)
            out_score_bf16[lane*16 +: 16] =
                lane_valid_reg[lane] ? converted_bf16[lane*16 +: 16] : 16'h0000;
    end

    assign all_mul_inputs_sent = !(|mul_send_valid);
    assign all_mul_results_seen =
        ((mul_result_seen & lane_valid_reg) == lane_valid_reg);
    assign mul_result_fire = mul_result_valid & mul_result_ready;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : GEN_SCALE_LANE
            fp32_to_bf16 u_scaled_to_bf16 (
                .fp32_in  (scaled_fp32_reg[g*32 +: 32]),
                .bf16_out (converted_bf16[g*16 +: 16])
            );

            fp32_mul_ip #(.IP_ID(2)) u_scale_mul (
                .clk          (clk),
                .rst_n        (rst_n && !clear),
                .a_valid      (mul_send_valid[g]),
                .a_ready      (mul_a_ready[g]),
                .a_data       (raw_fp32_reg[g*32 +: 32]),
                .b_valid      (mul_send_valid[g]),
                .b_ready      (mul_b_ready[g]),
                .b_data       (SCALE_FP32),
                .result_valid (mul_result_valid[g]),
                .result_ready (mul_result_ready[g]),
                .result_data  (mul_result_data[g*32 +: 32])
            );

            assign mul_result_ready[g] =
                (state == ST_MUL_WAIT) && !mul_result_seen[g];
        end
    endgenerate

    always_ff @(posedge clk) begin : p_formatter
        integer seq_lane;
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            epoch_reg <= '0;
            group_reg <= '0;
            head_reg <= '0;
            row_reg <= '0;
            key_block_reg <= '0;
            context_reg <= '0;
            lane_valid_reg <= '0;
            raw_fp32_reg <= '0;
            scaled_fp32_reg <= '0;
            mul_send_valid <= '0;
            mul_result_seen <= '1;
            scale_requests_accepted <= '0;
            scale_products_completed <= '0;
            score_format_transfers <= '0;
            protocol_errors <= '0;
            protocol_error_sticky <= 1'b0;
        end else begin
            if (state == ST_IDLE && in_valid && in_ready) begin
                epoch_reg <= in_epoch;
                group_reg <= in_group;
                head_reg <= in_global_q_head;
                row_reg <= in_row;
                key_block_reg <= in_key_block;
                context_reg <= in_context_tag;
                lane_valid_reg <= in_lane_valid;
                raw_fp32_reg <= in_raw_fp32;
                scaled_fp32_reg <= '0;
                mul_send_valid <= in_lane_valid;
                mul_result_seen <= ~in_lane_valid;
                scale_requests_accepted <= scale_requests_accepted + 1'b1;
                state <= (in_lane_valid == '0) ? ST_OUT : ST_MUL_SEND;
            end

            if (state == ST_MUL_SEND) begin
                for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1)
                    if (mul_send_valid[seq_lane] &&
                        mul_a_ready[seq_lane] && mul_b_ready[seq_lane])
                        mul_send_valid[seq_lane] <= 1'b0;
                if (all_mul_inputs_sent)
                    state <= ST_MUL_WAIT;
            end

            if (state == ST_MUL_WAIT) begin
                for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1) begin
                    if (mul_result_valid[seq_lane] && mul_result_ready[seq_lane]) begin
                        scaled_fp32_reg[seq_lane*32 +: 32] <=
                            mul_result_data[seq_lane*32 +: 32];
                        mul_result_seen[seq_lane] <= 1'b1;
                    end
                end
                scale_products_completed <=
                    scale_products_completed + count_lanes(mul_result_fire);
                if (all_mul_results_seen)
                    state <= ST_OUT;
            end

            if (state == ST_OUT && out_valid && out_ready) begin
                score_format_transfers <= score_format_transfers + 1'b1;
                state <= ST_IDLE;
            end
            if (counter_clear) begin
                scale_requests_accepted <= '0;
                scale_products_completed <= '0;
                score_format_transfers <= '0;
                protocol_errors <= '0;
                protocol_error_sticky <= 1'b0;
            end
        end
    end

    initial begin
        if (LANES <= 0)
            $error("cats_r4_qk_score_formatter requires positive LANES");
    end
endmodule
