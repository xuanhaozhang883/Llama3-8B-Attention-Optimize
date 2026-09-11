`timescale 1ns/1ps

// CATS-R4 B2 whole-row Softmax Compatibility candidate.
//
// This is a B-owned standalone checkpoint.  It is intentionally absent from
// scripts/source_manifest.tcl and is not connected to a public/system top.
// A row descriptor supplies the already-global BF16 maximum.  Scores can be
// interleaved across the frozen R=16 context tags and must be presented in
// increasing key order within each context.
//
// Compatibility arithmetic is explicit:
//   BF16 score/max -> signed Q10.14
//   exp(max-score) -> existing Q1.15 ROM, >8 cutoff retained
//   weight -> BF16 RNE
//   sum -> unsigned Q*.15 in key order
//   reciprocal -> floor(2^45/sum), then existing Q30-to-FP32 conversion
module cats_r4_row_softmax_compatibility #(
    parameter int SEQ_LEN = 128,
    parameter int CONTEXTS = 16,
    parameter int SCORE_W = 24,
    parameter int SCORE_FRAC = 14,
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,

    input  logic        row_valid,
    output logic        row_ready,
    input  logic [15:0] row_epoch,
    input  logic [3:0]  row_context_tag,
    input  logic [4:0]  row_global_q_head,
    input  logic [6:0]  row_index,
    input  logic [7:0]  row_key_count,
    input  logic [15:0] row_max_bf16,

    input  logic        score_valid,
    output logic        score_ready,
    input  logic [15:0] score_epoch,
    input  logic [3:0]  score_context_tag,
    input  logic [4:0]  score_global_q_head,
    input  logic [6:0]  score_row,
    input  logic [6:0]  score_key,
    input  logic [15:0] score_bf16,
    input  logic        score_mask,
    input  logic        score_last,

    output logic        weight_valid,
    input  logic        weight_ready,
    output logic [15:0] weight_epoch,
    output logic [3:0]  weight_context_tag,
    output logic [4:0]  weight_global_q_head,
    output logic [6:0]  weight_row,
    output logic [6:0]  weight_key,
    output logic [15:0] weight_bf16,
    output logic        weight_last,

    output logic        done_valid,
    input  logic        done_ready,
    output logic [15:0] done_epoch,
    output logic [3:0]  done_context_tag,
    output logic [4:0]  done_global_q_head,
    output logic [6:0]  done_row,
    output logic [22:0] done_sum_q15,
    output logic [30:0] done_reciprocal_q30,
    output logic [31:0] done_reciprocal_fp32,
    output logic        done_error,

    output logic [63:0] rows_issue,
    output logic [63:0] rows_result,
    output logic [63:0] rows_commit,
    output logic [63:0] exp_issue,
    output logic [63:0] exp_result,
    output logic [63:0] exp_commit,
    output logic [63:0] weight_issue,
    output logic [63:0] weight_result,
    output logic [63:0] weight_commit,
    output logic [63:0] sum_issue,
    output logic [63:0] sum_result,
    output logic [63:0] sum_commit,
    output logic [63:0] reciprocal_issue,
    output logic [63:0] reciprocal_result,
    output logic [63:0] reciprocal_commit,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] reciprocal_busy_stall_cycles,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_special_count,
    output logic        protocol_error_sticky
);
    localparam int EXP_ADDR_SHIFT = SCORE_FRAC - 6;
    localparam logic signed [SCORE_W:0] EXP_LIMIT_FIXED =
        8 <<< SCORE_FRAC;
    localparam logic signed [SCORE_W:0] EXP_ROUND_BIAS =
        1 <<< (EXP_ADDR_SHIFT-1);
    localparam logic [7:0] BF16_SHIFT_BIAS = 134 - SCORE_FRAC;
    localparam logic [7:0] BF16_SAT_EXP =
        (134 - SCORE_FRAC) + SCORE_W - 8;
    localparam logic [7:0] BF16_ZERO_EXP =
        (134 - SCORE_FRAC) - 9;

    logic [CONTEXTS-1:0] ctx_active;
    logic [CONTEXTS-1:0] ctx_closing;
    logic [CONTEXTS-1:0] ctx_error;
    logic [15:0] ctx_epoch [0:CONTEXTS-1];
    logic [4:0]  ctx_head [0:CONTEXTS-1];
    logic [6:0]  ctx_row [0:CONTEXTS-1];
    logic [7:0]  ctx_key_count [0:CONTEXTS-1];
    logic [6:0]  ctx_expected_key [0:CONTEXTS-1];
    logic signed [SCORE_W-1:0] ctx_max_fixed [0:CONTEXTS-1];
    logic [22:0] ctx_sum_q15 [0:CONTEXTS-1];

    logic weight_valid_reg;
    logic [15:0] weight_epoch_reg;
    logic [3:0]  weight_context_tag_reg;
    logic [4:0]  weight_head_reg;
    logic [6:0]  weight_row_reg;
    logic [6:0]  weight_key_reg;
    logic [15:0] weight_bf16_reg;
    logic        weight_last_reg;
    logic        weight_exp_counted_reg;
    logic [22:0] weight_sum_final_reg;

    // Elastic pre-weight stage.  Keeping Q15->BF16 normalization out of the
    // score/LUT/sum acceptance cycle removes the Compatibility timing
    // bottleneck while preserving one accepted score per cycle after fill.
    logic pending_valid;
    logic [15:0] pending_epoch;
    logic [3:0]  pending_context_tag;
    logic [4:0]  pending_head;
    logic [6:0]  pending_row;
    logic [6:0]  pending_key;
    logic [15:0] pending_weight_q15;
    logic        pending_last;
    logic        pending_exp_counted;
    logic [22:0] pending_sum_final;
    logic pending_advance;

    // Score decode is separated from exp-ROM/sum feedback.  calc_sum_base is
    // captured with the score and forwards the just-computed prior-key sum
    // when the same context is accepted in consecutive cycles.
    logic calc_valid;
    logic [15:0] calc_epoch;
    logic [3:0]  calc_context_tag;
    logic [4:0]  calc_head;
    logic [6:0]  calc_row;
    logic [6:0]  calc_key;
    logic signed [SCORE_W-1:0] calc_score_fixed;
    logic [22:0] calc_sum_base;
    logic        calc_mask;
    logic        calc_last;
    logic        calc_advance;


    logic done_valid_reg;
    logic [15:0] done_epoch_reg;
    logic [3:0]  done_context_tag_reg;
    logic [4:0]  done_head_reg;
    logic [6:0]  done_row_reg;
    logic [22:0] done_sum_reg;
    logic [30:0] done_reciprocal_q30_reg;
    logic [31:0] done_reciprocal_fp32_reg;
    logic        done_error_reg;

    logic [9:0] lut_addr;
    logic [15:0] lut_data;
    logic lut_forced_zero;
    logic signed [SCORE_W-1:0] score_fixed;
    logic signed [SCORE_W:0] score_delta;
    logic [15:0] selected_weight_q15;
    logic [22:0] selected_sum_next;

    logic row_fire;
    logic score_fire;
    logic weight_fire;
    logic done_fire;
    logic descriptor_legal;
    logic score_token_legal;
    logic score_key_legal;
    logic score_last_legal;
    logic score_max_legal;
    logic score_transfer_legal;
    logic last_resource_free;

    logic divider_start;
    logic divider_busy;
    logic divider_done;
    logic divider_by_zero;
    logic [45:0] divider_quotient;
    logic [22:0] divider_remainder;
    logic div_meta_valid;
    logic [15:0] div_epoch;
    logic [3:0]  div_context_tag;
    logic [4:0]  div_head;
    logic [6:0]  div_row;
    logic [22:0] div_sum;
    logic        div_error;

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
            sign_bit = value_bf16[15];
            exponent = value_bf16[14:7];
            fraction = value_bf16[6:0];
            significand = {1'b1, fraction};
            magnitude = '0;
            rounded_significand = '0;
            left_shift = '0;
            right_shift = '0;
            if (exponent == 0) begin
                bf16_to_fixed = '0;
            end else if (exponent == 8'hff) begin
                if (fraction != 0)
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
                    magnitude =
                        {{(SCORE_W-8){1'b0}}, significand} << left_shift;
                end else begin
                    right_shift = BF16_SHIFT_BIAS - exponent;
                    rounded_significand = {1'b0, significand} +
                        (9'd1 << (right_shift-1'b1));
                    magnitude = rounded_significand >> right_shift;
                end
                bf16_to_fixed = sign_bit ? -$signed(magnitude) :
                                             $signed(magnitude);
            end
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
        begin
            if (q15_value == 0) begin
                q15_to_bf16 = 16'h0000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 16; k = k + 1)
                    if (q15_value[k]) msb_index = k;
                exponent_biased = msb_index + 112;
                shift_left = 15-msb_index;
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
                    q15_to_bf16 = {1'b0, exponent_biased,
                                   rounded_fraction[6:0]};
                end
            end
        end
    endfunction

    function automatic logic [31:0] q30_to_fp32(
        input logic [30:0] q30_value
    );
        integer msb_index;
        integer shift_right;
        integer k;
        logic [24:0] significand;
        logic round_bit;
        logic sticky_bit;
        logic [7:0] exponent_biased;
        logic [30:0] sticky_mask;
        begin
            if (q30_value == 0) begin
                q30_to_fp32 = 32'h00000000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 31; k = k + 1)
                    if (q30_value[k]) msb_index = k;
                exponent_biased = msb_index + 97;
                significand = '0;
                round_bit = 1'b0;
                sticky_bit = 1'b0;
                sticky_mask = '0;
                if (msb_index <= 23) begin
                    significand = q30_value << (23-msb_index);
                end else begin
                    shift_right = msb_index-23;
                    significand = q30_value >> shift_right;
                    round_bit = q30_value[shift_right-1];
                    sticky_mask = (31'd1 << (shift_right-1))-1'b1;
                    sticky_bit = |(q30_value & sticky_mask);
                    if (round_bit && (sticky_bit || significand[0]))
                        significand = significand + 1'b1;
                end
                if (significand[24]) begin
                    exponent_biased = exponent_biased + 1'b1;
                    q30_to_fp32 = {1'b0, exponent_biased, 23'd0};
                end else begin
                    q30_to_fp32 = {1'b0, exponent_biased,
                                   significand[22:0]};
                end
            end
        end
    endfunction

    exp_lut #(.INIT_FILE(EXP_LUT_FILE)) u_exp_lut (
        .addr(lut_addr),
        .data(lut_data)
    );

    unsigned_restoring_divider #(
        .NUM_W(46),
        .DEN_W(23)
    ) u_reciprocal (
        .clk(clk),
        .rst_n(rst_n && !clear),
        .start(divider_start),
        .numerator(46'd35184372088832),
        .denominator(weight_sum_final_reg),
        .busy(divider_busy),
        .done(divider_done),
        .divide_by_zero(divider_by_zero),
        .quotient(divider_quotient),
        .remainder(divider_remainder)
    );

    always_comb begin
        score_fixed = bf16_to_fixed(score_bf16);
        score_delta =
            $signed({ctx_max_fixed[calc_context_tag][SCORE_W-1],
                     ctx_max_fixed[calc_context_tag]}) -
            $signed({calc_score_fixed[SCORE_W-1], calc_score_fixed});
        lut_addr = '0;
        lut_forced_zero = calc_mask;
        if (!calc_mask) begin
            if (score_delta <= 0) begin
                lut_addr = '0;
            end else if (score_delta > EXP_LIMIT_FIXED) begin
                lut_forced_zero = 1'b1;
            end else begin
                lut_addr = $unsigned(score_delta + EXP_ROUND_BIAS) >>
                           EXP_ADDR_SHIFT;
            end
        end
        selected_weight_q15 = lut_forced_zero ? 16'd0 : lut_data;
        selected_sum_next = calc_sum_base + selected_weight_q15;
    end

    assign descriptor_legal =
        (row_key_count != 0) &&
        ($unsigned(row_key_count) <= SEQ_LEN) &&
        ($unsigned(row_key_count) == ($unsigned(row_index) + 1));
    assign score_token_legal =
        ctx_active[score_context_tag] &&
        !ctx_closing[score_context_tag] &&
        (score_epoch == ctx_epoch[score_context_tag]) &&
        (score_global_q_head == ctx_head[score_context_tag]) &&
        (score_row == ctx_row[score_context_tag]);
    assign score_key_legal =
        score_key == ctx_expected_key[score_context_tag];
    assign score_last_legal =
        score_last ==
        (($unsigned(score_key) + 1) ==
         $unsigned(ctx_key_count[score_context_tag]));
    assign score_max_legal =
        score_mask || (score_fixed <= ctx_max_fixed[score_context_tag]);
    assign score_transfer_legal = score_token_legal && score_key_legal &&
                                  score_last_legal && score_max_legal;

    assign last_resource_free = !divider_busy && !div_meta_valid &&
                                 !done_valid_reg &&
                                 !(weight_valid_reg && weight_last_reg) &&
                                 !(pending_valid && pending_last) &&
                                 !(calc_valid && calc_last);
    assign row_ready = !ctx_active[row_context_tag];
    assign pending_advance = pending_valid &&
                             (!weight_valid_reg || weight_ready);
    assign calc_advance = calc_valid &&
                          (!pending_valid || pending_advance);
    assign score_ready = (!calc_valid || calc_advance) &&
                          (!score_last || last_resource_free);
    assign row_fire = row_valid && row_ready;
    assign score_fire = score_valid && score_ready;
    assign weight_fire = weight_valid_reg && weight_ready;
    assign done_fire = done_valid_reg && done_ready;
    assign divider_start = weight_fire && weight_last_reg;

    assign weight_valid = weight_valid_reg;
    assign weight_epoch = weight_epoch_reg;
    assign weight_context_tag = weight_context_tag_reg;
    assign weight_global_q_head = weight_head_reg;
    assign weight_row = weight_row_reg;
    assign weight_key = weight_key_reg;
    assign weight_bf16 = weight_bf16_reg;
    assign weight_last = weight_last_reg;

    assign done_valid = done_valid_reg;
    assign done_epoch = done_epoch_reg;
    assign done_context_tag = done_context_tag_reg;
    assign done_global_q_head = done_head_reg;
    assign done_row = done_row_reg;
    assign done_sum_q15 = done_sum_reg;
    assign done_reciprocal_q30 = done_reciprocal_q30_reg;
    assign done_reciprocal_fp32 = done_reciprocal_fp32_reg;
    assign done_error = done_error_reg;

    always_ff @(posedge clk or negedge rst_n) begin : p_state
        integer index;
        if (!rst_n) begin
            ctx_active <= '0;
            ctx_closing <= '0;
            ctx_error <= '0;
            weight_valid_reg <= 1'b0;
            weight_epoch_reg <= '0;
            weight_context_tag_reg <= '0;
            weight_head_reg <= '0;
            weight_row_reg <= '0;
            weight_key_reg <= '0;
            weight_bf16_reg <= '0;
            weight_last_reg <= 1'b0;
            weight_exp_counted_reg <= 1'b0;
            weight_sum_final_reg <= '0;
            pending_valid <= 1'b0;
            pending_epoch <= '0;
            pending_context_tag <= '0;
            pending_head <= '0;
            pending_row <= '0;
            pending_key <= '0;
            pending_weight_q15 <= '0;
            pending_last <= 1'b0;
            pending_exp_counted <= 1'b0;
            pending_sum_final <= '0;
            calc_valid <= 1'b0;
            calc_epoch <= '0;
            calc_context_tag <= '0;
            calc_head <= '0;
            calc_row <= '0;
            calc_key <= '0;
            calc_score_fixed <= '0;
            calc_sum_base <= '0;
            calc_mask <= 1'b0;
            calc_last <= 1'b0;
            done_valid_reg <= 1'b0;
            done_epoch_reg <= '0;
            done_context_tag_reg <= '0;
            done_head_reg <= '0;
            done_row_reg <= '0;
            done_sum_reg <= '0;
            done_reciprocal_q30_reg <= '0;
            done_reciprocal_fp32_reg <= '0;
            done_error_reg <= 1'b0;
            div_meta_valid <= 1'b0;
            div_epoch <= '0;
            div_context_tag <= '0;
            div_head <= '0;
            div_row <= '0;
            div_sum <= '0;
            div_error <= 1'b0;
            rows_issue <= '0;
            rows_result <= '0;
            rows_commit <= '0;
            exp_issue <= '0;
            exp_result <= '0;
            exp_commit <= '0;
            weight_issue <= '0;
            weight_result <= '0;
            weight_commit <= '0;
            sum_issue <= '0;
            sum_result <= '0;
            sum_commit <= '0;
            reciprocal_issue <= '0;
            reciprocal_result <= '0;
            reciprocal_commit <= '0;
            output_stall_cycles <= '0;
            reciprocal_busy_stall_cycles <= '0;
            protocol_error_count <= '0;
            numeric_special_count <= '0;
            protocol_error_sticky <= 1'b0;
            for (index = 0; index < CONTEXTS; index = index + 1) begin
                ctx_epoch[index] <= '0;
                ctx_head[index] <= '0;
                ctx_row[index] <= '0;
                ctx_key_count[index] <= '0;
                ctx_expected_key[index] <= '0;
                ctx_max_fixed[index] <= '0;
                ctx_sum_q15[index] <= '0;
            end
        end else if (clear) begin
            ctx_active <= '0;
            ctx_closing <= '0;
            ctx_error <= '0;
            weight_valid_reg <= 1'b0;
            pending_valid <= 1'b0;
            calc_valid <= 1'b0;
            done_valid_reg <= 1'b0;
            div_meta_valid <= 1'b0;
            rows_issue <= '0;
            rows_result <= '0;
            rows_commit <= '0;
            exp_issue <= '0;
            exp_result <= '0;
            exp_commit <= '0;
            weight_issue <= '0;
            weight_result <= '0;
            weight_commit <= '0;
            sum_issue <= '0;
            sum_result <= '0;
            sum_commit <= '0;
            reciprocal_issue <= '0;
            reciprocal_result <= '0;
            reciprocal_commit <= '0;
            output_stall_cycles <= '0;
            reciprocal_busy_stall_cycles <= '0;
            protocol_error_count <= '0;
            numeric_special_count <= '0;
            protocol_error_sticky <= 1'b0;
        end else begin
            if (weight_fire)
                weight_valid_reg <= 1'b0;
            if (pending_advance) begin
                weight_valid_reg <= 1'b1;
                weight_epoch_reg <= pending_epoch;
                weight_context_tag_reg <= pending_context_tag;
                weight_head_reg <= pending_head;
                weight_row_reg <= pending_row;
                weight_key_reg <= pending_key;
                weight_bf16_reg <= q15_to_bf16(pending_weight_q15);
                weight_last_reg <= pending_last;
                weight_exp_counted_reg <= pending_exp_counted;
                weight_sum_final_reg <= pending_sum_final;
                pending_valid <= 1'b0;
            end
            if (done_fire) begin
                done_valid_reg <= 1'b0;
                ctx_active[done_context_tag_reg] <= 1'b0;
                ctx_closing[done_context_tag_reg] <= 1'b0;
                ctx_error[done_context_tag_reg] <= 1'b0;
                rows_commit <= rows_commit + 1'b1;
                reciprocal_commit <= reciprocal_commit + 1'b1;
            end

            if (row_fire) begin
                if (descriptor_legal) begin
                    ctx_active[row_context_tag] <= 1'b1;
                    ctx_closing[row_context_tag] <= 1'b0;
                    ctx_error[row_context_tag] <= 1'b0;
                    ctx_epoch[row_context_tag] <= row_epoch;
                    ctx_head[row_context_tag] <= row_global_q_head;
                    ctx_row[row_context_tag] <= row_index;
                    ctx_key_count[row_context_tag] <= row_key_count;
                    ctx_expected_key[row_context_tag] <= '0;
                    ctx_max_fixed[row_context_tag] <=
                        bf16_to_fixed(row_max_bf16);
                    ctx_sum_q15[row_context_tag] <= '0;
                    rows_issue <= rows_issue + 1'b1;
                    if (row_max_bf16[14:7] == 8'hff)
                        numeric_special_count <= numeric_special_count + 1'b1;
                end
            end

            if (calc_advance) begin
                calc_valid <= 1'b0;
                pending_valid <= 1'b1;
                pending_epoch <= calc_epoch;
                pending_context_tag <= calc_context_tag;
                pending_head <= calc_head;
                pending_row <= calc_row;
                pending_key <= calc_key;
                pending_weight_q15 <= selected_weight_q15;
                pending_last <= calc_last;
                pending_exp_counted <= !calc_mask;
                pending_sum_final <= selected_sum_next;
                ctx_sum_q15[calc_context_tag] <= selected_sum_next;
                weight_issue <= weight_issue + 1'b1;
                weight_result <= weight_result + 1'b1;
                if (!calc_mask) begin
                    exp_issue <= exp_issue + 1'b1;
                    exp_result <= exp_result + 1'b1;
                    sum_issue <= sum_issue + 1'b1;
                    sum_result <= sum_result + 1'b1;
                end
                if (calc_last) begin
                    ctx_closing[calc_context_tag] <= 1'b1;
                    rows_result <= rows_result + 1'b1;
                end
            end

            if (score_fire && score_transfer_legal) begin
                calc_valid <= 1'b1;
                calc_epoch <= score_epoch;
                calc_context_tag <= score_context_tag;
                calc_head <= score_global_q_head;
                calc_row <= score_row;
                calc_key <= score_key;
                calc_score_fixed <= score_fixed;
                calc_sum_base <= (calc_advance &&
                                  calc_context_tag == score_context_tag) ?
                                 selected_sum_next :
                                 ctx_sum_q15[score_context_tag];
                calc_mask <= score_mask;
                calc_last <= score_last;
                if (!score_last)
                    ctx_expected_key[score_context_tag] <= score_key + 1'b1;
                if (score_bf16[14:7] == 8'hff)
                    numeric_special_count <= numeric_special_count + 1'b1;
            end

            if (weight_fire) begin
                weight_commit <= weight_commit + 1'b1;
                if (weight_exp_counted_reg) begin
                    exp_commit <= exp_commit + 1'b1;
                    sum_commit <= sum_commit + 1'b1;
                end
            end

            if (divider_start) begin
                div_meta_valid <= 1'b1;
                div_epoch <= weight_epoch_reg;
                div_context_tag <= weight_context_tag_reg;
                div_head <= weight_head_reg;
                div_row <= weight_row_reg;
                div_sum <= weight_sum_final_reg;
                div_error <= ctx_error[weight_context_tag_reg] ||
                             (weight_sum_final_reg == 0);
                reciprocal_issue <= reciprocal_issue + 1'b1;
            end

            if (divider_done && div_meta_valid) begin
                div_meta_valid <= 1'b0;
                done_valid_reg <= 1'b1;
                done_epoch_reg <= div_epoch;
                done_context_tag_reg <= div_context_tag;
                done_head_reg <= div_head;
                done_row_reg <= div_row;
                done_sum_reg <= div_sum;
                done_reciprocal_q30_reg <=
                    divider_by_zero ? 31'd0 : divider_quotient[30:0];
                done_reciprocal_fp32_reg <=
                    divider_by_zero ? 32'd0 :
                    q30_to_fp32(divider_quotient[30:0]);
                done_error_reg <= div_error || divider_by_zero;
                reciprocal_result <= reciprocal_result + 1'b1;
            end

            if (weight_valid_reg && !weight_ready)
                output_stall_cycles <= output_stall_cycles + 1'b1;
            if (score_valid && score_last &&
                (!last_resource_free ||
                 (weight_valid_reg && !weight_ready)))
                reciprocal_busy_stall_cycles <=
                    reciprocal_busy_stall_cycles + 1'b1;

            if ((row_fire && !descriptor_legal) ||
                (score_fire && !score_transfer_legal)) begin
                protocol_error_sticky <= 1'b1;
                if ((row_fire && !descriptor_legal) &&
                    (score_fire && !score_transfer_legal))
                    protocol_error_count <= protocol_error_count + 2'd2;
                else
                    protocol_error_count <= protocol_error_count + 1'b1;
                if (score_fire && score_token_legal)
                    ctx_error[score_context_tag] <= 1'b1;
            end
        end
    end

    initial begin
        if (SEQ_LEN != 128)
            $error("cats_r4_row_softmax_compatibility requires S=128");
        if (CONTEXTS != 16)
            $error("cats_r4_row_softmax_compatibility requires R=16");
        if (SCORE_FRAC < 7)
            $error("cats_r4_row_softmax_compatibility requires SCORE_FRAC>=7");
    end

    logic unused_divider_remainder;
    assign unused_divider_remainder = |divider_remainder;
endmodule
