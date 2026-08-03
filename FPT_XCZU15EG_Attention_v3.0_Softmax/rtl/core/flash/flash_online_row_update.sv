`timescale 1ns/1ps

// One-row FlashAttention online-softmax update for a TILE_COLS-wide score tile.
//
// The module consumes one row slice and its previous (m, l) state, then emits:
//   m_new   = max(m_old, max(score_i))
//   alpha   = exp(m_old - m_new)
//   p_i     = exp(score_i - m_new)
//   l_new   = alpha * l_old + sum(p_i)
//
// Scores and m use the same signed Q10.14 conversion as softmax_bf16. Exponent,
// alpha and p use unsigned Q1.23 with fine-delta correction. l is a Q23-scaled
// unsigned accumulator; L_SUM_W=32 covers a complete MAX_LEN=128 row.
module flash_online_row_update #(
    parameter integer TILE_COLS  = 4,
    parameter integer MAX_LEN    = 128,
    parameter integer SCORE_W    = 24,
    parameter integer SCORE_FRAC = 14,
    parameter integer EXP_W      = 24,
    parameter integer EXP_FRAC   = 23,
    parameter integer L_SUM_W    = EXP_W + $clog2(MAX_LEN + 1),
    parameter EXP_LUT_FILE       = "mem/exp_lut_q23.mem"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         in_valid,
    output logic                         in_ready,
    input  logic [TILE_COLS*16-1:0]      in_scores_bf16,
    input  logic [TILE_COLS-1:0]         in_mask,
    input  logic                         in_state_valid,
    input  logic signed [SCORE_W-1:0]    in_m_fixed,
    input  logic [L_SUM_W-1:0]           in_l_q23,

    output logic                         out_valid,
    input  logic                         out_ready,
    output logic                         out_state_valid,
    output logic signed [SCORE_W-1:0]    out_m_fixed,
    output logic [L_SUM_W-1:0]           out_l_q23,
    output logic [EXP_W-1:0]             out_alpha_q23,
    output logic [15:0]                  out_alpha_q15,
    output logic [15:0]                  out_alpha_bf16,
    output logic [TILE_COLS*EXP_W-1:0]   out_weights_q23,
    output logic [TILE_COLS*16-1:0]      out_weights_q15,
    output logic [TILE_COLS*16-1:0]      out_weights_bf16,
    output logic [L_SUM_W-1:0]           out_row_sum_q23,
    output logic                         out_all_masked_tile,
    output logic                         out_numeric_error,

    output logic                         busy
);

    localparam integer L_PRODUCT_W = L_SUM_W + EXP_W;
    localparam integer TAG_W = (TILE_COLS < 1) ? 1 : $clog2(TILE_COLS + 1);
    localparam integer COUNT_W = $clog2(TILE_COLS + 2);
    localparam logic [TAG_W-1:0] ALPHA_TAG = TILE_COLS;
    localparam logic [EXP_W-1:0] EXP_ONE = 24'h800000;
    localparam logic [7:0] BF16_SHIFT_BIAS = 134 - SCORE_FRAC;
    localparam logic [7:0] BF16_SAT_EXP =
        (134 - SCORE_FRAC) + SCORE_W - 8;
    localparam logic [7:0] BF16_ZERO_EXP =
        (134 - SCORE_FRAC) - 9;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PREPARE,
        ST_EXP_RUN,
        ST_FINALIZE,
        ST_HOLD
    } state_t;

    state_t state;

    logic signed [SCORE_W-1:0] score_reg [0:TILE_COLS-1];
    logic [TILE_COLS-1:0] mask_reg;
    logic                  old_state_valid_reg;
    logic signed [SCORE_W-1:0] old_m_reg;
    logic [L_SUM_W-1:0]         old_l_reg;

    logic signed [SCORE_W-1:0] tile_max_comb;
    logic                      tile_has_value_comb;
    logic signed [SCORE_W-1:0] new_m_reg;
    logic [EXP_W-1:0]          alpha_reg;
    logic [EXP_W-1:0]          weight_reg [0:TILE_COLS-1];
    logic [L_SUM_W-1:0]        row_sum_reg;
    logic [COUNT_W-1:0]        exp_issue_count;
    logic [COUNT_W-1:0]        exp_collect_count;
    logic [COUNT_W-1:0]        exp_total_count;

    logic                      exp_in_valid;
    logic signed [SCORE_W:0]   exp_in_magnitude;
    logic                      exp_in_force_zero;
    logic [TAG_W-1:0]          exp_in_tag;
    logic                      exp_out_valid;
    logic [EXP_W-1:0]          exp_out_value;
    logic [TAG_W-1:0]          exp_out_tag;
    logic [TAG_W-1:0]          issue_lane_comb;

    logic [L_PRODUCT_W-1:0] l_product;
    logic [L_PRODUCT_W:0]   l_product_rounded;
    logic [L_SUM_W:0]        l_rescaled_ext;
    logic [L_SUM_W:0]        l_candidate_ext;

    integer max_lane;
    integer seq_lane;

    initial begin
        if (TILE_COLS < 1)
            $error("TILE_COLS must be >= 1");
        if (MAX_LEN < TILE_COLS)
            $error("MAX_LEN must be >= TILE_COLS");
        if (SCORE_FRAC < 7)
            $error("SCORE_FRAC must be >= 7");
        if (SCORE_W < 8)
            $error("SCORE_W must be >= 8");
        if ((EXP_W != 24) || (EXP_FRAC != 23))
            $error("Stage 2A requires EXP_W=24 and EXP_FRAC=23");
        if (L_SUM_W < (EXP_W + $clog2(MAX_LEN + 1)))
            $error("L_SUM_W is too small for MAX_LEN");
        if (((134 - SCORE_FRAC) < 9) ||
            (((134 - SCORE_FRAC) + SCORE_W - 8) > 254))
            $error("SCORE_W/SCORE_FRAC are outside the BF16 converter range");
    end

    function automatic logic signed [SCORE_W-1:0] bf16_to_fixed(
        input logic [15:0] value_bf16
    );
        logic sign_bit;
        logic [7:0] exponent;
        logic [6:0] fraction;
        logic [7:0] significand;
        logic [SCORE_W-1:0] magnitude;
        logic [8:0] rounded_significand;
        logic [4:0] left_shift;
        logic [3:0] right_shift;
        begin
            sign_bit   = value_bf16[15];
            exponent   = value_bf16[14:7];
            fraction   = value_bf16[6:0];
            significand = {1'b1, fraction};
            magnitude  = '0;
            rounded_significand = '0;
            left_shift  = '0;
            right_shift = '0;

            if (exponent == 8'h00) begin
                bf16_to_fixed = '0;
            end else if (exponent == 8'hff) begin
                if (fraction != 7'd0)
                    bf16_to_fixed = '0;
                else
                    bf16_to_fixed = sign_bit ?
                        {1'b1, {(SCORE_W-1){1'b0}}} :
                        {1'b0, {(SCORE_W-1){1'b1}}};
            end else if (exponent >= BF16_SAT_EXP) begin
                bf16_to_fixed = sign_bit ?
                    {1'b1, {(SCORE_W-1){1'b0}}} :
                    {1'b0, {(SCORE_W-1){1'b1}}};
            end else if (exponent <= BF16_ZERO_EXP) begin
                bf16_to_fixed = '0;
            end else begin
                if (exponent >= BF16_SHIFT_BIAS) begin
                    left_shift = exponent - BF16_SHIFT_BIAS;
                    magnitude = {{(SCORE_W-8){1'b0}}, significand} << left_shift;
                end else begin
                    right_shift = BF16_SHIFT_BIAS - exponent;
                    rounded_significand = {1'b0, significand} +
                                          (9'd1 << (right_shift - 1'b1));
                    magnitude = rounded_significand >> right_shift;
                end
                if (sign_bit)
                    bf16_to_fixed = -$signed(magnitude);
                else
                    bf16_to_fixed = $signed(magnitude);
            end
        end
    endfunction

    function automatic logic [15:0] q23_to_q15(
        input logic [23:0] q23_value
    );
        logic [24:0] rounded_value;
        logic [16:0] shifted_value;
        begin
            rounded_value = {1'b0, q23_value} + 25'd128;
            shifted_value = rounded_value >> 8;
            if (shifted_value > 17'd32768)
                q23_to_q15 = 16'd32768;
            else
                q23_to_q15 = shifted_value[15:0];
        end
    endfunction

    function automatic logic [15:0] q15_to_bf16(
        input logic [15:0] q15_value
    );
        integer msb_index;
        integer shift_left;
        integer k;
        logic [31:0] normalized;
        logic [6:0] fraction7;
        logic round_bit;
        logic sticky_bit;
        logic [7:0] rounded_fraction;
        logic [7:0] exponent_biased;
        integer exponent_temp;
        begin
            if (q15_value == 16'd0) begin
                q15_to_bf16 = 16'h0000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 16; k = k + 1)
                    if (q15_value[k])
                        msb_index = k;
                exponent_temp = msb_index + 112;
                exponent_biased = exponent_temp[7:0];
                shift_left = 15 - msb_index;
                normalized = {16'd0, q15_value} << shift_left;
                fraction7 = normalized[14:8];
                round_bit = normalized[7];
                sticky_bit = |normalized[6:0];
                rounded_fraction = {1'b0, fraction7};
                if (round_bit && (sticky_bit || fraction7[0]))
                    rounded_fraction = rounded_fraction + 1'b1;
                if (rounded_fraction[7]) begin
                    exponent_biased = exponent_biased + 1'b1;
                    q15_to_bf16 = {1'b0, exponent_biased, 7'd0};
                end else begin
                    q15_to_bf16 = {1'b0, exponent_biased, rounded_fraction[6:0]};
                end
            end
        end
    endfunction

    always_comb begin
        tile_has_value_comb = 1'b0;
        tile_max_comb = '0;
        for (max_lane = 0; max_lane < TILE_COLS; max_lane = max_lane + 1) begin
            if (!mask_reg[max_lane]) begin
                if (!tile_has_value_comb ||
                    (score_reg[max_lane] > tile_max_comb))
                    tile_max_comb = score_reg[max_lane];
                tile_has_value_comb = 1'b1;
            end
        end
    end

    always_comb begin
        exp_in_valid = 1'b0;
        exp_in_magnitude = '0;
        exp_in_force_zero = 1'b1;
        exp_in_tag = '0;
        issue_lane_comb = '0;

        if ((state == ST_EXP_RUN) &&
            (exp_issue_count < exp_total_count)) begin
            exp_in_valid = 1'b1;
            if (old_state_valid_reg && (exp_issue_count == 0)) begin
                exp_in_magnitude =
                $signed({new_m_reg[SCORE_W-1], new_m_reg}) -
                $signed({old_m_reg[SCORE_W-1], old_m_reg});
                exp_in_force_zero = 1'b0;
                exp_in_tag = ALPHA_TAG;
            end else begin
                issue_lane_comb = exp_issue_count - old_state_valid_reg;
                exp_in_magnitude =
                    $signed({new_m_reg[SCORE_W-1], new_m_reg}) -
                    $signed({score_reg[issue_lane_comb][SCORE_W-1],
                             score_reg[issue_lane_comb]});
                exp_in_force_zero = mask_reg[issue_lane_comb];
                exp_in_tag = issue_lane_comb;
            end
        end
    end

    flash_exp_approx_q23 #(
        .SCORE_W(SCORE_W),
        .SCORE_FRAC(SCORE_FRAC),
        .TAG_W(TAG_W),
        .LUT_FILE(EXP_LUT_FILE)
    ) u_exp_approx (
        .clk,
        .rst_n,
        .in_valid(exp_in_valid),
        .in_magnitude_fixed(exp_in_magnitude),
        .in_force_zero(exp_in_force_zero),
        .in_tag(exp_in_tag),
        .out_valid(exp_out_valid),
        .out_value_q23(exp_out_value),
        .out_tag(exp_out_tag)
    );

    always_comb begin
        l_product = old_l_reg * alpha_reg;
        l_product_rounded = {1'b0, l_product} +
            ({{L_PRODUCT_W{1'b0}}, 1'b1} << (EXP_FRAC - 1));
        l_rescaled_ext = l_product_rounded >> EXP_FRAC;
        l_candidate_ext = l_rescaled_ext + {1'b0, row_sum_reg};
    end

    assign in_ready = (state == ST_IDLE) && !out_valid;
    assign busy = (state != ST_IDLE) || out_valid;

    assign out_alpha_q23 = alpha_reg;
    assign out_alpha_q15 = q23_to_q15(alpha_reg);
    assign out_alpha_bf16 = q15_to_bf16(q23_to_q15(alpha_reg));
    assign out_row_sum_q23 = row_sum_reg;

    generate
        genvar output_lane;
        for (output_lane = 0; output_lane < TILE_COLS; output_lane = output_lane + 1) begin : g_output
            assign out_weights_q23[output_lane*EXP_W +: EXP_W] =
                weight_reg[output_lane];
            assign out_weights_q15[output_lane*16 +: 16] =
                q23_to_q15(weight_reg[output_lane]);
            assign out_weights_bf16[output_lane*16 +: 16] =
                q15_to_bf16(q23_to_q15(weight_reg[output_lane]));
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            mask_reg <= '0;
            old_state_valid_reg <= 1'b0;
            old_m_reg <= '0;
            old_l_reg <= '0;
            new_m_reg <= '0;
            alpha_reg <= '0;
            row_sum_reg <= '0;
            exp_issue_count <= '0;
            exp_collect_count <= '0;
            exp_total_count <= '0;
            out_valid <= 1'b0;
            out_state_valid <= 1'b0;
            out_m_fixed <= '0;
            out_l_q23 <= '0;
            out_all_masked_tile <= 1'b0;
            out_numeric_error <= 1'b0;
            for (seq_lane = 0; seq_lane < TILE_COLS; seq_lane = seq_lane + 1) begin
                score_reg[seq_lane] <= '0;
                weight_reg[seq_lane] <= '0;
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    if (in_valid && in_ready) begin
                        for (seq_lane = 0; seq_lane < TILE_COLS; seq_lane = seq_lane + 1) begin
                            score_reg[seq_lane] <=
                                bf16_to_fixed(in_scores_bf16[seq_lane*16 +: 16]);
                            weight_reg[seq_lane] <= '0;
                        end
                        mask_reg <= in_mask;
                        old_state_valid_reg <= in_state_valid;
                        old_m_reg <= in_m_fixed;
                        old_l_reg <= in_l_q23;
                        alpha_reg <= '0;
                        row_sum_reg <= '0;
                        exp_issue_count <= '0;
                        exp_collect_count <= '0;
                        exp_total_count <= '0;
                        out_state_valid <= 1'b0;
                        out_m_fixed <= '0;
                        out_l_q23 <= '0;
                        out_all_masked_tile <= 1'b0;
                        out_numeric_error <= !in_state_valid && (in_l_q23 != '0);
                        state <= ST_PREPARE;
                    end
                end

                ST_PREPARE: begin
                    if (!tile_has_value_comb) begin
                        out_all_masked_tile <= 1'b1;
                        out_state_valid <= old_state_valid_reg;
                        out_m_fixed <= old_m_reg;
                        out_l_q23 <= old_state_valid_reg ? old_l_reg : '0;
                        alpha_reg <= old_state_valid_reg ? EXP_ONE : '0;
                        row_sum_reg <= '0;
                        out_valid <= 1'b1;
                        state <= ST_HOLD;
                    end else begin
                        out_all_masked_tile <= 1'b0;
                        out_state_valid <= 1'b1;
                        if (old_state_valid_reg && (old_m_reg > tile_max_comb))
                            new_m_reg <= old_m_reg;
                        else
                            new_m_reg <= tile_max_comb;
                        if (old_state_valid_reg && (old_m_reg > tile_max_comb))
                            out_m_fixed <= old_m_reg;
                        else
                            out_m_fixed <= tile_max_comb;
                        exp_issue_count <= '0;
                        exp_collect_count <= '0;
                        exp_total_count <= TILE_COLS + old_state_valid_reg;
                        if (!old_state_valid_reg)
                            alpha_reg <= '0;
                        state <= ST_EXP_RUN;
                    end
                end

                ST_EXP_RUN: begin
                    if (exp_in_valid)
                        exp_issue_count <= exp_issue_count + 1'b1;

                    if (exp_out_valid) begin
                        if (exp_out_tag == ALPHA_TAG) begin
                            alpha_reg <= exp_out_value;
                        end else begin
                            weight_reg[exp_out_tag] <= exp_out_value;
                            row_sum_reg <= row_sum_reg + exp_out_value;
                        end
                        exp_collect_count <= exp_collect_count + 1'b1;
                        if (exp_collect_count == (exp_total_count - 1'b1))
                        state <= ST_FINALIZE;
                    end
                end

                ST_FINALIZE: begin
                    if (l_candidate_ext[L_SUM_W]) begin
                        out_l_q23 <= {L_SUM_W{1'b1}};
                        out_numeric_error <= 1'b1;
                    end else begin
                        out_l_q23 <= l_candidate_ext[L_SUM_W-1:0];
                    end
                    out_valid <= 1'b1;
                    state <= ST_HOLD;
                end

                ST_HOLD: begin
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    out_valid <= 1'b0;
                end
            endcase
        end
    end

endmodule
