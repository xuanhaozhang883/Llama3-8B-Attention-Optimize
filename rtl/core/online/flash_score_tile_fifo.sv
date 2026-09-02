`timescale 1ns/1ps

// Scalar QK score stream -> complete score-tile FIFO.
//
// The QK producer interface intentionally remains scalar and unchanged.  This
// module assembles TILE*TILE consecutive row-major scores into one atomic tile
// for the FlashAttention consumer.  A tile already being assembled owns one
// future FIFO entry, so input backpressure is only asserted between tiles when
// every entry is occupied.
//
// Packed ordering:
//   element = local_row*TILE + local_col
//   out_scores[element*SCORE_W +: SCORE_W]
//   out_masks[element]
module flash_score_tile_fifo #(
    parameter int SCORE_W     = 16,
    parameter int TILE        = 4,
    parameter int DEPTH_TILES = 4,
    parameter int SEQ_LEN     = 128,
    parameter int Q_HEADS     = 4,
    parameter int GQA_GROUPS  = 8,
    parameter int HEAD_W      = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W     = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int POS_W       = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic               in_valid,
    output logic               in_ready,
    input  logic [SCORE_W-1:0] in_score,
    input  logic               in_mask,
    input  logic [GROUP_W-1:0] in_group,
    input  logic [HEAD_W-1:0]  in_head,
    input  logic [POS_W-1:0]   in_row,
    input  logic [POS_W-1:0]   in_col,
    input  logic               in_last,

    output logic                         out_valid,
    input  logic                         out_ready,
    output logic [TILE*TILE*SCORE_W-1:0] out_scores,
    output logic [TILE*TILE-1:0]         out_masks,
    output logic [GROUP_W-1:0]           out_group,
    output logic [HEAD_W-1:0]            out_head,
    output logic [POS_W-1:0]             out_row_base,
    output logic [POS_W-1:0]             out_col_base,
    output logic                         out_all_masked,
    output logic                         out_group_last,

    output logic        busy,
    output logic        order_error,
    output logic [31:0] tiles_enqueued,
    output logic [31:0] tiles_dequeued
);
    localparam int TILE_ITEMS = TILE*TILE;
    localparam int ITEM_W = (TILE_ITEMS <= 1) ? 1 : $clog2(TILE_ITEMS);
    localparam int PTR_W = (DEPTH_TILES <= 1) ? 1 : $clog2(DEPTH_TILES);
    localparam int COUNT_W = (DEPTH_TILES <= 1) ? 1 :
                             $clog2(DEPTH_TILES + 1);

    logic [TILE_ITEMS*SCORE_W-1:0] tile_score_mem [0:DEPTH_TILES-1];
    logic [TILE_ITEMS-1:0]         tile_mask_mem [0:DEPTH_TILES-1];
    logic [GROUP_W-1:0]            tile_group_mem [0:DEPTH_TILES-1];
    logic [HEAD_W-1:0]             tile_head_mem [0:DEPTH_TILES-1];
    logic [POS_W-1:0]              tile_row_mem [0:DEPTH_TILES-1];
    logic [POS_W-1:0]              tile_col_mem [0:DEPTH_TILES-1];
    logic                          tile_last_mem [0:DEPTH_TILES-1];

    logic [PTR_W-1:0] write_ptr;
    logic [PTR_W-1:0] read_ptr;
    logic [COUNT_W-1:0] tile_count;

    logic [ITEM_W-1:0] assemble_count;
    logic [TILE_ITEMS*SCORE_W-1:0] assemble_scores;
    logic [TILE_ITEMS-1:0]         assemble_masks;
    logic [GROUP_W-1:0]            assemble_group;
    logic [HEAD_W-1:0]             assemble_head;
    logic [POS_W-1:0]              assemble_row_base;
    logic [POS_W-1:0]              assemble_col_base;

    logic [TILE_ITEMS*SCORE_W-1:0] assembled_scores_next;
    logic [TILE_ITEMS-1:0]         assembled_masks_next;
    logic [POS_W-1:0]              input_row_base;
    logic [POS_W-1:0]              input_col_base;
    logic [POS_W-1:0]              expected_row;
    logic [POS_W-1:0]              expected_col;
    logic                          expected_stream_last;
    logic                          input_fire;
    logic                          enqueue_tile;
    logic                          dequeue_tile;

    integer base_int;
    integer expected_row_int;
    integer expected_col_int;

    function automatic logic [PTR_W-1:0] next_ptr(
        input logic [PTR_W-1:0] ptr
    );
        begin
            if ($unsigned(ptr) == DEPTH_TILES-1)
                next_ptr = '0;
            else
                next_ptr = ptr + 1'b1;
        end
    endfunction

    always_comb begin
        base_int = ($unsigned(in_row)/TILE)*TILE;
        input_row_base = base_int[POS_W-1:0];
        base_int = ($unsigned(in_col)/TILE)*TILE;
        input_col_base = base_int[POS_W-1:0];

        expected_row_int = $unsigned(assemble_row_base) +
                           ($unsigned(assemble_count)/TILE);
        expected_col_int = $unsigned(assemble_col_base) +
                           ($unsigned(assemble_count)%TILE);
        expected_row = expected_row_int[POS_W-1:0];
        expected_col = expected_col_int[POS_W-1:0];

        assembled_scores_next = assemble_scores;
        assembled_scores_next[$unsigned(assemble_count)*SCORE_W +: SCORE_W] =
            in_score;
        assembled_masks_next = assemble_masks;
        assembled_masks_next[$unsigned(assemble_count)] = in_mask;

        // The QK producer is launched once per GQA group.  Its in_last marks
        // the final scalar of that group, not the final scalar of all groups.
        expected_stream_last =
            ($unsigned(in_head) == Q_HEADS-1) &&
            ($unsigned(in_row) == SEQ_LEN-1) &&
            ($unsigned(in_col) == SEQ_LEN-1);
    end

    assign out_valid = (tile_count != 0);
    assign dequeue_tile = out_valid && out_ready;

    // A partially assembled tile has already reserved the next free entry.
    // When no tile is in progress, a simultaneous dequeue may free an entry.
    assign in_ready = (assemble_count != 0) ||
                      ($unsigned(tile_count) < DEPTH_TILES) ||
                      dequeue_tile;
    assign input_fire = in_valid && in_ready;
    assign enqueue_tile = input_fire &&
                          ($unsigned(assemble_count) == TILE_ITEMS-1);

    assign out_scores = tile_score_mem[read_ptr];
    assign out_masks = tile_mask_mem[read_ptr];
    assign out_group = tile_group_mem[read_ptr];
    assign out_head = tile_head_mem[read_ptr];
    assign out_row_base = tile_row_mem[read_ptr];
    assign out_col_base = tile_col_mem[read_ptr];
    assign out_all_masked = &tile_mask_mem[read_ptr];
    assign out_group_last = tile_last_mem[read_ptr];
    assign busy = (assemble_count != 0) || (tile_count != 0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_ptr <= '0;
            read_ptr <= '0;
            tile_count <= '0;
            assemble_count <= '0;
            assemble_scores <= '0;
            assemble_masks <= '0;
            assemble_group <= '0;
            assemble_head <= '0;
            assemble_row_base <= '0;
            assemble_col_base <= '0;
            order_error <= 1'b0;
            tiles_enqueued <= '0;
            tiles_dequeued <= '0;
        end else if (clear) begin
            write_ptr <= '0;
            read_ptr <= '0;
            tile_count <= '0;
            assemble_count <= '0;
            assemble_scores <= '0;
            assemble_masks <= '0;
            assemble_group <= '0;
            assemble_head <= '0;
            assemble_row_base <= '0;
            assemble_col_base <= '0;
            order_error <= 1'b0;
            tiles_enqueued <= '0;
            tiles_dequeued <= '0;
        end else begin
            if (dequeue_tile) begin
                read_ptr <= next_ptr(read_ptr);
                tiles_dequeued <= tiles_dequeued + 1'b1;
            end

            if (input_fire) begin
                if (assemble_count == 0) begin
                    assemble_group <= in_group;
                    assemble_head <= in_head;
                    assemble_row_base <= input_row_base;
                    assemble_col_base <= input_col_base;
                    if (($unsigned(in_row)%TILE) != 0 ||
                        ($unsigned(in_col)%TILE) != 0)
                        order_error <= 1'b1;
                end else begin
                    if ((in_group != assemble_group) ||
                        (in_head != assemble_head) ||
                        (in_row != expected_row) ||
                        (in_col != expected_col))
                        order_error <= 1'b1;
                end

                if (in_last != expected_stream_last)
                    order_error <= 1'b1;

                if ($unsigned(assemble_count) == TILE_ITEMS-1) begin
                    tile_score_mem[write_ptr] <= assembled_scores_next;
                    tile_mask_mem[write_ptr] <= assembled_masks_next;
                    tile_group_mem[write_ptr] <=
                        (assemble_count == 0) ? in_group : assemble_group;
                    tile_head_mem[write_ptr] <=
                        (assemble_count == 0) ? in_head : assemble_head;
                    tile_row_mem[write_ptr] <=
                        (assemble_count == 0) ? input_row_base :
                                                assemble_row_base;
                    tile_col_mem[write_ptr] <=
                        (assemble_count == 0) ? input_col_base :
                                                assemble_col_base;
                    tile_last_mem[write_ptr] <= in_last;
                    write_ptr <= next_ptr(write_ptr);
                    assemble_count <= '0;
                    assemble_scores <= '0;
                    assemble_masks <= '0;
                    tiles_enqueued <= tiles_enqueued + 1'b1;
                end else begin
                    assemble_scores <= assembled_scores_next;
                    assemble_masks <= assembled_masks_next;
                    assemble_count <= assemble_count + 1'b1;
                end
            end

            case ({enqueue_tile, dequeue_tile})
                2'b10: tile_count <= tile_count + 1'b1;
                2'b01: tile_count <= tile_count - 1'b1;
                default: tile_count <= tile_count;
            endcase
        end
    end

    initial begin
        if (SCORE_W < 1)
            $error("flash_score_tile_fifo: SCORE_W must be positive");
        if (TILE < 1)
            $error("flash_score_tile_fifo: TILE must be positive");
        if (DEPTH_TILES < 2)
            $error("flash_score_tile_fifo: DEPTH_TILES must be at least 2");
        if ((SEQ_LEN % TILE) != 0)
            $error("flash_score_tile_fifo: TILE must divide SEQ_LEN");
        if ((1 << POS_W) < SEQ_LEN)
            $error("flash_score_tile_fifo: POS_W is too small");
    end
endmodule
