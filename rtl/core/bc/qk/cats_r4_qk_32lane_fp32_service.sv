// CATS-R4 A2 local checkpoint: 32-lane FP32 QK accumulator service.
//
// One accepted request represents one Q scalar times one 32-key K vector at a
// single d.  The service keeps independent FP32 accumulators for
// CONTEXTS x LANES, uses the validated floating-point wrappers, and returns
// tagged completion.  A score vector is returned only on d=HEAD_DIM-1.
// This is a local candidate; it is not in the production source manifest.
module cats_r4_qk_32lane_fp32_service #(
    parameter int CONTEXTS = 16,
    parameter int LANES    = 32,
    parameter int HEAD_DIM = 128
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic req_valid,
    output logic req_ready,
    input  logic [15:0] req_epoch,
    input  logic [2:0] req_group,
    input  logic [4:0] req_global_q_head,
    input  logic [6:0] req_row,
    input  logic [1:0] req_key_block,
    input  logic [3:0] req_context_tag,
    input  logic [6:0] req_d,
    input  logic [LANES-1:0] req_lane_valid,
    input  logic req_first,
    input  logic req_last,
    input  logic [15:0] req_q_bf16,
    input  logic [LANES*16-1:0] req_k_vec,

    output logic rsp_valid,
    input logic rsp_ready,
    output logic [15:0] rsp_epoch,
    output logic [2:0] rsp_group,
    output logic [4:0] rsp_global_q_head,
    output logic [6:0] rsp_row,
    output logic [1:0] rsp_key_block,
    output logic [3:0] rsp_context_tag,
    output logic [6:0] rsp_d,
    output logic rsp_score_valid,
    output logic [LANES-1:0] rsp_lane_valid,
    output logic [LANES*32-1:0] rsp_score_fp32,

    output logic [63:0] requests_accepted,
    output logic [63:0] mul_products_completed,
    output logic [63:0] add_results_completed,
    output logic [63:0] response_transfers,
    output logic [63:0] protocol_errors,
    output logic protocol_error_sticky
);
    typedef enum logic [2:0] {
        ST_IDLE     = 3'd0,
        ST_MUL_SEND = 3'd1,
        ST_MUL_WAIT = 3'd2,
        ST_ADD_SEND = 3'd3,
        ST_ADD_WAIT = 3'd4,
        ST_RESP     = 3'd5
    } state_t;

    state_t state;

    logic [15:0] epoch_reg;
    logic [2:0] group_reg;
    logic [4:0] head_reg;
    logic [6:0] row_reg;
    logic [1:0] key_block_reg;
    logic [3:0] context_reg;
    logic [6:0] d_reg;
    logic [LANES-1:0] lane_valid_reg;
    logic first_reg;
    logic last_reg;
    logic [15:0] q_bf16_reg;
    logic [LANES*16-1:0] k_vec_reg;

    logic [31:0] accum_mem [0:CONTEXTS-1][0:LANES-1];
    logic [31:0] product_reg [0:LANES-1];
    logic [31:0] sum_reg [0:LANES-1];

    logic [LANES-1:0] mul_send_valid;
    logic [LANES-1:0] mul_result_seen;
    logic [LANES-1:0] add_send_valid;
    logic [LANES-1:0] add_result_seen;

    logic [LANES-1:0] mul_a_ready;
    logic [LANES-1:0] mul_b_ready;
    logic [LANES-1:0] mul_result_valid;
    logic [LANES-1:0] mul_result_ready;
    logic [LANES*32-1:0] mul_result_data;

    logic [LANES-1:0] add_a_ready;
    logic [LANES-1:0] add_b_ready;
    logic [LANES-1:0] add_result_valid;
    logic [LANES-1:0] add_result_ready;
    logic [LANES*32-1:0] add_result_data;

    logic [LANES*32-1:0] mul_a_data;
    logic [LANES*32-1:0] mul_b_data;
    logic [LANES*32-1:0] add_a_data;
    logic [LANES*32-1:0] add_b_data;

    logic all_mul_inputs_sent;
    logic all_mul_results_seen;
    logic all_add_inputs_sent;
    logic all_add_results_seen;
    logic [LANES-1:0] mul_result_fire;
    logic [LANES-1:0] add_result_fire;

    integer score_lane;

    function automatic [6:0] count_lanes(input logic [LANES-1:0] value);
        integer index;
        begin
            count_lanes = 0;
            for (index = 0; index < LANES; index = index + 1)
                count_lanes = count_lanes + value[index];
        end
    endfunction

    assign req_ready = (state == ST_IDLE) && !protocol_error_sticky;
    assign rsp_valid = (state == ST_RESP);
    assign rsp_epoch = epoch_reg;
    assign rsp_group = group_reg;
    assign rsp_global_q_head = head_reg;
    assign rsp_row = row_reg;
    assign rsp_key_block = key_block_reg;
    assign rsp_context_tag = context_reg;
    assign rsp_d = d_reg;
    assign rsp_score_valid = last_reg;
    assign rsp_lane_valid = lane_valid_reg;

    always_comb begin
        rsp_score_fp32 = '0;
        for (score_lane = 0; score_lane < LANES; score_lane = score_lane + 1)
            rsp_score_fp32[score_lane*32 +: 32] = sum_reg[score_lane];
    end

    assign all_mul_inputs_sent = !(|mul_send_valid);
    assign all_mul_results_seen =
        ((mul_result_seen & lane_valid_reg) == lane_valid_reg);
    assign all_add_inputs_sent = !(|add_send_valid);
    assign mul_result_fire = mul_result_valid & mul_result_ready;
    assign add_result_fire = add_result_valid & add_result_ready;
    assign all_add_results_seen =
        ((add_result_seen & lane_valid_reg) == lane_valid_reg);

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : GEN_FP_LANE
            bf16_to_fp32 u_q_to_fp32 (
                .bf16_in  (q_bf16_reg),
                .fp32_out (mul_a_data[g*32 +: 32])
            );
            bf16_to_fp32 u_k_to_fp32 (
                .bf16_in  (k_vec_reg[g*16 +: 16]),
                .fp32_out (mul_b_data[g*32 +: 32])
            );

            assign add_a_data[g*32 +: 32] =
                first_reg ? 32'h0000_0000 :
                accum_mem[context_reg][g];
            assign add_b_data[g*32 +: 32] = product_reg[g];

            fp32_mul_ip #(.IP_ID(0)) u_mul (
                .clk          (clk),
                .rst_n        (rst_n),
                .a_valid      (mul_send_valid[g]),
                .a_ready      (mul_a_ready[g]),
                .a_data       (mul_a_data[g*32 +: 32]),
                .b_valid      (mul_send_valid[g]),
                .b_ready      (mul_b_ready[g]),
                .b_data       (mul_b_data[g*32 +: 32]),
                .result_valid (mul_result_valid[g]),
                .result_ready (mul_result_ready[g]),
                .result_data  (mul_result_data[g*32 +: 32])
            );

            fp32_add_ip u_add (
                .clk          (clk),
                .rst_n        (rst_n),
                .a_valid      (add_send_valid[g]),
                .a_ready      (add_a_ready[g]),
                .a_data       (add_a_data[g*32 +: 32]),
                .b_valid      (add_send_valid[g]),
                .b_ready      (add_b_ready[g]),
                .b_data       (add_b_data[g*32 +: 32]),
                .result_valid (add_result_valid[g]),
                .result_ready (add_result_ready[g]),
                .result_data  (add_result_data[g*32 +: 32])
            );

            assign mul_result_ready[g] =
                (state == ST_MUL_WAIT) && !mul_result_seen[g];
            assign add_result_ready[g] =
                (state == ST_ADD_WAIT) && !add_result_seen[g];
        end
    endgenerate

    always_ff @(posedge clk) begin : p_service
        integer seq_lane;
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            epoch_reg <= '0;
            group_reg <= '0;
            head_reg <= '0;
            row_reg <= '0;
            key_block_reg <= '0;
            context_reg <= '0;
            d_reg <= '0;
            lane_valid_reg <= '0;
            first_reg <= 1'b0;
            last_reg <= 1'b0;
            q_bf16_reg <= '0;
            k_vec_reg <= '0;
            mul_send_valid <= '0;
            mul_result_seen <= '1;
            add_send_valid <= '0;
            add_result_seen <= '1;
            requests_accepted <= '0;
            mul_products_completed <= '0;
            add_results_completed <= '0;
            response_transfers <= '0;
            protocol_errors <= '0;
            protocol_error_sticky <= 1'b0;
            for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1) begin
                product_reg[seq_lane] <= '0;
                sum_reg[seq_lane] <= '0;
            end
        end else begin
            if (state == ST_IDLE && req_valid && req_ready) begin
                epoch_reg <= req_epoch;
                group_reg <= req_group;
                head_reg <= req_global_q_head;
                row_reg <= req_row;
                key_block_reg <= req_key_block;
                context_reg <= req_context_tag;
                d_reg <= req_d;
                lane_valid_reg <= req_lane_valid;
                first_reg <= req_first;
                last_reg <= req_last;
                q_bf16_reg <= req_q_bf16;
                k_vec_reg <= req_k_vec;
                mul_send_valid <= req_lane_valid;
                mul_result_seen <= ~req_lane_valid;
                add_send_valid <= '0;
                add_result_seen <= ~req_lane_valid;
                requests_accepted <= requests_accepted + 1'b1;
                if (($unsigned(req_context_tag) >= CONTEXTS) ||
                    (req_first != (req_d == 0)) ||
                    (req_last != (req_d == HEAD_DIM-1))) begin
                    protocol_errors <= protocol_errors + 1'b1;
                    protocol_error_sticky <= 1'b1;
                end
                state <= ST_MUL_SEND;
            end

            if (state == ST_MUL_SEND) begin
                for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1)
                    if (mul_send_valid[seq_lane] &&
                        mul_a_ready[seq_lane] && mul_b_ready[seq_lane])
                        mul_send_valid[seq_lane] <= 1'b0;
                if (all_mul_inputs_sent) begin
                    state <= ST_MUL_WAIT;
                end
            end

            if (state == ST_MUL_WAIT) begin
                for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1) begin
                    if (mul_result_valid[seq_lane] && mul_result_ready[seq_lane]) begin
                        product_reg[seq_lane] <= mul_result_data[seq_lane*32 +: 32];
                        mul_result_seen[seq_lane] <= 1'b1;
                    end
                end
                // Count each accepted lane result once per cycle. Updating inside
                // the lane loop would add the same popcount once per lane.
                mul_products_completed <=
                    mul_products_completed + count_lanes(mul_result_fire);
                if (all_mul_results_seen) begin
                    add_send_valid <= lane_valid_reg;
                    add_result_seen <= ~lane_valid_reg;
                    state <= ST_ADD_SEND;
                end
            end

            if (state == ST_ADD_SEND) begin
                for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1)
                    if (add_send_valid[seq_lane] &&
                        add_a_ready[seq_lane] && add_b_ready[seq_lane])
                        add_send_valid[seq_lane] <= 1'b0;
                if (all_add_inputs_sent)
                    state <= ST_ADD_WAIT;
            end

            if (state == ST_ADD_WAIT) begin
                for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1) begin
                    if (add_result_valid[seq_lane] && add_result_ready[seq_lane]) begin
                        sum_reg[seq_lane] <= add_result_data[seq_lane*32 +: 32];
                        accum_mem[context_reg][seq_lane] <=
                            add_result_data[seq_lane*32 +: 32];
                        add_result_seen[seq_lane] <= 1'b1;
                    end
                end
                // Count each accepted lane result once per cycle.
                add_results_completed <=
                    add_results_completed + count_lanes(add_result_fire);
                if (all_add_results_seen)
                    state <= ST_RESP;
            end

            if (state == ST_RESP && rsp_valid && rsp_ready) begin
                response_transfers <= response_transfers + 1'b1;
                state <= ST_IDLE;
            end
        end
    end

    initial begin
        if ((CONTEXTS != 16) || (LANES != 32) || (HEAD_DIM <= 0))
            $error("cats_r4_qk_32lane_fp32_service requires R=16, lanes=32, positive D");
    end
endmodule
