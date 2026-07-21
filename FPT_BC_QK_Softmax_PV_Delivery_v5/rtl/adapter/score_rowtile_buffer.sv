`timescale 1ns/1ps

// ============================================================================
// score_rowtile_buffer (v4 BRAM-safe)
// ----------------------------------------------------------------------------
// Reorders one QK row-tile from tile-major order into complete row-major order.
// For TILE=4 and SEQ_LEN=128, one fill phase stores 4*128 BF16 scores, then
// drains four complete rows. This correctness-first version deliberately uses
// a single buffer and backpressures QK while draining.
//
// STRICT_TILE_ORDER checks the exact qk_systolic_gqa_top order:
//   col tile -> local row -> local col.
// This detects repeated, missing, or out-of-order coordinates before stale RAM
// contents could be emitted.
// Reset: synchronous, active-low rst_n. Payload RAM is intentionally not reset;
// state and counters guarantee that only fully overwritten locations are read.
// ============================================================================
module score_rowtile_buffer #(
    parameter int SCORE_W = 16,
    parameter int SEQ_LEN = 128,
    parameter int TILE    = 4,
    parameter int HEAD_W  = 2,
    parameter int POS_W   = 7,
    parameter bit STRICT_TILE_ORDER = 1'b1
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 s_valid,
    output logic                 s_ready,
    input  logic [SCORE_W-1:0]   s_score,
    input  logic                 s_mask,
    input  logic [HEAD_W-1:0]    s_head,
    input  logic [POS_W-1:0]     s_row,
    input  logic [POS_W-1:0]     s_col,

    output logic                 m_valid,
    input  logic                 m_ready,
    output logic [SCORE_W-1:0]   m_data,
    output logic                 m_mask,
    output logic [HEAD_W-1:0]    m_head,
    output logic [POS_W-1:0]     m_row,
    output logic [POS_W-1:0]     m_col,
    output logic                 m_first,
    output logic                 m_last,

    output logic                 busy,
    output logic                 protocol_error
);

    localparam int DEPTH       = TILE * SEQ_LEN;
    localparam int ADDR_W      = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam int COUNT_W     = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);
    localparam int LOCAL_ROW_W = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int TILE_ITEMS  = TILE * TILE;

    typedef enum logic { ST_FILL, ST_DRAIN } state_t;
    state_t state;

    logic [COUNT_W-1:0] fill_count;
    logic [HEAD_W-1:0]  active_head;
    logic [POS_W-1:0]   active_row_base;

    logic [LOCAL_ROW_W-1:0] next_local_row;
    logic [POS_W-1:0]       next_col;
    logic                   load_done;

    logic                 out_valid_reg;
    logic [HEAD_W-1:0]    out_head_reg;
    logic [POS_W-1:0]     out_row_reg;
    logic [POS_W-1:0]     out_col_reg;
    logic                 out_first_reg;
    logic                 out_last_reg;

    logic [POS_W-1:0]  write_row_base;
    logic [POS_W-1:0]  write_local_row;
    logic [ADDR_W-1:0] write_addr;
    logic [ADDR_W-1:0] read_addr;
    logic              payload_wr_en;
    logic              payload_rd_en;
    logic [SCORE_W:0]  payload_rd_data;

    integer write_addr_int;
    integer read_addr_int;
    integer expected_col_block_int;
    integer expected_within_tile_int;
    integer expected_local_row_int;
    integer expected_local_col_int;
    integer expected_row_int;
    integer expected_col_int;
    logic [POS_W-1:0] expected_row_vec;
    logic [POS_W-1:0] expected_col_vec;

    function automatic logic [POS_W-1:0] row_group_base(
        input logic [POS_W-1:0] row_value
    );
        integer base_value;
        begin
            base_value = (row_value / TILE) * TILE;
            row_group_base = base_value[POS_W-1:0];
        end
    endfunction

    always_comb begin
        write_row_base  = (fill_count == 0) ? row_group_base(s_row)
                                            : active_row_base;
        write_local_row = s_row - write_row_base;
        write_addr_int  = (write_local_row * SEQ_LEN) + s_col;
        write_addr      = write_addr_int[ADDR_W-1:0];

        read_addr_int = (next_local_row * SEQ_LEN) + next_col;
        read_addr     = read_addr_int[ADDR_W-1:0];

        expected_col_block_int  = fill_count / TILE_ITEMS;
        expected_within_tile_int = fill_count % TILE_ITEMS;
        expected_local_row_int  = expected_within_tile_int / TILE;
        expected_local_col_int  = expected_within_tile_int % TILE;
        expected_row_int = write_row_base + expected_local_row_int;
        expected_col_int = expected_col_block_int*TILE + expected_local_col_int;
        expected_row_vec = expected_row_int[POS_W-1:0];
        expected_col_vec = expected_col_int[POS_W-1:0];
    end

    assign s_ready = (state == ST_FILL) && (fill_count < DEPTH);

    assign payload_wr_en = (state == ST_FILL) && s_valid && s_ready;

    // The BRAM read response and its metadata form a one-entry elastic output
    // register.  Issue a new read only when that slot is empty or its current
    // item will be accepted on this edge.  Therefore every output field holds
    // stable for an arbitrary valid/ready stall.
    assign payload_rd_en = (state == ST_DRAIN) && !load_done &&
                           (!out_valid_reg || m_ready);

    score_rowtile_payload_bram #(
        .DATA_W(SCORE_W + 1),
        .DEPTH (DEPTH),
        .ADDR_W(ADDR_W)
    ) u_payload_bram (
        .clk,
        .wr_en   (payload_wr_en),
        .wr_addr (write_addr),
        .wr_data ({s_mask, s_score}),
        .rd_en   (payload_rd_en),
        .rd_addr (read_addr),
        .rd_data (payload_rd_data)
    );

    assign m_valid = out_valid_reg;
    assign m_data  = payload_rd_data[SCORE_W-1:0];
    assign m_mask  = payload_rd_data[SCORE_W];
    assign m_head  = out_head_reg;
    assign m_row   = out_row_reg;
    assign m_col   = out_col_reg;
    assign m_first = out_first_reg;
    assign m_last  = out_last_reg;

    assign busy = (state != ST_FILL) || (fill_count != 0) || out_valid_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= ST_FILL;
            fill_count      <= '0;
            active_head     <= '0;
            active_row_base <= '0;
            next_local_row  <= '0;
            next_col        <= '0;
            load_done       <= 1'b0;
            out_valid_reg   <= 1'b0;
            out_head_reg    <= '0;
            out_row_reg     <= '0;
            out_col_reg     <= '0;
            out_first_reg   <= 1'b0;
            out_last_reg    <= 1'b0;
            protocol_error  <= 1'b0;
        end else begin
            case (state)
                ST_FILL: begin
                    out_valid_reg <= 1'b0;
                    load_done     <= 1'b0;

                    if (s_valid && s_ready) begin
                        if (fill_count == 0) begin
                            active_head     <= s_head;
                            active_row_base <= row_group_base(s_row);
                        end else begin
                            if (s_head !== active_head)
                                protocol_error <= 1'b1;
                            if ((s_row < active_row_base) ||
                                ($unsigned(s_row) >= ($unsigned(active_row_base) + TILE)))
                                protocol_error <= 1'b1;
                        end

                        if ($unsigned(s_col) >= SEQ_LEN)
                            protocol_error <= 1'b1;

                        if (STRICT_TILE_ORDER) begin
                            if ((s_row !== expected_row_vec) ||
                                (s_col !== expected_col_vec))
                                protocol_error <= 1'b1;
                        end else if ((fill_count == 0) &&
                                     (((s_row % TILE) != 0) || (s_col != 0))) begin
                            protocol_error <= 1'b1;
                        end

                        if (fill_count == DEPTH-1) begin
                            state          <= ST_DRAIN;
                            next_local_row <= '0;
                            next_col       <= '0;
                            load_done      <= 1'b0;
                        end else begin
                            fill_count <= fill_count + 1'b1;
                        end
                    end
                end

                ST_DRAIN: begin
                    // Retire the current output.  A simultaneous payload read
                    // below refills the slot without introducing a bubble.
                    if (out_valid_reg && m_ready) begin
                        if (out_last_reg && load_done) begin
                            state          <= ST_FILL;
                            fill_count     <= '0;
                            next_local_row <= '0;
                            next_col       <= '0;
                            load_done      <= 1'b0;
                        end
                        out_valid_reg <= 1'b0;
                    end

                    // payload_rd_data is updated by the dedicated BRAM on the
                    // same edge.  These registers capture the matching address
                    // metadata, and out_valid_reg exposes both after the edge.
                    if (payload_rd_en) begin
                        out_head_reg  <= active_head;
                        out_row_reg   <= active_row_base + next_local_row;
                        out_col_reg   <= next_col;
                        out_first_reg <= (next_col == 0);
                        out_last_reg  <= (next_col == SEQ_LEN-1);
                        out_valid_reg <= 1'b1;

                        if ((next_local_row == TILE-1) &&
                            (next_col == SEQ_LEN-1)) begin
                            load_done <= 1'b1;
                        end else if (next_col == SEQ_LEN-1) begin
                            next_col       <= '0;
                            next_local_row <= next_local_row + 1'b1;
                        end else begin
                            next_col <= next_col + 1'b1;
                        end
                    end
                end

                default: begin
                    state          <= ST_FILL;
                    fill_count     <= '0;
                    out_valid_reg  <= 1'b0;
                    load_done      <= 1'b0;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

    initial begin
        if (SEQ_LEN < 1) $error("score_rowtile_buffer: SEQ_LEN must be >= 1");
        if (TILE < 1) $error("score_rowtile_buffer: TILE must be >= 1");
        if ((SEQ_LEN % TILE) != 0)
            $error("score_rowtile_buffer: SEQ_LEN must be divisible by TILE");
        if ((1 << POS_W) < SEQ_LEN)
            $error("score_rowtile_buffer: POS_W is too small for SEQ_LEN");
    end
endmodule
