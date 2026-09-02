`timescale 1ns/1ps

// Tile-wise Online Softmax front end for FlashAttention.
//
// Input and output tiles use row-major packing.  Four EXP LUT replicas process
// one tile column per cycle.  Per-row running maximum m and denominator l are
// retained across key tiles; l is unsigned Q*.15 and is rescaled with RNE:
//
//   m' = max(m, tile_max)
//   alpha = exp(m-m')
//   l' = round(l*alpha/2^15) + sum(exp(score-m'))
//
// The module requires increasing col_base values for one row tile and starts a
// new state epoch at col_base==0.  Output is fully elastic and stable while
// stalled.
module flash_online_softmax_frontend #(
    parameter int TILE        = 4,
    parameter int SEQ_LEN     = 128,
    parameter int SCORE_W     = 24,
    parameter int SCORE_FRAC  = 14,
    parameter int Q_HEADS     = 4,
    parameter int GQA_GROUPS  = 8,
    parameter int HEAD_W      = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W     = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int POS_W       = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int L_W         = 16 + $clog2(SEQ_LEN + 1),
    parameter EXP_LUT_FILE    = "exp_lut_q15.mem"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic                      in_valid,
    output logic                      in_ready,
    input  logic [TILE*TILE*16-1:0]   in_scores_bf16,
    input  logic [TILE*TILE-1:0]      in_masks,
    input  logic [GROUP_W-1:0]        in_group,
    input  logic [HEAD_W-1:0]         in_head,
    input  logic [POS_W-1:0]          in_row_base,
    input  logic [POS_W-1:0]          in_col_base,
    input  logic                      in_group_last,

    output logic                      out_valid,
    input  logic                      out_ready,
    output logic [TILE*TILE*16-1:0]   out_weights_q15,
    output logic [TILE*16-1:0]        out_alpha_q15,
    output logic [TILE*L_W-1:0]       out_l_q15,
    output logic [TILE-1:0]           out_row_active,
    output logic [GROUP_W-1:0]        out_group,
    output logic [HEAD_W-1:0]         out_head,
    output logic [POS_W-1:0]          out_row_base,
    output logic [POS_W-1:0]          out_col_base,
    output logic                      out_row_tile_last,
    output logic                      out_group_last,

    output logic                      busy,
    output logic                      protocol_error,
    output logic [31:0]               tiles_processed
);
    localparam int ITEMS = TILE*TILE;
    localparam int COL_W = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int EXP_ADDR_SHIFT = SCORE_FRAC - 6;
    localparam logic signed [SCORE_W:0] EXP_LIMIT_FIXED = 8 <<< SCORE_FRAC;
    localparam logic signed [SCORE_W:0] EXP_ROUND_BIAS =
        1 <<< (EXP_ADDR_SHIFT-1);
    localparam logic [7:0] BF16_SHIFT_BIAS = 134 - SCORE_FRAC;
    localparam logic [7:0] BF16_SAT_EXP =
        (134 - SCORE_FRAC) + SCORE_W - 8;
    localparam logic [7:0] BF16_ZERO_EXP = (134 - SCORE_FRAC) - 9;

    typedef enum logic [2:0] {
        ST_IDLE, ST_PREP, ST_ALPHA, ST_WEIGHT, ST_OUTPUT
    } state_t;
    state_t state;

    logic signed [SCORE_W-1:0] score_reg [0:ITEMS-1];
    logic [ITEMS-1:0] mask_reg;
    logic signed [SCORE_W-1:0] row_m [0:TILE-1];
    logic [L_W-1:0] row_l [0:TILE-1];
    logic [TILE-1:0] row_have;

    logic signed [SCORE_W-1:0] work_old_m [0:TILE-1];
    logic signed [SCORE_W-1:0] work_new_m [0:TILE-1];
    logic [L_W-1:0] work_old_l [0:TILE-1];
    logic [TILE-1:0] work_old_have;
    logic [TILE-1:0] work_have;
    logic [15:0] work_alpha [0:TILE-1];
    logic [L_W-1:0] tile_sum [0:TILE-1];
    logic [ITEMS*16-1:0] work_weights;
    logic [COL_W-1:0] weight_col;

    logic [GROUP_W-1:0] meta_group;
    logic [HEAD_W-1:0] meta_head;
    logic [POS_W-1:0] meta_row;
    logic [POS_W-1:0] meta_col;
    logic meta_group_last;
    logic [GROUP_W-1:0] active_group;
    logic [HEAD_W-1:0] active_head;
    logic [POS_W-1:0] active_row;
    logic [POS_W-1:0] expected_col;

    logic signed [SCORE_W-1:0] capture_fixed [0:ITEMS-1];
    logic signed [SCORE_W-1:0] capture_row_max [0:TILE-1];
    logic [TILE-1:0] capture_row_have;
    logic [9:0] lut_addr [0:TILE-1];
    logic [15:0] lut_data [0:TILE-1];
    logic [TILE-1:0] lut_forced_zero;
    logic [L_W-1:0] tile_sum_with_weight [0:TILE-1];
    logic [L_W+15:0] l_product_rounded [0:TILE-1];
    logic [L_W-1:0] l_scaled [0:TILE-1];
    logic [L_W-1:0] l_updated [0:TILE-1];
    logic [ITEMS*16-1:0] work_weights_next;

    logic [ITEMS*16-1:0] out_weights_reg;
    logic [TILE*16-1:0] out_alpha_reg;
    logic [TILE*L_W-1:0] out_l_reg;
    logic [TILE-1:0] out_row_active_reg;

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
                    magnitude = {{(SCORE_W-8){1'b0}}, significand} << left_shift;
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

    generate
        genvar gr;
        for (gr = 0; gr < TILE; gr = gr + 1) begin : g_exp_lut
            exp_lut #(.INIT_FILE(EXP_LUT_FILE)) u_exp_lut (
                .addr(lut_addr[gr]), .data(lut_data[gr])
            );
        end
    endgenerate

    always_comb begin : p_capture
        integer capture_item;
        integer capture_row;
        integer capture_col;
        for (capture_item = 0; capture_item < ITEMS;
             capture_item = capture_item + 1)
            capture_fixed[capture_item] =
                bf16_to_fixed(in_scores_bf16[capture_item*16 +: 16]);

        for (capture_row = 0; capture_row < TILE;
             capture_row = capture_row + 1) begin
            capture_row_have[capture_row] = 1'b0;
            capture_row_max[capture_row] = '0;
            for (capture_col = 0; capture_col < TILE;
                 capture_col = capture_col + 1) begin
                capture_item = capture_row*TILE+capture_col;
                if (!mask_reg[capture_item]) begin
                    if (!capture_row_have[capture_row] ||
                        (score_reg[capture_item] >
                         capture_row_max[capture_row]))
                        capture_row_max[capture_row] = score_reg[capture_item];
                    capture_row_have[capture_row] = 1'b1;
                end
            end
        end
    end

    always_comb begin : p_lut_address
        integer lut_row;
        integer lut_item;
        for (lut_row = 0; lut_row < TILE; lut_row = lut_row + 1) begin
            lut_addr[lut_row] = '0;
            lut_forced_zero[lut_row] = 1'b0;
            if (state == ST_ALPHA) begin
                if (!work_old_have[lut_row]) begin
                    lut_forced_zero[lut_row] = 1'b1;
                end else if (($signed({work_new_m[lut_row][SCORE_W-1], work_new_m[lut_row]}) -
                              $signed({work_old_m[lut_row][SCORE_W-1], work_old_m[lut_row]})) >
                             EXP_LIMIT_FIXED) begin
                    lut_forced_zero[lut_row] = 1'b1;
                end else begin
                    lut_addr[lut_row] = $unsigned(
                        ($signed({work_new_m[lut_row][SCORE_W-1], work_new_m[lut_row]}) -
                         $signed({work_old_m[lut_row][SCORE_W-1], work_old_m[lut_row]})) +
                        EXP_ROUND_BIAS) >> EXP_ADDR_SHIFT;
                end
            end else if (state == ST_WEIGHT) begin
                lut_item = lut_row*TILE + $unsigned(weight_col);
                if (!work_have[lut_row] || mask_reg[lut_item]) begin
                    lut_forced_zero[lut_row] = 1'b1;
                end else if (($signed({work_new_m[lut_row][SCORE_W-1], work_new_m[lut_row]}) -
                              $signed({score_reg[lut_item][SCORE_W-1], score_reg[lut_item]})) >
                             EXP_LIMIT_FIXED) begin
                    lut_forced_zero[lut_row] = 1'b1;
                end else begin
                    lut_addr[lut_row] = $unsigned(
                        ($signed({work_new_m[lut_row][SCORE_W-1], work_new_m[lut_row]}) -
                         $signed({score_reg[lut_item][SCORE_W-1], score_reg[lut_item]})) +
                        EXP_ROUND_BIAS) >> EXP_ADDR_SHIFT;
                end
            end
        end
    end

    always_comb begin : p_update_math
        integer update_row;
        integer update_item;
        work_weights_next = work_weights;
        for (update_row = 0; update_row < TILE;
             update_row = update_row + 1) begin
            update_item = update_row*TILE + $unsigned(weight_col);
            work_weights_next[update_item*16 +: 16] =
                lut_forced_zero[update_row] ? 16'd0 : lut_data[update_row];
            tile_sum_with_weight[update_row] = tile_sum[update_row] +
                (lut_forced_zero[update_row] ? 16'd0 : lut_data[update_row]);
            l_product_rounded[update_row] =
                work_old_l[update_row] * work_alpha[update_row] +
                                   (1 << 14);
            l_scaled[update_row] = l_product_rounded[update_row] >> 15;
            l_updated[update_row] = l_scaled[update_row] +
                                    tile_sum_with_weight[update_row];
        end
    end

    assign in_ready = (state == ST_IDLE);
    assign out_valid = (state == ST_OUTPUT);
    assign out_weights_q15 = out_weights_reg;
    assign out_alpha_q15 = out_alpha_reg;
    assign out_l_q15 = out_l_reg;
    assign out_row_active = out_row_active_reg;
    assign out_group = meta_group;
    assign out_head = meta_head;
    assign out_row_base = meta_row;
    assign out_col_base = meta_col;
    assign out_row_tile_last =
        ($unsigned(meta_col) == SEQ_LEN-TILE);
    assign out_group_last = meta_group_last;
    assign busy = (state != ST_IDLE);

    always_ff @(posedge clk) begin : p_sequential
        integer seq_index;
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            mask_reg <= '0;
            row_have <= '0;
            work_old_have <= '0;
            work_have <= '0;
            work_weights <= '0;
            weight_col <= '0;
            meta_group <= '0;
            meta_head <= '0;
            meta_row <= '0;
            meta_col <= '0;
            meta_group_last <= 1'b0;
            active_group <= '0;
            active_head <= '0;
            active_row <= '0;
            expected_col <= '0;
            out_weights_reg <= '0;
            out_alpha_reg <= '0;
            out_l_reg <= '0;
            out_row_active_reg <= '0;
            protocol_error <= 1'b0;
            tiles_processed <= '0;
            for (seq_index = 0; seq_index < ITEMS; seq_index = seq_index + 1)
                score_reg[seq_index] <= '0;
            for (seq_index = 0; seq_index < TILE; seq_index = seq_index + 1) begin
                row_m[seq_index] <= '0;
                row_l[seq_index] <= '0;
                work_old_m[seq_index] <= '0;
                work_new_m[seq_index] <= '0;
                work_old_l[seq_index] <= '0;
                work_alpha[seq_index] <= '0;
                tile_sum[seq_index] <= '0;
            end
        end else begin
            case (state)
                ST_IDLE: if (in_valid && in_ready) begin
                    mask_reg <= in_masks;
                    meta_group <= in_group;
                    meta_head <= in_head;
                    meta_row <= in_row_base;
                    meta_col <= in_col_base;
                    meta_group_last <= in_group_last;
                    work_weights <= '0;
                    weight_col <= '0;
                    for (seq_index = 0; seq_index < ITEMS; seq_index = seq_index + 1)
                        score_reg[seq_index] <= capture_fixed[seq_index];
                    state <= ST_PREP;
                end

                // Deliberately separate FIFO/BF16 capture from the four-way
                // row maximum and running-m selection.  This register boundary
                // keeps the scalar-score FIFO read path out of the max tree.
                ST_PREP: begin
                    for (seq_index = 0; seq_index < TILE; seq_index = seq_index + 1) begin
                        if ($unsigned(meta_col) == 0) begin
                            work_old_have[seq_index] <= 1'b0;
                            work_old_m[seq_index] <= '0;
                            work_old_l[seq_index] <= '0;
                            work_have[seq_index] <= capture_row_have[seq_index];
                            work_new_m[seq_index] <= capture_row_max[seq_index];
                        end else begin
                            work_old_have[seq_index] <= row_have[seq_index];
                            work_old_m[seq_index] <= row_m[seq_index];
                            work_old_l[seq_index] <= row_l[seq_index];
                            work_have[seq_index] <= row_have[seq_index] ||
                                                    capture_row_have[seq_index];
                            if (!row_have[seq_index])
                                work_new_m[seq_index] <= capture_row_max[seq_index];
                            else if (capture_row_have[seq_index] &&
                                     (capture_row_max[seq_index] > row_m[seq_index]))
                                work_new_m[seq_index] <= capture_row_max[seq_index];
                            else
                                work_new_m[seq_index] <= row_m[seq_index];
                        end
                        tile_sum[seq_index] <= '0;
                    end

                    if ($unsigned(meta_col) == 0) begin
                        active_group <= meta_group;
                        active_head <= meta_head;
                        active_row <= meta_row;
                    end else if ((meta_group != active_group) ||
                                 (meta_head != active_head) ||
                                 (meta_row != active_row) ||
                                 (meta_col != expected_col)) begin
                        protocol_error <= 1'b1;
                    end
                    if (($unsigned(meta_col) % TILE) != 0)
                        protocol_error <= 1'b1;
                    expected_col <= meta_col + TILE;
                    state <= ST_ALPHA;
                end

                ST_ALPHA: begin
                    for (seq_index = 0; seq_index < TILE; seq_index = seq_index + 1)
                        work_alpha[seq_index] <= lut_forced_zero[seq_index] ?
                                                 16'd0 : lut_data[seq_index];
                    state <= ST_WEIGHT;
                end

                ST_WEIGHT: begin
                    work_weights <= work_weights_next;
                    for (seq_index = 0; seq_index < TILE; seq_index = seq_index + 1)
                        tile_sum[seq_index] <= tile_sum_with_weight[seq_index];
                    if ($unsigned(weight_col) == TILE-1) begin
                        for (seq_index = 0; seq_index < TILE;
                             seq_index = seq_index + 1) begin
                            row_m[seq_index] <= work_new_m[seq_index];
                            row_l[seq_index] <= l_updated[seq_index];
                            row_have[seq_index] <= work_have[seq_index];
                            out_alpha_reg[seq_index*16 +: 16] <= work_alpha[seq_index];
                            out_l_reg[seq_index*L_W +: L_W] <= l_updated[seq_index];
                            out_row_active_reg[seq_index] <= work_have[seq_index];
                        end
                        out_weights_reg <= work_weights_next;
                        state <= ST_OUTPUT;
                    end else begin
                        weight_col <= weight_col + 1'b1;
                    end
                end

                ST_OUTPUT: if (out_valid && out_ready) begin
                    tiles_processed <= tiles_processed + 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

    initial begin
        if (TILE != 4)
            $error("flash_online_softmax_frontend: current implementation requires TILE=4");
        if ((SEQ_LEN % TILE) != 0)
            $error("flash_online_softmax_frontend: TILE must divide SEQ_LEN");
        if (SCORE_FRAC < 7)
            $error("flash_online_softmax_frontend: SCORE_FRAC must be >= 7");
    end
endmodule
