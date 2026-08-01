`timescale 1ns/1ps

// Fused tile-online Softmax and streaming Context accumulator.
//
// One launch consumes one 4Q/1KV GQA group in the legacy QK coordinate order:
//   head -> query-row tile -> key-column tile -> local row -> local column.
// A complete probability matrix is never produced or stored.  For each score
// tile the module updates the running maximum m, the Q1.15 denominator l and
// a banked FP32 Context numerator O.  At the end of a query-row tile only O/l
// is emitted.
module online_softmax_context_tile #(
    parameter int TILE       = 4,
    parameter int SEQ_LEN    = 128,
    parameter int HEAD_DIM   = 128,
    parameter int Q_HEADS    = 4,
    parameter int GQA_GROUPS = 8,
    parameter int SCORE_W    = 32,
    parameter int SCORE_FRAC = 20,
    parameter int HEAD_W     = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W    = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int POS_W      = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W      = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int V_ADDR_W   = ((GQA_GROUPS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
                              $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter EXP_LUT_FILE   = "exp_lut_q15.mem"
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       start,
    input  logic [GROUP_W-1:0]         group_id,
    input  logic                       causal_en,
    output logic                       start_ready,
    output logic                       busy,
    output logic                       done,

    input  logic                       score_valid,
    output logic                       score_ready,
    input  logic [15:0]                score_bf16,
    input  logic [HEAD_W-1:0]          score_head,
    input  logic [POS_W-1:0]           score_row,
    input  logic [POS_W-1:0]           score_col,
    input  logic                       score_global_last,

    output logic                       v_req_valid,
    input  logic                       v_req_ready,
    output logic [V_ADDR_W-1:0]        v_req_addr,
    input  logic                       v_rsp_valid,
    output logic                       v_rsp_ready,
    input  logic [TILE*16-1:0]         v_rsp_data,

    output logic                       context_valid,
    input  logic                       context_ready,
    output logic [15:0]                context_bf16,
    output logic [31:0]                context_fp32_debug,
    output logic [GROUP_W-1:0]         context_group_id,
    output logic [HEAD_W-1:0]          context_head,
    output logic [POS_W-1:0]           context_row,
    output logic [DIM_W-1:0]           context_col,
    output logic                       context_group_last,

    output logic [31:0]                online_tiles_processed,
    output logic [31:0]                online_tiles_skipped,
    output logic [31:0]                online_rescale_events,
    output logic [31:0]                online_v_vectors_read,
    output logic [31:0]                online_mac_terms,
    output logic                       order_error,
    output logic                       numeric_error
);
    localparam int SCORE_ITEMS = TILE*TILE;
    localparam int SCORE_IDX_W = (SCORE_ITEMS <= 1) ? 1 : $clog2(SCORE_ITEMS);
    localparam int FEATURE_TILES = HEAD_DIM/TILE;
    localparam int FEATURE_W = (FEATURE_TILES <= 1) ? 1 : $clog2(FEATURE_TILES);
    localparam int LOCAL_W = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int SUM_W = 16 + $clog2(SEQ_LEN + 1);
    localparam int EXP_ADDR_SHIFT = SCORE_FRAC - 6;
    localparam logic signed [SCORE_W:0] EXP_LIMIT_FIXED = 8 <<< SCORE_FRAC;
    localparam logic signed [SCORE_W:0] EXP_ROUND_BIAS =
        1 <<< (EXP_ADDR_SHIFT-1);
    localparam logic [7:0] BF16_SHIFT_BIAS = 134 - SCORE_FRAC;
    localparam logic [7:0] BF16_SAT_EXP =
        (134 - SCORE_FRAC) + SCORE_W - 8;
    localparam logic [7:0] BF16_ZERO_EXP = (134 - SCORE_FRAC) - 9;
    localparam int PE_COUNT = TILE*TILE;

    localparam logic [1:0] OP_SCALE = 2'd0;
    localparam logic [1:0] OP_MAC   = 2'd1;
    localparam logic [1:0] OP_NORM  = 2'd2;

    typedef enum logic [4:0] {
        S_IDLE,
        S_CLEAR_CONTEXT,
        S_COLLECT,
        S_PREPARE,
        S_ALPHA,
        S_WEIGHT,
        S_UPDATE_STATE,
        S_PE_LOAD,
        S_SCALE_ISSUE,
        S_SCALE_WAIT,
        S_V_REQ,
        S_V_WAIT,
        S_MAC_ISSUE,
        S_MAC_WAIT,
        S_STORE_FEATURE,
        S_COMMIT_BLOCK,
        S_DIV_START,
        S_DIV_WAIT,
        S_NORM_LOAD,
        S_NORM_ISSUE,
        S_NORM_WAIT,
        S_OUTPUT
    } state_t;

    state_t state;
    logic [GROUP_W-1:0] group_reg;
    logic causal_reg;

    logic [HEAD_W-1:0] expected_head;
    logic [POS_W-1:0] expected_row_base;
    logic [POS_W-1:0] expected_col_base;
    logic [SCORE_IDX_W-1:0] score_index;

    logic signed [SCORE_W-1:0] score_mem [0:SCORE_ITEMS-1];
    logic score_mask [0:SCORE_ITEMS-1];

    logic signed [SCORE_W-1:0] running_max [0:TILE-1];
    logic signed [SCORE_W-1:0] next_max [0:TILE-1];
    logic [TILE-1:0] row_initialized;
    logic [TILE-1:0] row_block_valid;
    logic block_any_valid;
    logic [$clog2(TILE+1)-1:0] block_rescale_count;
    logic [$clog2(SCORE_ITEMS+1)-1:0] block_valid_score_count;

    logic [SUM_W-1:0] running_sum [0:TILE-1];
    logic [SUM_W-1:0] block_sum [0:TILE-1];
    logic [SUM_W-1:0] updated_sum [0:TILE-1];
    logic [15:0] alpha_q15 [0:TILE-1];
    logic [15:0] weight_q15 [0:TILE-1][0:TILE-1];

    logic [LOCAL_W-1:0] calc_col;
    logic [LOCAL_W-1:0] reduce_local;
    logic [FEATURE_W-1:0] feature_tile;
    logic [FEATURE_W-1:0] clear_feature;
    logic need_scale;

    logic [31:0] context_read_data [0:PE_COUNT-1];

    logic [TILE*16-1:0] v_data_reg;

    logic [PE_COUNT-1:0] pe_ready;
    logic [PE_COUNT-1:0] pe_result_valid;
    logic [PE_COUNT-1:0] pe_result_ready;
    logic [31:0] pe_acc [0:PE_COUNT-1];
    logic [31:0] pe_result [0:PE_COUNT-1];
    logic [31:0] normalized_result [0:PE_COUNT-1];
    logic [3:0] output_index;

    logic pe_clear;
    logic pe_load_acc;
    logic pe_op_valid;
    logic [1:0] pe_op_kind;
    logic [15:0] pe_factor [0:PE_COUNT-1];
    logic [15:0] pe_value [0:PE_COUNT-1];
    logic all_pe_ready;
    logic all_pe_results;

    logic [9:0] exp_addr [0:TILE-1];
    logic [15:0] exp_data [0:TILE-1];
    logic exp_forced_zero [0:TILE-1];

    logic div_start;
    logic [TILE-1:0] div_done;
    logic [TILE-1:0] div_zero;
    logic [45:0] div_quotient [0:TILE-1];
    logic [SUM_W-1:0] div_remainder [0:TILE-1];
    logic [15:0] reciprocal_bf16 [0:TILE-1];

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
            if (exponent == 8'h00) begin
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
                    magnitude = {{(SCORE_W-8){1'b0}}, significand}
                                << left_shift;
                end else begin
                    right_shift = BF16_SHIFT_BIAS - exponent;
                    rounded_significand = {1'b0, significand} +
                                          (9'd1 << (right_shift-1'b1));
                    magnitude = rounded_significand >> right_shift;
                end
                bf16_to_fixed = sign_bit ? -$signed(magnitude)
                                         :  $signed(magnitude);
            end
        end
    endfunction

    function automatic logic [15:0] q15_to_bf16(input logic [15:0] value);
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
            if (value == 0) begin
                q15_to_bf16 = 16'h0000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 16; k = k + 1)
                    if (value[k]) msb_index = k;
                exponent_biased = msb_index + 112;
                shift_left = 15-msb_index;
                normalized = {16'd0, value} << shift_left;
                fraction7 = normalized[14:8];
                round_bit = normalized[7];
                sticky_bit = |normalized[6:0];
                rounded_fraction = {1'b0, fraction7};
                if (round_bit && (sticky_bit || fraction7[0]))
                    rounded_fraction = rounded_fraction + 1'b1;
                if (rounded_fraction[7])
                    q15_to_bf16 = {1'b0, exponent_biased+1'b1, 7'd0};
                else
                    q15_to_bf16 = {1'b0, exponent_biased,
                                   rounded_fraction[6:0]};
            end
        end
    endfunction

    function automatic logic [15:0] uq30_to_bf16(input logic [30:0] value);
        integer msb_index;
        integer shift_left;
        integer k;
        logic [61:0] normalized;
        logic [6:0] fraction7;
        logic round_bit;
        logic sticky_bit;
        logic [7:0] rounded_fraction;
        logic [7:0] exponent_biased;
        begin
            if (value == 0) begin
                uq30_to_bf16 = 16'h0000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 31; k = k + 1)
                    if (value[k]) msb_index = k;
                exponent_biased = 127 + msb_index - 30;
                shift_left = 30-msb_index;
                normalized = {31'd0, value} << shift_left;
                fraction7 = normalized[29:23];
                round_bit = normalized[22];
                sticky_bit = |normalized[21:0];
                rounded_fraction = {1'b0, fraction7};
                if (round_bit && (sticky_bit || fraction7[0]))
                    rounded_fraction = rounded_fraction + 1'b1;
                if (rounded_fraction[7])
                    uq30_to_bf16 = {1'b0, exponent_biased+1'b1, 7'd0};
                else
                    uq30_to_bf16 = {1'b0, exponent_biased,
                                    rounded_fraction[6:0]};
            end
        end
    endfunction

    function automatic logic [15:0] fp32_to_bf16(input logic [31:0] value);
        logic round_up;
        logic [16:0] rounded;
        begin
            round_up = value[15] && (|value[14:0] || value[16]);
            rounded = {1'b0, value[31:16]} + round_up;
            fp32_to_bf16 = rounded[15:0];
        end
    endfunction

    // Candidate maxima and exact causal masks are evaluated after a complete
    // 4x4 score tile has been accepted.
    always_comb begin : BUILD_BLOCK_METADATA
        integer rr;
        integer cc;
        block_any_valid = 1'b0;
        block_rescale_count = '0;
        block_valid_score_count = '0;
        for (rr = 0; rr < TILE; rr = rr + 1) begin
            next_max[rr] = running_max[rr];
            row_block_valid[rr] = 1'b0;
            for (cc = 0; cc < TILE; cc = cc + 1) begin
                if (!score_mask[rr*TILE+cc]) begin
                    block_any_valid = 1'b1;
                    block_valid_score_count = block_valid_score_count + 1'b1;
                    if (!row_block_valid[rr] ||
                        (score_mem[rr*TILE+cc] > next_max[rr]))
                        next_max[rr] = score_mem[rr*TILE+cc];
                    row_block_valid[rr] = 1'b1;
                end
            end
            if (row_initialized[rr] && row_block_valid[rr] &&
                (next_max[rr] > running_max[rr]))
                block_rescale_count = block_rescale_count + 1'b1;
        end
    end

    // Four LUT copies evaluate one row each.  The same copies are time-shared
    // between the alpha rescale and four score columns.
    generate
        genvar lr;
        for (lr = 0; lr < TILE; lr = lr + 1) begin : GEN_EXP_LUT
            exp_lut #(.INIT_FILE(EXP_LUT_FILE)) u_lut (
                .addr(exp_addr[lr]), .data(exp_data[lr])
            );
        end
    endgenerate

    always_comb begin : BUILD_EXP_REQUESTS
        integer rr;
        for (rr = 0; rr < TILE; rr = rr + 1) begin
            logic signed [SCORE_W:0] delta;
            logic signed [SCORE_W:0] rounded_delta;
            delta = '0;
            exp_forced_zero[rr] = 1'b0;
            if (state == S_ALPHA) begin
                if (!row_initialized[rr])
                    exp_forced_zero[rr] = 1'b1;
                else if (row_block_valid[rr])
                    delta = $signed({next_max[rr][SCORE_W-1], next_max[rr]}) -
                            $signed({running_max[rr][SCORE_W-1], running_max[rr]});
                else
                    delta = '0;
            end else begin
                if (score_mask[rr*TILE+calc_col])
                    exp_forced_zero[rr] = 1'b1;
                else
                    delta = $signed({next_max[rr][SCORE_W-1], next_max[rr]}) -
                            $signed({score_mem[rr*TILE+calc_col][SCORE_W-1],
                                     score_mem[rr*TILE+calc_col]});
            end
            rounded_delta = delta + EXP_ROUND_BIAS;
            if (delta <= 0)
                exp_addr[rr] = 10'd0;
            else if (delta > EXP_LIMIT_FIXED) begin
                exp_addr[rr] = 10'd0;
                exp_forced_zero[rr] = 1'b1;
            end else
                exp_addr[rr] = $unsigned(rounded_delta) >> EXP_ADDR_SHIFT;
        end
    end

    always_comb begin : BUILD_UPDATED_SUM
        integer rr;
        for (rr = 0; rr < TILE; rr = rr + 1) begin
            logic [SUM_W+15:0] scaled_product;
            scaled_product = running_sum[rr] * alpha_q15[rr];
            updated_sum[rr] =
                ((scaled_product + (1 << 14)) >> 15) + block_sum[rr];
        end
    end

    assign all_pe_ready = &pe_ready;
    assign all_pe_results = &pe_result_valid;

    always_comb begin : DRIVE_CONTEXT_PES
        integer pp;
        pe_clear = (state == S_CLEAR_CONTEXT);
        pe_load_acc = (state == S_PE_LOAD) || (state == S_NORM_LOAD);
        pe_op_valid = (state == S_SCALE_ISSUE) ||
                      (state == S_MAC_ISSUE) ||
                      (state == S_NORM_ISSUE);
        pe_op_kind = OP_SCALE;
        if (state == S_MAC_ISSUE) pe_op_kind = OP_MAC;
        if (state == S_NORM_ISSUE) pe_op_kind = OP_NORM;
        pe_result_ready = (state == S_NORM_WAIT && all_pe_results) ?
                          {PE_COUNT{1'b1}} : '0;
        for (pp = 0; pp < PE_COUNT; pp = pp + 1) begin
            pe_factor[pp] = 16'h3F80;
            pe_value[pp] = 16'h0000;
            if (state == S_SCALE_ISSUE)
                pe_factor[pp] = q15_to_bf16(alpha_q15[pp/TILE]);
            else if (state == S_MAC_ISSUE) begin
                pe_factor[pp] = q15_to_bf16(
                    weight_q15[pp/TILE][reduce_local]
                );
                pe_value[pp] = v_data_reg[(pp%TILE)*16 +: 16];
            end else if (state == S_NORM_ISSUE)
                pe_factor[pp] = reciprocal_bf16[pp/TILE];
        end
    end

    generate
        genvar gp;
        for (gp = 0; gp < PE_COUNT; gp = gp + 1) begin : GEN_CONTEXT_PE
            online_context_bank #(
                .DEPTH(FEATURE_TILES),
                .ADDR_W(FEATURE_W)
            ) u_context_bank (
                .clk(clk),
                .clear_write(state == S_CLEAR_CONTEXT),
                .clear_addr(clear_feature),
                .write_en(state == S_STORE_FEATURE),
                .write_addr(feature_tile),
                .write_data(pe_acc[gp]),
                .read_addr(feature_tile),
                .read_data(context_read_data[gp])
            );

            online_context_pe u_pe (
                .clk(clk), .rst_n(rst_n), .clear(pe_clear),
                .load_acc(pe_load_acc),
                .load_acc_fp32(context_read_data[gp]),
                .op_valid(pe_op_valid), .op_ready(pe_ready[gp]),
                .op_kind(pe_op_kind), .factor_bf16(pe_factor[gp]),
                .value_bf16(pe_value[gp]), .acc_fp32(pe_acc[gp]),
                .result_valid(pe_result_valid[gp]),
                .result_ready(pe_result_ready[gp]),
                .result_fp32(pe_result[gp])
            );
        end
    endgenerate

    assign div_start = (state == S_DIV_START);
    generate
        genvar gd;
        for (gd = 0; gd < TILE; gd = gd + 1) begin : GEN_DIVIDER
            logic div_busy_unused;
            unsigned_restoring_divider #(
                .NUM_W(46), .DEN_W(SUM_W)
            ) u_divider (
                .clk(clk), .rst_n(rst_n), .start(div_start),
                .numerator(46'd35184372088832),
                .denominator(running_sum[gd]),
                .busy(div_busy_unused), .done(div_done[gd]),
                .divide_by_zero(div_zero[gd]),
                .quotient(div_quotient[gd]),
                .remainder(div_remainder[gd])
            );
        end
    endgenerate

    assign start_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE);
    assign score_ready = (state == S_COLLECT);
    assign v_req_valid = (state == S_V_REQ);
    assign v_rsp_ready = (state == S_V_WAIT);
    assign v_req_addr =
        ($unsigned(group_reg) * SEQ_LEN * HEAD_DIM) +
        (($unsigned(expected_col_base) + $unsigned(reduce_local)) * HEAD_DIM) +
        ($unsigned(feature_tile) * TILE);

    assign context_valid = (state == S_OUTPUT);
    assign context_fp32_debug = normalized_result[output_index];
    assign context_bf16 = fp32_to_bf16(normalized_result[output_index]);
    assign context_group_id = group_reg;
    assign context_head = expected_head;
    assign context_row = expected_row_base + (output_index/TILE);
    assign context_col = ($unsigned(feature_tile)*TILE) +
                         (output_index%TILE);
    assign context_group_last =
        (expected_head == Q_HEADS-1) &&
        (expected_row_base == SEQ_LEN-TILE) &&
        (feature_tile == FEATURE_TILES-1) &&
        (output_index == PE_COUNT-1);

    always_ff @(posedge clk) begin : STATE_MACHINE
        integer rr;
        integer cc;
        integer pp;
        if (!rst_n) begin
            state <= S_IDLE;
            group_reg <= '0;
            causal_reg <= 1'b0;
            expected_head <= '0;
            expected_row_base <= '0;
            expected_col_base <= '0;
            score_index <= '0;
            calc_col <= '0;
            reduce_local <= '0;
            feature_tile <= '0;
            clear_feature <= '0;
            row_initialized <= '0;
            need_scale <= 1'b0;
            v_data_reg <= '0;
            output_index <= '0;
            done <= 1'b0;
            online_tiles_processed <= '0;
            online_tiles_skipped <= '0;
            online_rescale_events <= '0;
            online_v_vectors_read <= '0;
            online_mac_terms <= '0;
            order_error <= 1'b0;
            numeric_error <= 1'b0;
            for (rr = 0; rr < TILE; rr = rr + 1) begin
                running_max[rr] <= {1'b1, {(SCORE_W-1){1'b0}}};
                running_sum[rr] <= '0;
                block_sum[rr] <= '0;
                alpha_q15[rr] <= '0;
                reciprocal_bf16[rr] <= '0;
                for (cc = 0; cc < TILE; cc = cc + 1)
                    weight_q15[rr][cc] <= '0;
            end
            for (pp = 0; pp < PE_COUNT; pp = pp + 1)
                normalized_result[pp] <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        group_reg <= group_id;
                        causal_reg <= causal_en;
                        expected_head <= '0;
                        expected_row_base <= '0;
                        expected_col_base <= '0;
                        score_index <= '0;
                        clear_feature <= '0;
                        row_initialized <= '0;
                        order_error <= 1'b0;
                        numeric_error <= 1'b0;
                        online_tiles_processed <= '0;
                        online_tiles_skipped <= '0;
                        online_rescale_events <= '0;
                        online_v_vectors_read <= '0;
                        online_mac_terms <= '0;
                        for (rr = 0; rr < TILE; rr = rr + 1) begin
                            running_max[rr] <=
                                {1'b1, {(SCORE_W-1){1'b0}}};
                            running_sum[rr] <= '0;
                        end
                        state <= S_CLEAR_CONTEXT;
                    end
                end

                S_CLEAR_CONTEXT: begin
                    if (clear_feature == FEATURE_TILES-1) begin
                        clear_feature <= '0;
                        state <= S_COLLECT;
                    end else
                        clear_feature <= clear_feature + 1'b1;
                end

                S_COLLECT: begin
                    if (score_valid && score_ready) begin
                        if ((score_head != expected_head) ||
                            (score_row != expected_row_base +
                                          (score_index/TILE)) ||
                            (score_col != expected_col_base +
                                          (score_index%TILE)))
                            order_error <= 1'b1;

                        if (score_global_last !=
                            ((expected_head == Q_HEADS-1) &&
                             (expected_row_base == SEQ_LEN-TILE) &&
                             (expected_col_base == SEQ_LEN-TILE) &&
                             (score_index == SCORE_ITEMS-1)))
                            order_error <= 1'b1;

                        score_mem[score_index] <= bf16_to_fixed(score_bf16);
                        score_mask[score_index] <=
                            (causal_reg &&
                             ($unsigned(score_col) > $unsigned(score_row))) ||
                            (score_bf16 == 16'hFF80);

                        if (score_index == SCORE_ITEMS-1) begin
                            score_index <= '0;
                            state <= S_PREPARE;
                        end else
                            score_index <= score_index + 1'b1;
                    end
                end

                S_PREPARE: begin
                    for (rr = 0; rr < TILE; rr = rr + 1) begin
                        block_sum[rr] <= '0;
                        for (cc = 0; cc < TILE; cc = cc + 1)
                            weight_q15[rr][cc] <= '0;
                    end
                    if (block_any_valid)
                        online_tiles_processed <= online_tiles_processed + 1'b1;
                    else
                        online_tiles_skipped <= online_tiles_skipped + 1'b1;
                    calc_col <= '0;
                    state <= S_ALPHA;
                end

                S_ALPHA: begin
                    for (rr = 0; rr < TILE; rr = rr + 1) begin
                        alpha_q15[rr] <= exp_forced_zero[rr] ? 16'd0
                                                            : exp_data[rr];
                    end
                    online_rescale_events <= online_rescale_events +
                                             block_rescale_count;
                    calc_col <= '0;
                    state <= S_WEIGHT;
                end

                S_WEIGHT: begin
                    for (rr = 0; rr < TILE; rr = rr + 1) begin
                        weight_q15[rr][calc_col] <=
                            exp_forced_zero[rr] ? 16'd0 : exp_data[rr];
                        block_sum[rr] <= block_sum[rr] +
                            (exp_forced_zero[rr] ? 16'd0 : exp_data[rr]);
                    end
                    if (calc_col == TILE-1)
                        state <= S_UPDATE_STATE;
                    else
                        calc_col <= calc_col + 1'b1;
                end

                S_UPDATE_STATE: begin
                    for (rr = 0; rr < TILE; rr = rr + 1) begin
                        if (row_block_valid[rr]) begin
                            running_max[rr] <= next_max[rr];
                            row_initialized[rr] <= 1'b1;
                        end
                        running_sum[rr] <= updated_sum[rr];
                    end
                    online_mac_terms <= online_mac_terms +
                                        block_valid_score_count*HEAD_DIM;
                    need_scale <= |row_initialized;
                    feature_tile <= '0;
                    reduce_local <= '0;
                    if (block_any_valid)
                        state <= S_PE_LOAD;
                    else if (expected_col_base == SEQ_LEN-TILE)
                        state <= S_DIV_START;
                    else
                        state <= S_COMMIT_BLOCK;
                end

                S_PE_LOAD: begin
                    if (need_scale)
                        state <= S_SCALE_ISSUE;
                    else
                        state <= S_V_REQ;
                end

                S_SCALE_ISSUE: begin
                    if (all_pe_ready)
                        state <= S_SCALE_WAIT;
                end

                S_SCALE_WAIT: begin
                    if (all_pe_ready) begin
                        reduce_local <= '0;
                        state <= S_V_REQ;
                    end
                end

                S_V_REQ: begin
                    if (v_req_valid && v_req_ready)
                        state <= S_V_WAIT;
                end

                S_V_WAIT: begin
                    if (v_rsp_valid && v_rsp_ready) begin
                        v_data_reg <= v_rsp_data;
                        online_v_vectors_read <= online_v_vectors_read + 1'b1;
                        state <= S_MAC_ISSUE;
                    end
                end

                S_MAC_ISSUE: begin
                    if (all_pe_ready)
                        state <= S_MAC_WAIT;
                end

                S_MAC_WAIT: begin
                    if (all_pe_ready) begin
                        if (reduce_local == TILE-1)
                            state <= S_STORE_FEATURE;
                        else begin
                            reduce_local <= reduce_local + 1'b1;
                            state <= S_V_REQ;
                        end
                    end
                end

                S_STORE_FEATURE: begin
                    if (feature_tile == FEATURE_TILES-1) begin
                        if (expected_col_base == SEQ_LEN-TILE)
                            state <= S_DIV_START;
                        else
                            state <= S_COMMIT_BLOCK;
                    end else begin
                        feature_tile <= feature_tile + 1'b1;
                        reduce_local <= '0;
                        state <= S_PE_LOAD;
                    end
                end

                S_COMMIT_BLOCK: begin
                    expected_col_base <= expected_col_base + TILE;
                    state <= S_COLLECT;
                end

                S_DIV_START: begin
                    for (rr = 0; rr < TILE; rr = rr + 1)
                        if (!row_initialized[rr] || (running_sum[rr] == 0))
                            numeric_error <= 1'b1;
                    state <= S_DIV_WAIT;
                end

                S_DIV_WAIT: begin
                    if (&div_done) begin
                        for (rr = 0; rr < TILE; rr = rr + 1) begin
                            reciprocal_bf16[rr] <=
                                uq30_to_bf16(div_quotient[rr][30:0]);
                            if (div_zero[rr]) numeric_error <= 1'b1;
                        end
                        feature_tile <= '0;
                        state <= S_NORM_LOAD;
                    end
                end

                S_NORM_LOAD: begin
                    state <= S_NORM_ISSUE;
                end

                S_NORM_ISSUE: begin
                    if (all_pe_ready)
                        state <= S_NORM_WAIT;
                end

                S_NORM_WAIT: begin
                    if (all_pe_results) begin
                        for (pp = 0; pp < PE_COUNT; pp = pp + 1)
                            normalized_result[pp] <= pe_result[pp];
                        output_index <= '0;
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    if (context_valid && context_ready) begin
                        if (output_index == PE_COUNT-1) begin
                            if (feature_tile == FEATURE_TILES-1) begin
                                if ((expected_head == Q_HEADS-1) &&
                                    (expected_row_base == SEQ_LEN-TILE)) begin
                                    done <= 1'b1;
                                    state <= S_IDLE;
                                end else begin
                                    expected_col_base <= '0;
                                    if (expected_row_base == SEQ_LEN-TILE) begin
                                        expected_row_base <= '0;
                                        expected_head <= expected_head + 1'b1;
                                    end else
                                        expected_row_base <=
                                            expected_row_base + TILE;
                                    clear_feature <= '0;
                                    row_initialized <= '0;
                                    for (rr = 0; rr < TILE; rr = rr + 1) begin
                                        running_max[rr] <=
                                            {1'b1, {(SCORE_W-1){1'b0}}};
                                        running_sum[rr] <= '0;
                                    end
                                    state <= S_CLEAR_CONTEXT;
                                end
                            end else begin
                                feature_tile <= feature_tile + 1'b1;
                                state <= S_NORM_LOAD;
                            end
                        end else
                            output_index <= output_index + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (TILE != 4)
            $error("online_softmax_context_tile: TILE must equal 4");
        if ((SEQ_LEN % TILE) != 0 || (HEAD_DIM % TILE) != 0)
            $error("online_softmax_context_tile: TILE must divide dimensions");
        if (SCORE_FRAC < 7)
            $error("online_softmax_context_tile: SCORE_FRAC must be >= 7");
    end
endmodule
