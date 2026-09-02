`timescale 1ns/1ps

// FlashAttention Context-Fusion backend.
//
// One accepted Online-Softmax tile is combined with the corresponding 4x8 V
// tile over all feature chunks.  Thirty-two update PEs maintain FP32 O state:
//
//   O' = alpha*O + W_tile*V_tile
//
// On the final key tile, four exact integer dividers form 1/l, the same PE
// array normalizes O, and Context is emitted in row-major order.  The V-cache
// interface reads eight adjacent BF16 features per response (V_LANES=8).
module flash_context_fusion_backend #(
    parameter int TILE        = 4,
    parameter int V_LANES     = 8,
    parameter int SEQ_LEN     = 128,
    parameter int HEAD_DIM    = 128,
    parameter int Q_HEADS     = 4,
    parameter int GQA_GROUPS  = 8,
    parameter int HEAD_W      = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W     = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_HEAD_W = ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
                                   $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W       = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W       = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int L_W         = 16 + $clog2(SEQ_LEN + 1),
    parameter int V_ADDR_W    = ((GQA_GROUPS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
                                $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic [TILE*TILE*16-1:0] in_weights_q15,
    input  logic [TILE*16-1:0]      in_alpha_q15,
    input  logic [TILE*L_W-1:0]     in_l_q15,
    input  logic [TILE-1:0]         in_row_active,
    input  logic [GROUP_W-1:0]      in_group,
    input  logic [HEAD_W-1:0]       in_head,
    input  logic [POS_W-1:0]        in_row_base,
    input  logic [POS_W-1:0]        in_col_base,
    input  logic                    in_row_tile_last,
    input  logic                    in_group_last,

    output logic                    v_req_valid,
    input  logic                    v_req_ready,
    output logic [V_ADDR_W-1:0]     v_req_addr,
    input  logic                    v_rsp_valid,
    output logic                    v_rsp_ready,
    input  logic [V_LANES*16-1:0]  v_rsp_data,

    output logic                    context_valid,
    input  logic                    context_ready,
    output logic [15:0]             context_bf16,
    output logic [31:0]             context_fp32_debug,
    output logic [GROUP_W-1:0]      context_group,
    output logic [HEAD_W-1:0]       context_head,
    output logic [GLOBAL_HEAD_W-1:0] context_global_head,
    output logic [POS_W-1:0]        context_row,
    output logic [DIM_W-1:0]        context_col,
    output logic                    context_last,

    output logic                    busy,
    output logic                    tile_done,
    output logic                    protocol_error,
    output logic [31:0]             tiles_processed,
    output logic [31:0]             v_vectors_read
);
    localparam int PE_COUNT = TILE*V_LANES;
    localparam int FEATURE_CHUNKS = HEAD_DIM/V_LANES;
    localparam int FEATURE_W = (FEATURE_CHUNKS <= 1) ? 1 :
                               $clog2(FEATURE_CHUNKS);
    localparam int KEY_W = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int CONTEXT_ITEMS = TILE*HEAD_DIM;
    localparam int EMIT_W = (CONTEXT_ITEMS <= 1) ? 1 :
                            $clog2(CONTEXT_ITEMS);
    localparam int RECIP_NUM_W = 46;

    typedef enum logic [3:0] {
        ST_IDLE, ST_V_REQ, ST_V_RSP, ST_UPDATE_START, ST_UPDATE_WAIT,
        ST_DIV_START, ST_DIV_WAIT, ST_NORM_START, ST_NORM_WAIT,
        ST_CONTEXT_OUT
    } state_t;
    state_t state;

    logic [TILE*TILE*16-1:0] weights_q15_reg;
    logic [TILE*16-1:0] alpha_q15_reg;
    logic [TILE*L_W-1:0] l_q15_reg;
    logic [TILE-1:0] row_active_reg;
    logic [GROUP_W-1:0] group_reg;
    logic [HEAD_W-1:0] head_reg;
    logic [POS_W-1:0] row_base_reg;
    logic [POS_W-1:0] col_base_reg;
    logic row_tile_last_reg;
    logic group_last_reg;

    logic [FEATURE_W-1:0] feature_chunk;
    logic [KEY_W-1:0] key_index;
    logic [EMIT_W-1:0] emit_index;
    logic [TILE*V_LANES*16-1:0] v_tile_reg;

    // Bank by physical PE: each of the TILE*V_LANES update lanes owns one
    // feature-chunk-deep memory.  Every bank has one read and one write in an
    // update cycle, avoiding the 32-write/32-read pseudo multi-port memory that
    // Vivado otherwise dissolves into a large FF/mux network.  A col_base==0
    // tile logically clears state by seeding the PEs with zero.
    logic [31:0] o_state_bank [0:PE_COUNT-1][0:FEATURE_CHUNKS-1];

    logic [PE_COUNT-1:0] pe_ready;
    logic [PE_COUNT-1:0] pe_result_valid;
    logic [PE_COUNT-1:0] pe_result_ready;
    logic [31:0] pe_result [0:PE_COUNT-1];
    logic [31:0] row_alpha_fp32 [0:TILE-1];
    logic [31:0] row_recip_fp32 [0:TILE-1];
    logic [TILE*16-1:0] row_weights_bf16 [0:TILE-1];
    logic [TILE*16-1:0] lane_values_bf16 [0:V_LANES-1];
    logic all_pe_ready;
    logic all_results_valid;
    logic pe_start;
    logic pe_normalize;

    logic [TILE-1:0] div_start;
    logic [TILE-1:0] div_done;
    logic [TILE-1:0] div_busy;
    logic [TILE-1:0] div_by_zero;
    logic [RECIP_NUM_W-1:0] div_quotient [0:TILE-1];
    logic [L_W-1:0] div_remainder [0:TILE-1];
    logic all_div_complete;

    integer address_value;

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

    function automatic logic [15:0] fp32_to_bf16(
        input logic [31:0] fp32_value
    );
        logic round_up;
        logic [16:0] rounded;
        begin
            round_up = fp32_value[15] &&
                       (|fp32_value[14:0] || fp32_value[16]);
            rounded = {1'b0, fp32_value[31:16]} + round_up;
            fp32_to_bf16 = rounded[15:0];
        end
    endfunction

    always_comb begin : p_pack_bf16
        integer pack_row;
        integer pack_key;
        integer pack_lane;
        for (pack_row = 0; pack_row < TILE; pack_row = pack_row + 1) begin
            row_alpha_fp32[pack_row] = {
                q15_to_bf16(alpha_q15_reg[pack_row*16 +: 16]), 16'd0
            };
            row_weights_bf16[pack_row] = '0;
            for (pack_key = 0; pack_key < TILE; pack_key = pack_key + 1)
                row_weights_bf16[pack_row][pack_key*16 +: 16] =
                    q15_to_bf16(weights_q15_reg[
                        (pack_row*TILE+pack_key)*16 +: 16]);
        end
        for (pack_lane = 0; pack_lane < V_LANES;
             pack_lane = pack_lane + 1) begin
            lane_values_bf16[pack_lane] = '0;
            for (pack_key = 0; pack_key < TILE; pack_key = pack_key + 1)
                lane_values_bf16[pack_lane][pack_key*16 +: 16] =
                    v_tile_reg[(pack_key*V_LANES+pack_lane)*16 +: 16];
        end
    end

    assign all_pe_ready = &pe_ready;
    assign all_results_valid = &pe_result_valid;
    assign pe_start = ((state == ST_UPDATE_START) ||
                       (state == ST_NORM_START)) && all_pe_ready;
    assign pe_normalize = (state == ST_NORM_START);
    assign pe_result_ready =
        {PE_COUNT{all_results_valid &&
                  ((state == ST_UPDATE_WAIT) || (state == ST_NORM_WAIT))}};

    generate
        genvar pr;
        genvar pl;
        for (pr = 0; pr < TILE; pr = pr + 1) begin : g_pe_row
            for (pl = 0; pl < V_LANES; pl = pl + 1) begin : g_pe_lane
                localparam int PE = pr*V_LANES+pl;
                wire [31:0] selected_old_o =
                    ((state == ST_UPDATE_START) &&
                     ($unsigned(col_base_reg) == 0)) ? 32'd0 :
                    o_state_bank[PE][$unsigned(feature_chunk)];
                flash_context_update_pe #(.TILE(TILE)) u_pe (
                    .clk, .rst_n, .clear,
                    .start(pe_start), .normalize(pe_normalize),
                    .alpha_fp32(pe_normalize ? row_recip_fp32[pr] :
                                               row_alpha_fp32[pr]),
                    .old_o_fp32(selected_old_o),
                    .weights_bf16(row_weights_bf16[pr]),
                    .values_bf16(lane_values_bf16[pl]),
                    .ready(pe_ready[PE]),
                    .result_valid(pe_result_valid[PE]),
                    .result_ready(pe_result_ready[PE]),
                    .result_fp32(pe_result[PE])
                );
            end
        end
    endgenerate

    generate
        genvar dr;
        for (dr = 0; dr < TILE; dr = dr + 1) begin : g_divider
            unsigned_restoring_divider #(
                .NUM_W(RECIP_NUM_W), .DEN_W(L_W)
            ) u_divider (
                .clk, .rst_n,
                .start(div_start[dr]),
                .numerator(46'd35184372088832),
                .denominator(l_q15_reg[dr*L_W +: L_W]),
                .busy(div_busy[dr]), .done(div_done[dr]),
                .divide_by_zero(div_by_zero[dr]),
                .quotient(div_quotient[dr]),
                .remainder(div_remainder[dr])
            );
        end
    endgenerate

    always_comb begin : p_divider_control
        integer div_row;
        div_start = '0;
        all_div_complete = 1'b1;
        for (div_row = 0; div_row < TILE; div_row = div_row + 1) begin
            if ((state == ST_DIV_START) && row_active_reg[div_row] &&
                (l_q15_reg[div_row*L_W +: L_W] != 0))
                div_start[div_row] = 1'b1;
            if (row_active_reg[div_row] &&
                (l_q15_reg[div_row*L_W +: L_W] != 0) &&
                !div_done[div_row])
                all_div_complete = 1'b0;
        end
    end

    always_comb begin
        address_value = ($unsigned(group_reg)*SEQ_LEN*HEAD_DIM) +
                        (($unsigned(col_base_reg)+$unsigned(key_index))*HEAD_DIM) +
                        ($unsigned(feature_chunk)*V_LANES);
        v_req_addr = address_value[V_ADDR_W-1:0];
    end
    assign v_req_valid = (state == ST_V_REQ);
    assign v_rsp_ready = (state == ST_V_RSP);
    assign in_ready = (state == ST_IDLE);
    assign busy = (state != ST_IDLE);

    assign context_valid = (state == ST_CONTEXT_OUT);
    assign context_fp32_debug =
        o_state_bank[(($unsigned(emit_index)/HEAD_DIM)*V_LANES) +
                     ($unsigned(emit_index)%V_LANES)]
                    [($unsigned(emit_index)%HEAD_DIM)/V_LANES];
    assign context_bf16 = fp32_to_bf16(context_fp32_debug);
    assign context_group = group_reg;
    assign context_head = head_reg;
    assign context_global_head =
        $unsigned(group_reg)*Q_HEADS + $unsigned(head_reg);
    assign context_row = row_base_reg + ($unsigned(emit_index)/HEAD_DIM);
    assign context_col = $unsigned(emit_index)%HEAD_DIM;
    assign context_last = group_last_reg &&
                          ($unsigned(emit_index) == CONTEXT_ITEMS-1);

    always_ff @(posedge clk) begin : p_controller
        integer seq_pe;
        integer seq_row;
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            weights_q15_reg <= '0;
            alpha_q15_reg <= '0;
            l_q15_reg <= '0;
            row_active_reg <= '0;
            group_reg <= '0;
            head_reg <= '0;
            row_base_reg <= '0;
            col_base_reg <= '0;
            row_tile_last_reg <= 1'b0;
            group_last_reg <= 1'b0;
            feature_chunk <= '0;
            key_index <= '0;
            emit_index <= '0;
            v_tile_reg <= '0;
            tile_done <= 1'b0;
            protocol_error <= 1'b0;
            tiles_processed <= '0;
            v_vectors_read <= '0;
            for (seq_row = 0; seq_row < TILE; seq_row = seq_row + 1)
                row_recip_fp32[seq_row] <= '0;
        end else begin
            tile_done <= 1'b0;
            case (state)
                ST_IDLE: if (in_valid && in_ready) begin
                    weights_q15_reg <= in_weights_q15;
                    alpha_q15_reg <= in_alpha_q15;
                    l_q15_reg <= in_l_q15;
                    row_active_reg <= in_row_active;
                    group_reg <= in_group;
                    head_reg <= in_head;
                    row_base_reg <= in_row_base;
                    col_base_reg <= in_col_base;
                    row_tile_last_reg <= in_row_tile_last;
                    group_last_reg <= in_group_last;
                    feature_chunk <= '0;
                    key_index <= '0;
                    v_tile_reg <= '0;
                    if (($unsigned(in_col_base)%TILE) != 0)
                        protocol_error <= 1'b1;
                    state <= ST_V_REQ;
                end

                ST_V_REQ: if (v_req_valid && v_req_ready)
                    state <= ST_V_RSP;

                ST_V_RSP: if (v_rsp_valid && v_rsp_ready) begin
                    v_tile_reg[key_index*V_LANES*16 +: V_LANES*16] <=
                        v_rsp_data;
                    v_vectors_read <= v_vectors_read + 1'b1;
                    if ($unsigned(key_index) == TILE-1) begin
                        state <= ST_UPDATE_START;
                    end else begin
                        key_index <= key_index + 1'b1;
                        state <= ST_V_REQ;
                    end
                end

                ST_UPDATE_START: if (all_pe_ready)
                    state <= ST_UPDATE_WAIT;

                ST_UPDATE_WAIT: if (all_results_valid) begin
                    for (seq_pe = 0; seq_pe < PE_COUNT; seq_pe = seq_pe + 1)
                        o_state_bank[seq_pe][$unsigned(feature_chunk)] <=
                            pe_result[seq_pe];
                    if ($unsigned(feature_chunk) == FEATURE_CHUNKS-1) begin
                        if (row_tile_last_reg) begin
                            state <= ST_DIV_START;
                        end else begin
                            tiles_processed <= tiles_processed + 1'b1;
                            tile_done <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end else begin
                        feature_chunk <= feature_chunk + 1'b1;
                        key_index <= '0;
                        v_tile_reg <= '0;
                        state <= ST_V_REQ;
                    end
                end

                ST_DIV_START: state <= ST_DIV_WAIT;

                ST_DIV_WAIT: if (all_div_complete) begin
                    for (seq_row = 0; seq_row < TILE; seq_row = seq_row + 1) begin
                        if (!row_active_reg[seq_row] ||
                            (l_q15_reg[seq_row*L_W +: L_W] == 0))
                            row_recip_fp32[seq_row] <= 32'h00000000;
                        else
                            row_recip_fp32[seq_row] <=
                                q30_to_fp32(div_quotient[seq_row][30:0]);
                    end
                    feature_chunk <= '0;
                    state <= ST_NORM_START;
                end

                ST_NORM_START: if (all_pe_ready)
                    state <= ST_NORM_WAIT;

                ST_NORM_WAIT: if (all_results_valid) begin
                    for (seq_pe = 0; seq_pe < PE_COUNT; seq_pe = seq_pe + 1)
                        o_state_bank[seq_pe][$unsigned(feature_chunk)] <=
                            pe_result[seq_pe];
                    if ($unsigned(feature_chunk) == FEATURE_CHUNKS-1) begin
                        emit_index <= '0;
                        state <= ST_CONTEXT_OUT;
                    end else begin
                        feature_chunk <= feature_chunk + 1'b1;
                        state <= ST_NORM_START;
                    end
                end

                ST_CONTEXT_OUT: if (context_valid && context_ready) begin
                    if ($unsigned(emit_index) == CONTEXT_ITEMS-1) begin
                        tiles_processed <= tiles_processed + 1'b1;
                        tile_done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        emit_index <= emit_index + 1'b1;
                    end
                end

                default: begin
                    protocol_error <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    logic unused_div_busy;
    logic unused_div_by_zero;
    logic [L_W-1:0] unused_div_remainder;
    assign unused_div_busy = |div_busy;
    assign unused_div_by_zero = |div_by_zero;
    assign unused_div_remainder = div_remainder[0];

    initial begin
        if (TILE != 4)
            $error("flash_context_fusion_backend: current implementation requires TILE=4");
        if (V_LANES != 8)
            $error("flash_context_fusion_backend: V_LANES must be 8");
        if ((HEAD_DIM % V_LANES) != 0)
            $error("flash_context_fusion_backend: V_LANES must divide HEAD_DIM");
        if ((SEQ_LEN % TILE) != 0)
            $error("flash_context_fusion_backend: TILE must divide SEQ_LEN");
    end
endmodule
