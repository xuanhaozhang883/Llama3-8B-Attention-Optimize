`timescale 1ns/1ps

// CATS-R4 C-side PV accumulation wrapper candidate.
// B supplies ordered FP32 products (weight * V) for four 32-feature blocks
// per key. C preserves key/block order, accumulates with the validated FP32
// adder boundary, normalizes with inv_sum, and emits BF16 context chunks.
// Verification candidate only; not in the production manifest.
module cats_r4_pv_fp32_accumulator #(
    parameter int LANES = 32,
    parameter int KEYS  = 128
) (
    input logic clk, input logic rst_n, input logic clear,
    input logic row_start_valid, output logic row_start_ready,
    input logic [15:0] row_epoch, input logic [2:0] row_group,
    input logic [4:0] row_global_q_head, input logic [6:0] row_number,
    input logic [1:0] row_slot_id, input logic [1:0] row_numeric_mode,
    input logic [31:0] row_inv_sum_fp32,
    input logic product_valid, output logic product_ready,
    input logic [6:0] product_key, input logic [1:0] product_feature_block,
    input logic [LANES*32-1:0] product_fp32, input logic product_last,
    output logic context_valid, input logic context_ready,
    output logic [15:0] context_epoch, output logic [2:0] context_group,
    output logic [4:0] context_global_q_head, output logic [6:0] context_row,
    output logic [1:0] context_slot_id, output logic [1:0] context_numeric_mode,
    output logic [1:0] context_feature_block,
    output logic [LANES*16-1:0] context_data_bf16, output logic context_row_last,
    output logic [63:0] product_accept_count, output logic [63:0] add_commit_count,
    output logic [63:0] context_emit_count, output logic [63:0] protocol_error_count
);
    localparam int FEATURES = LANES*4;
    typedef enum logic [3:0] {ST_IDLE, ST_INPUT, ST_ADD_SEND, ST_ADD_WAIT,
                              ST_NORM_SEND, ST_NORM_WAIT, ST_OUTPUT} state_t;
    state_t state;
    logic [15:0] epoch_reg; logic [2:0] group_reg; logic [4:0] head_reg;
    logic [6:0] row_reg, key_reg; logic [1:0] slot_reg, mode_reg, feature_block;
    logic [31:0] inv_sum_reg;
    logic [31:0] accum [0:FEATURES-1];
    logic [31:0] product_reg [0:LANES-1];
    logic [31:0] norm_reg [0:FEATURES-1];
    logic input_last_reg;
    logic [LANES-1:0] add_pending, add_done, norm_pending, norm_done;
    logic [LANES-1:0] add_a_valid, add_b_valid, add_a_ready, add_b_ready;
    logic [LANES-1:0] add_result_valid, add_result_ready;
    logic [31:0] add_result_data [0:LANES-1];
    logic [LANES-1:0] norm_a_valid, norm_b_valid, norm_a_ready, norm_b_ready;
    logic [LANES-1:0] norm_result_valid, norm_result_ready;
    logic [31:0] norm_result_data [0:LANES-1];
    integer i;

    genvar g;
    generate for (g=0; g<LANES; g=g+1) begin : gen_lane
        pv_fp32_add_ip u_add (
            .clk, .rst_n, .a_valid(add_a_valid[g]), .a_ready(add_a_ready[g]),
            .a_data(accum[feature_block*LANES+g]), .b_valid(add_b_valid[g]),
            .b_ready(add_b_ready[g]), .b_data(product_reg[g]),
            .result_valid(add_result_valid[g]), .result_ready(add_result_ready[g]),
            .result_data(add_result_data[g]));
        pv_fp32_mul_ip u_norm (
            .clk, .rst_n, .a_valid(norm_a_valid[g]), .a_ready(norm_a_ready[g]),
            .a_data(accum[feature_block*LANES+g]), .b_valid(norm_b_valid[g]), .b_ready(norm_b_ready[g]),
            .b_data(inv_sum_reg), .result_valid(norm_result_valid[g]),
            .result_ready(norm_result_ready[g]), .result_data(norm_result_data[g]));
    end endgenerate

    function automatic [15:0] fp32_to_bf16_rne(input logic [31:0] bits);
        logic round_up; logic [16:0] rounded;
        begin
            round_up = bits[15] && (|bits[14:0] || bits[16]);
            rounded = {1'b0,bits[31:16]} + round_up;
            fp32_to_bf16_rne = rounded[15:0];
        end
    endfunction

    always_comb begin
        row_start_ready = (state == ST_IDLE);
        product_ready = (state == ST_INPUT);
        context_valid = (state == ST_OUTPUT);
        context_epoch = epoch_reg; context_group = group_reg;
        context_global_q_head = head_reg; context_row = row_reg;
        context_slot_id = slot_reg; context_numeric_mode = mode_reg;
        context_feature_block = feature_block;
        context_row_last = context_valid && (feature_block == 2'd3);
        context_data_bf16 = '0;
        for (i=0;i<LANES;i=i+1)
            context_data_bf16[i*16 +: 16] = fp32_to_bf16_rne(norm_reg[feature_block*LANES+i]);
        for (i=0;i<LANES;i=i+1) begin
            add_a_valid[i] = (state==ST_ADD_SEND) && add_pending[i];
            add_b_valid[i] = (state==ST_ADD_SEND) && add_pending[i];
            add_result_ready[i] = (state==ST_ADD_WAIT);
            norm_a_valid[i] = (state==ST_NORM_SEND) && norm_pending[i];
            norm_b_valid[i] = (state==ST_NORM_SEND) && norm_pending[i];
            norm_result_ready[i] = (state==ST_NORM_WAIT);
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state<=ST_IDLE; epoch_reg<='0; group_reg<='0; head_reg<='0;
            row_reg<='0; key_reg<='0; slot_reg<='0; mode_reg<='0;
            feature_block<='0; inv_sum_reg<='0; input_last_reg<=0;
            add_pending<='0; add_done<='0; norm_pending<='0; norm_done<='0;
            product_accept_count<='0; add_commit_count<='0; context_emit_count<='0;
            protocol_error_count<='0;
            for (i=0;i<FEATURES;i=i+1) begin accum[i]<='0; norm_reg[i]<='0; end
            for (i=0;i<LANES;i=i+1) product_reg[i]<='0;
        end else begin
            case (state)
                ST_IDLE: if (row_start_valid && row_start_ready) begin
                    epoch_reg<=row_epoch; group_reg<=row_group; head_reg<=row_global_q_head;
                    row_reg<=row_number; slot_reg<=row_slot_id; mode_reg<=row_numeric_mode;
                    inv_sum_reg<=row_inv_sum_fp32; key_reg<='0; feature_block<='0;
                    state<=ST_INPUT;
                end
                ST_INPUT: if (product_valid && product_ready) begin
                    if ((product_key != key_reg) || (product_feature_block != feature_block) ||
                        (product_last != ((product_key == KEYS-1) && (product_feature_block == 2'd3))))
                        protocol_error_count<=protocol_error_count+1'b1;
                    for (i=0;i<LANES;i=i+1) product_reg[i]<=product_fp32[i*32 +: 32];
                    input_last_reg<=product_last; add_pending<={LANES{1'b1}}; add_done<='0;
                    product_accept_count<=product_accept_count+1'b1; state<=ST_ADD_SEND;
                end
                ST_ADD_SEND: begin
                    for (i=0;i<LANES;i=i+1)
                        if (add_pending[i] && add_a_ready[i] && add_b_ready[i]) add_pending[i]<=1'b0;
                    if (add_pending == '0) state<=ST_ADD_WAIT;
                end
                ST_ADD_WAIT: begin
                    for (i=0;i<LANES;i=i+1) if (add_result_valid[i]) begin
                        accum[feature_block*LANES+i]<=add_result_data[i]; add_done[i]<=1'b1;
                    end
                    if (&add_done || (&add_result_valid)) begin
                        add_commit_count<=add_commit_count+1'b1;
                        if (input_last_reg) begin feature_block<='0; norm_pending<={LANES{1'b1}}; norm_done<='0; state<=ST_NORM_SEND; end
                        else if (feature_block==2'd3) begin feature_block<='0; key_reg<=key_reg+1'b1; state<=ST_INPUT; end
                        else begin feature_block<=feature_block+1'b1; state<=ST_INPUT; end
                    end
                end
                ST_NORM_SEND: begin
                    for (i=0;i<LANES;i=i+1)
                        if (norm_pending[i] && norm_a_ready[i] && norm_b_ready[i]) norm_pending[i]<=1'b0;
                    if (norm_pending == '0) state<=ST_NORM_WAIT;
                end
                ST_NORM_WAIT: begin
                    for (i=0;i<LANES;i=i+1) if (norm_result_valid[i]) begin
                        norm_reg[feature_block*LANES+i]<=norm_result_data[i]; norm_done[i]<=1'b1;
                    end
                    if (&norm_done || (&norm_result_valid)) begin
                        if (feature_block==2'd3) begin feature_block<='0; state<=ST_OUTPUT; end
                        else begin feature_block<=feature_block+1'b1; norm_pending<={LANES{1'b1}}; norm_done<='0; state<=ST_NORM_SEND; end
                    end
                end
                ST_OUTPUT: if (context_valid && context_ready) begin
                    context_emit_count<=context_emit_count+1'b1;
                    if (feature_block==2'd3) state<=ST_IDLE;
                    else feature_block<=feature_block+1'b1;
                end
                default: state<=ST_IDLE;
            endcase
        end
    end

    initial if ((LANES != 32) || (KEYS != 128))
        $error("cats_r4_pv_fp32_accumulator: requires LANES=32, KEYS=128");
endmodule
