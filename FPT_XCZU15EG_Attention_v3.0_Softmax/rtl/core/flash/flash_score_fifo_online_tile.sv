`timescale 1ns/1ps

// Score FIFO scalar stream -> four-row FlashAttention online-softmax tiles.
//
// The adapter performs four jobs:
//   1. assembles row-major FIFO scalars into complete 4x4 tiles;
//   2. derives the element-level causal mask from row/column metadata;
//   3. stores per-(local Q head, row) online-softmax m/l state;
//   4. emits an atomic P tile plus alpha and updated m/l state.
//
// Two input tile slots absorb the assembly/compute boundary. Under downstream
// ready traffic the four parallel row engines finish within the 16 cycles used
// by the scalar FIFO to deliver the next tile, avoiding structural FIFO stalls.
// State must be cleared once at the start of every 4Q/1KV GQA group.
module flash_score_fifo_online_tile #(
    parameter integer TILE       = 4,
    parameter integer SEQ_LEN    = 128,
    parameter integer Q_HEADS    = 4,
    parameter integer HEAD_W     = 2,
    parameter integer POS_W      = 7,
    parameter integer SCORE_W    = 24,
    parameter integer SCORE_FRAC = 14,
    parameter integer EXP_W      = 24,
    parameter integer EXP_FRAC   = 23,
    parameter integer L_SUM_W    = EXP_W + $clog2(SEQ_LEN + 1),
    parameter integer CAUSAL     = 1,
    parameter EXP_LUT_FILE       = "mem/exp_lut_q23.mem"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Pulse only while state_clear_ready is high. Reset also starts a clear.
    input  logic                         state_clear,
    output logic                         state_clear_ready,
    output logic                         state_clear_busy,
    output logic                         state_clear_done,
    input  logic                         status_clear,

    // Directly connects to flash_score_tile_fifo.out_*.
    input  logic                         score_valid,
    output logic                         score_ready,
    input  logic [15:0]                  score_bf16,
    input  logic [HEAD_W-1:0]            score_head,
    input  logic [POS_W-1:0]             score_row,
    input  logic [POS_W-1:0]             score_col,
    input  logic                         score_last,

    output logic                         tile_valid,
    input  logic                         tile_ready,
    output logic [HEAD_W-1:0]            tile_head,
    output logic [POS_W-1:0]             tile_row_base,
    output logic [POS_W-1:0]             tile_col_base,
    output logic                         tile_last,
    output logic [TILE-1:0]              tile_state_valid,
    output logic [TILE*SCORE_W-1:0]      tile_m_fixed,
    output logic [TILE*L_SUM_W-1:0]      tile_l_q23,
    output logic [TILE*EXP_W-1:0]        tile_alpha_q23,
    output logic [TILE*16-1:0]           tile_alpha_q15,
    output logic [TILE*16-1:0]           tile_alpha_bf16,
    output logic [TILE*TILE*EXP_W-1:0]   tile_weights_q23,
    output logic [TILE*TILE*16-1:0]      tile_weights_q15,
    output logic [TILE*TILE*16-1:0]      tile_weights_bf16,
    output logic [TILE*L_SUM_W-1:0]      tile_row_sum_q23,
    output logic [TILE-1:0]              tile_all_masked_rows,
    output logic [TILE-1:0]              tile_numeric_error,

    output logic                         busy,
    output logic [31:0]                  tiles_assembled,
    output logic [31:0]                  tiles_emitted,
    output logic [31:0]                  input_backpressure_cycles,
    output logic [1:0]                   buffered_tiles,
    output logic [1:0]                   max_buffered_tiles,
    output logic                         protocol_error
);

    localparam integer ITEMS = TILE*TILE;
    localparam integer ITEM_IDX_W = (ITEMS <= 1) ? 1 : $clog2(ITEMS);
    localparam integer ROW_TILES = SEQ_LEN/TILE;
    localparam integer STATE_DEPTH = Q_HEADS*ROW_TILES;
    localparam integer STATE_ADDR_W =
        (STATE_DEPTH <= 1) ? 1 : $clog2(STATE_DEPTH);
    localparam integer STATE_ENTRY_W = 1 + SCORE_W + L_SUM_W;

    logic [ITEMS*16-1:0] tile_score_slot0;
    logic [ITEMS*16-1:0] tile_score_slot1;
    logic [ITEMS-1:0] tile_mask_slot0;
    logic [ITEMS-1:0] tile_mask_slot1;
    logic [1:0]  slot_full;
    logic        write_slot;
    logic        read_slot;
    logic [ITEM_IDX_W-1:0] write_item_index;
    logic [HEAD_W-1:0] slot_head [0:1];
    logic [POS_W-1:0] slot_row_base [0:1];
    logic [POS_W-1:0] slot_col_base [0:1];
    logic slot_last [0:1];

    // Rows 0..3 of an aligned tile map to four independent single-read,
    // single-write banks. Packing valid/m/l into one word lets Vivado infer one
    // compact synchronous state memory per row lane instead of thousands of
    // FFs. Distributed RAM intentionally preserves BRAM for the Stage 3 V cache.
    (* ram_style = "distributed" *)
    logic [STATE_ENTRY_W-1:0] state_mem0 [0:STATE_DEPTH-1];
    (* ram_style = "distributed" *)
    logic [STATE_ENTRY_W-1:0] state_mem1 [0:STATE_DEPTH-1];
    (* ram_style = "distributed" *)
    logic [STATE_ENTRY_W-1:0] state_mem2 [0:STATE_DEPTH-1];
    (* ram_style = "distributed" *)
    logic [STATE_ENTRY_W-1:0] state_mem3 [0:STATE_DEPTH-1];
    logic [STATE_ENTRY_W-1:0] state_read_data0;
    logic [STATE_ENTRY_W-1:0] state_read_data1;
    logic [STATE_ENTRY_W-1:0] state_read_data2;
    logic [STATE_ENTRY_W-1:0] state_read_data3;
    logic state_read_pending;
    logic state_read_request;

    logic clear_active;
    logic [STATE_ADDR_W-1:0] clear_addr;
    logic seen_last;

    logic score_fire;
    logic score_tile_commit;
    logic core_in_valid;
    logic core_in_ready;
    logic core_input_fire;
    logic [TILE*TILE*16-1:0] core_scores_bf16;
    logic [TILE*TILE-1:0] core_mask;
    logic [TILE-1:0] core_in_state_valid;
    logic [TILE*SCORE_W-1:0] core_in_m_fixed;
    logic [TILE*L_SUM_W-1:0] core_in_l_q23;
    logic core_out_valid;
    logic core_out_ready;
    logic [TILE-1:0] core_out_state_valid;
    logic [TILE*SCORE_W-1:0] core_out_m_fixed;
    logic [TILE*L_SUM_W-1:0] core_out_l_q23;
    logic [TILE*EXP_W-1:0] core_out_alpha_q23;
    logic [TILE*16-1:0] core_out_alpha_q15;
    logic [TILE*16-1:0] core_out_alpha_bf16;
    logic [TILE*TILE*EXP_W-1:0] core_out_weights_q23;
    logic [TILE*TILE*16-1:0] core_out_weights_q15;
    logic [TILE*TILE*16-1:0] core_out_weights_bf16;
    logic [TILE*L_SUM_W-1:0] core_out_row_sum_q23;
    logic [TILE-1:0] core_out_all_masked_rows;
    logic [TILE-1:0] core_out_numeric_error;
    logic core_busy;
    logic core_output_fire;

    logic [STATE_ADDR_W-1:0] selected_state_addr;
    logic [STATE_ADDR_W-1:0] inflight_state_addr;
    logic [HEAD_W-1:0] inflight_head;
    logic [POS_W-1:0] inflight_row_base;
    logic [POS_W-1:0] inflight_col_base;
    logic inflight_last;

    logic [1:0] buffered_tiles_next;

    assign buffered_tiles = {1'b0, slot_full[0]} +
                            {1'b0, slot_full[1]};
    assign buffered_tiles_next = buffered_tiles +
        (score_tile_commit ? 2'd1 : 2'd0) -
        (core_input_fire ? 2'd1 : 2'd0);

    assign state_clear_busy = clear_active;
    assign state_clear_ready = rst_n && !busy;
    assign score_ready = rst_n && !clear_active && !state_clear &&
                         !seen_last && !slot_full[write_slot];
    assign score_fire = score_valid && score_ready;
    assign score_tile_commit = score_fire &&
        (write_item_index == ITEMS-1);

    assign state_read_request = slot_full[read_slot] && !clear_active &&
                                !state_read_pending && core_in_ready;
    assign core_in_valid = state_read_pending;
    assign core_input_fire = core_in_valid && core_in_ready;
    assign core_out_ready = tile_ready;
    assign core_output_fire = core_out_valid && core_out_ready;

    assign tile_valid = core_out_valid;
    assign tile_head = inflight_head;
    assign tile_row_base = inflight_row_base;
    assign tile_col_base = inflight_col_base;
    assign tile_last = inflight_last;
    assign tile_state_valid = core_out_state_valid;
    assign tile_m_fixed = core_out_m_fixed;
    assign tile_l_q23 = core_out_l_q23;
    assign tile_alpha_q23 = core_out_alpha_q23;
    assign tile_alpha_q15 = core_out_alpha_q15;
    assign tile_alpha_bf16 = core_out_alpha_bf16;
    assign tile_weights_q23 = core_out_weights_q23;
    assign tile_weights_q15 = core_out_weights_q15;
    assign tile_weights_bf16 = core_out_weights_bf16;
    assign tile_row_sum_q23 = core_out_row_sum_q23;
    assign tile_all_masked_rows = core_out_all_masked_rows;
    assign tile_numeric_error = core_out_numeric_error;

    assign busy = clear_active || state_read_pending ||
                  (write_item_index != 0) ||
                  (|slot_full) || core_busy || core_out_valid;

    always_comb begin
        selected_state_addr =
            ($unsigned(slot_head[read_slot])*ROW_TILES) +
            ($unsigned(slot_row_base[read_slot])/TILE);

        if (read_slot) begin
            core_scores_bf16 = tile_score_slot1;
            core_mask = tile_mask_slot1;
        end else begin
            core_scores_bf16 = tile_score_slot0;
            core_mask = tile_mask_slot0;
        end

        core_in_state_valid[0] = state_read_data0[STATE_ENTRY_W-1];
        core_in_state_valid[1] = state_read_data1[STATE_ENTRY_W-1];
        core_in_state_valid[2] = state_read_data2[STATE_ENTRY_W-1];
        core_in_state_valid[3] = state_read_data3[STATE_ENTRY_W-1];

        core_in_m_fixed[0*SCORE_W +: SCORE_W] =
            core_in_state_valid[0] ?
                state_read_data0[L_SUM_W +: SCORE_W] : '0;
        core_in_m_fixed[1*SCORE_W +: SCORE_W] =
            core_in_state_valid[1] ?
                state_read_data1[L_SUM_W +: SCORE_W] : '0;
        core_in_m_fixed[2*SCORE_W +: SCORE_W] =
            core_in_state_valid[2] ?
                state_read_data2[L_SUM_W +: SCORE_W] : '0;
        core_in_m_fixed[3*SCORE_W +: SCORE_W] =
            core_in_state_valid[3] ?
                state_read_data3[L_SUM_W +: SCORE_W] : '0;

        core_in_l_q23[0*L_SUM_W +: L_SUM_W] =
            core_in_state_valid[0] ?
                state_read_data0[0 +: L_SUM_W] : '0;
        core_in_l_q23[1*L_SUM_W +: L_SUM_W] =
            core_in_state_valid[1] ?
                state_read_data1[0 +: L_SUM_W] : '0;
        core_in_l_q23[2*L_SUM_W +: L_SUM_W] =
            core_in_state_valid[2] ?
                state_read_data2[0 +: L_SUM_W] : '0;
        core_in_l_q23[3*L_SUM_W +: L_SUM_W] =
            core_in_state_valid[3] ?
                state_read_data3[0 +: L_SUM_W] : '0;
    end

    // Synchronous read and independent write infer simple dual-port block RAM.
    // No reset is applied to the array itself; clear_active initializes all
    // valid bits and payloads through the normal write port after reset.
    always_ff @(posedge clk) begin
        if (state_read_request) begin
            state_read_data0 <= state_mem0[selected_state_addr];
            state_read_data1 <= state_mem1[selected_state_addr];
            state_read_data2 <= state_mem2[selected_state_addr];
            state_read_data3 <= state_mem3[selected_state_addr];
        end

        if (clear_active) begin
            state_mem0[clear_addr] <= '0;
            state_mem1[clear_addr] <= '0;
            state_mem2[clear_addr] <= '0;
            state_mem3[clear_addr] <= '0;
        end else if (core_output_fire) begin
            state_mem0[inflight_state_addr] <= {
                core_out_state_valid[0],
                core_out_m_fixed[0*SCORE_W +: SCORE_W],
                core_out_l_q23[0*L_SUM_W +: L_SUM_W]
            };
            state_mem1[inflight_state_addr] <= {
                core_out_state_valid[1],
                core_out_m_fixed[1*SCORE_W +: SCORE_W],
                core_out_l_q23[1*L_SUM_W +: L_SUM_W]
            };
            state_mem2[inflight_state_addr] <= {
                core_out_state_valid[2],
                core_out_m_fixed[2*SCORE_W +: SCORE_W],
                core_out_l_q23[2*L_SUM_W +: L_SUM_W]
            };
            state_mem3[inflight_state_addr] <= {
                core_out_state_valid[3],
                core_out_m_fixed[3*SCORE_W +: SCORE_W],
                core_out_l_q23[3*L_SUM_W +: L_SUM_W]
            };
        end
    end

    flash_online_tile_update #(
        .TILE(TILE),
        .MAX_LEN(SEQ_LEN),
        .SCORE_W(SCORE_W),
        .SCORE_FRAC(SCORE_FRAC),
        .EXP_W(EXP_W),
        .EXP_FRAC(EXP_FRAC),
        .L_SUM_W(L_SUM_W),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_online_tile_update (
        .clk,
        .rst_n,
        .in_valid(core_in_valid),
        .in_ready(core_in_ready),
        .in_scores_bf16(core_scores_bf16),
        .in_mask(core_mask),
        .in_state_valid(core_in_state_valid),
        .in_m_fixed(core_in_m_fixed),
        .in_l_q23(core_in_l_q23),
        .out_valid(core_out_valid),
        .out_ready(core_out_ready),
        .out_state_valid(core_out_state_valid),
        .out_m_fixed(core_out_m_fixed),
        .out_l_q23(core_out_l_q23),
        .out_alpha_q23(core_out_alpha_q23),
        .out_alpha_q15(core_out_alpha_q15),
        .out_alpha_bf16(core_out_alpha_bf16),
        .out_weights_q23(core_out_weights_q23),
        .out_weights_q15(core_out_weights_q15),
        .out_weights_bf16(core_out_weights_bf16),
        .out_row_sum_q23(core_out_row_sum_q23),
        .out_all_masked_rows(core_out_all_masked_rows),
        .out_numeric_error(core_out_numeric_error),
        .busy(core_busy)
    );

    integer reset_slot;
    integer reset_item;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_full <= '0;
            write_slot <= 1'b0;
            read_slot <= 1'b0;
            write_item_index <= '0;
            state_read_pending <= 1'b0;
            clear_active <= 1'b1;
            clear_addr <= '0;
            state_clear_done <= 1'b0;
            seen_last <= 1'b0;
            inflight_state_addr <= '0;
            inflight_head <= '0;
            inflight_row_base <= '0;
            inflight_col_base <= '0;
            inflight_last <= 1'b0;
            tiles_assembled <= '0;
            tiles_emitted <= '0;
            input_backpressure_cycles <= '0;
            max_buffered_tiles <= '0;
            protocol_error <= 1'b0;
            for (reset_slot = 0; reset_slot < 2;
                 reset_slot = reset_slot + 1) begin
                slot_head[reset_slot] <= '0;
                slot_row_base[reset_slot] <= '0;
                slot_col_base[reset_slot] <= '0;
                slot_last[reset_slot] <= 1'b0;
            end
        end else begin
            state_clear_done <= 1'b0;

            if (clear_active) begin
                if ($unsigned(clear_addr) == STATE_DEPTH-1) begin
                    clear_active <= 1'b0;
                    clear_addr <= '0;
                    state_clear_done <= 1'b1;
                end else begin
                    clear_addr <= clear_addr + 1'b1;
                end
            end else if (state_clear && state_clear_ready) begin
                clear_active <= 1'b1;
                clear_addr <= '0;
                seen_last <= 1'b0;
            end

            if (state_clear && !state_clear_ready)
                protocol_error <= 1'b1;

            if (status_clear) begin
                tiles_assembled <= '0;
                tiles_emitted <= '0;
                input_backpressure_cycles <= '0;
                max_buffered_tiles <= buffered_tiles;
                protocol_error <= busy;
            end else begin
                if (score_valid && !score_ready)
                    input_backpressure_cycles <=
                        input_backpressure_cycles + 1'b1;
                if (score_tile_commit)
                    tiles_assembled <= tiles_assembled + 1'b1;
                if (core_output_fire)
                    tiles_emitted <= tiles_emitted + 1'b1;
                if (buffered_tiles_next > max_buffered_tiles)
                    max_buffered_tiles <= buffered_tiles_next;
            end

            if (score_fire) begin
                if (write_slot) begin
                    tile_score_slot1[
                        write_item_index*16 +: 16] <= score_bf16;
                    tile_mask_slot1[write_item_index] <=
                        (CAUSAL != 0) &&
                        ($unsigned(score_col) > $unsigned(score_row));
                end else begin
                    tile_score_slot0[
                        write_item_index*16 +: 16] <= score_bf16;
                    tile_mask_slot0[write_item_index] <=
                        (CAUSAL != 0) &&
                        ($unsigned(score_col) > $unsigned(score_row));
                end

                if (write_item_index == 0) begin
                    slot_head[write_slot] <= score_head;
                    slot_row_base[write_slot] <= score_row;
                    slot_col_base[write_slot] <= score_col;
                    if (($unsigned(score_head) >= Q_HEADS) ||
                        ($unsigned(score_row) >= SEQ_LEN) ||
                        ($unsigned(score_col) >= SEQ_LEN) ||
                        (($unsigned(score_row) % TILE) != 0) ||
                        (($unsigned(score_col) % TILE) != 0))
                        protocol_error <= 1'b1;
                end else begin
                    if ((score_head != slot_head[write_slot]) ||
                        ($unsigned(score_row) !=
                         ($unsigned(slot_row_base[write_slot]) +
                          ($unsigned(write_item_index)/TILE))) ||
                        ($unsigned(score_col) !=
                         ($unsigned(slot_col_base[write_slot]) +
                          ($unsigned(write_item_index)%TILE))))
                        protocol_error <= 1'b1;
                end

                if (score_last &&
                    (write_item_index != ITEMS-1))
                    protocol_error <= 1'b1;

                if (score_tile_commit) begin
                    slot_last[write_slot] <= score_last;
                    slot_full[write_slot] <= 1'b1;
                    write_slot <= ~write_slot;
                    write_item_index <= '0;
                    if (score_last)
                        seen_last <= 1'b1;
                end else begin
                    write_item_index <= write_item_index + 1'b1;
                end
            end

            if (state_read_request)
                state_read_pending <= 1'b1;

            if (core_input_fire) begin
                state_read_pending <= 1'b0;
                slot_full[read_slot] <= 1'b0;
                read_slot <= ~read_slot;
                inflight_state_addr <= selected_state_addr;
                inflight_head <= slot_head[read_slot];
                inflight_row_base <= slot_row_base[read_slot];
                inflight_col_base <= slot_col_base[read_slot];
                inflight_last <= slot_last[read_slot];
            end

        end
    end

    initial begin
        if (TILE != 4)
            $error("flash_score_fifo_online_tile requires TILE=4");
        if ((SEQ_LEN < TILE) || ((SEQ_LEN % TILE) != 0))
            $error("SEQ_LEN must be a positive multiple of TILE");
        if (Q_HEADS != 4)
            $error("Stage 2B state banking requires Q_HEADS=4");
        if ((1 << HEAD_W) < Q_HEADS)
            $error("HEAD_W is too small for Q_HEADS");
        if ((1 << POS_W) < SEQ_LEN)
            $error("POS_W is too small for SEQ_LEN");
        if (STATE_DEPTH < 1)
            $error("STATE_DEPTH must be positive");
    end

endmodule
