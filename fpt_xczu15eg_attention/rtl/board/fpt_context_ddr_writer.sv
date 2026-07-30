`timescale 1ns/1ps

// Reorders the real PV TILE4 output stream into row-major DDR layout.
//
// The real PV core emits one 4x4 tile at a time:
//   head -> row_base -> col_base -> local_row -> local_col
//
// Software/golden Context uses:
//   head -> row -> col
//
// One staging block stores exactly four complete rows.  This matches one
// row_base group from the TILE4 scheduler, so every incoming BF16 value can be
// placed directly into its final row-major 64-bit beat before the block is
// written to DDR.
module fpt_context_ddr_writer #(
    parameter int RUN_GROUPS = 1,
    parameter int Q_HEADS = 4,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int GROUP_W = 3,
    parameter int HEAD_W = 2,
    parameter int GLOBAL_HEAD_W = 5,
    parameter int POS_W = 7,
    parameter int DIM_W = 7,
    parameter int TILE_ROWS = 4,
    parameter int BLOCK_BEATS = (TILE_ROWS*HEAD_DIM)/4
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [31:0] context_base_addr,

    input  logic context_valid,
    output logic context_ready,
    input  logic [15:0] context_bf16,
    input  logic [GROUP_W-1:0] context_group_id,
    input  logic [HEAD_W-1:0] context_head,
    input  logic [GLOBAL_HEAD_W-1:0] context_global_q_head,
    input  logic [POS_W-1:0] context_row,
    input  logic [DIM_W-1:0] context_col,
    input  logic context_global_last,

    output logic wr_start,
    input  logic wr_ready,
    output logic [31:0] wr_addr,
    output logic [31:0] wr_len,
    input  logic wr_fifo_re,
    output logic wr_fifo_empty,
    output logic wr_fifo_aempty,
    output logic [63:0] wr_fifo_data,
    input  logic wr_done,
    input  logic wr_error,

    output logic busy,
    output logic done,
    output logic error,
    output logic [31:0] words_accepted
);
    localparam int TOTAL_WORDS = RUN_GROUPS*Q_HEADS*SEQ_LEN*HEAD_DIM;
    localparam int BLOCK_WORDS = BLOCK_BEATS*4;
    localparam int BLOCK_BYTES = BLOCK_BEATS*8;
    localparam int BEAT_W = (BLOCK_BEATS <= 1) ? 1 : $clog2(BLOCK_BEATS);
    localparam int WORDS_IN_BLOCK_W = $clog2(BLOCK_WORDS+1);
    localparam int BEATS_PER_ROW = HEAD_DIM/4;

    (* ram_style = "distributed" *) logic [63:0] block_mem [0:BLOCK_BEATS-1];
    logic [63:0] pack_reg;
    logic [1:0] pack_lane;
    logic [BEAT_W-1:0] write_beat;
    logic [WORDS_IN_BLOCK_W-1:0] words_in_block;
    logic block_full;
    logic write_active;
    logic final_seen;
    logic [31:0] bytes_written;
    logic [31:0] linear_index;
    logic [31:0] expected_block_number;
    logic [31:0] incoming_block_number;
    logic [BEAT_W-1:0] target_beat;

    assign context_ready = busy && !block_full && !write_active && !final_seen;
    assign wr_addr = context_base_addr + bytes_written;
    assign wr_len = BLOCK_BYTES;
    assign wr_fifo_data = block_mem[write_beat];
    assign wr_fifo_empty = !write_active;
    assign wr_fifo_aempty = 1'b0;

    always_comb begin
        linear_index = ($unsigned(context_global_q_head) * SEQ_LEN * HEAD_DIM) +
                       ($unsigned(context_row) * HEAD_DIM) +
                       $unsigned(context_col);

        // Each DDR block is four complete rows (512 BF16 values / 1024 B).
        expected_block_number = bytes_written / BLOCK_BYTES;
        incoming_block_number = linear_index / BLOCK_WORDS;

        // context_row[1:0] is the local row inside the current TILE4 row group.
        // context_col[6:2] selects the 64-bit beat inside that row.
        target_beat = ($unsigned(context_row) % TILE_ROWS) * BEATS_PER_ROW +
                      ($unsigned(context_col) / 4);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
            wr_start       <= 1'b0;
            pack_reg       <= '0;
            pack_lane      <= '0;
            write_beat     <= '0;
            words_in_block <= '0;
            block_full     <= 1'b0;
            write_active   <= 1'b0;
            final_seen     <= 1'b0;
            bytes_written  <= '0;
            words_accepted <= '0;
        end else begin
            done     <= 1'b0;
            wr_start <= 1'b0;

            if (wr_error)
                error <= 1'b1;

            if (start) begin
                busy           <= 1'b1;
                error          <= 1'b0;
                pack_reg       <= '0;
                pack_lane      <= '0;
                write_beat     <= '0;
                words_in_block <= '0;
                block_full     <= 1'b0;
                write_active   <= 1'b0;
                final_seen     <= 1'b0;
                bytes_written  <= '0;
                words_accepted <= '0;
            end else if (busy) begin
                if (context_valid && context_ready) begin
                    if ($unsigned(context_group_id) >= RUN_GROUPS ||
                        $unsigned(context_head) >= Q_HEADS ||
                        $unsigned(context_row) >= SEQ_LEN ||
                        $unsigned(context_col) >= HEAD_DIM)
                        error <= 1'b1;

                    // The stream is tile-major, but all values belonging to one
                    // four-row block must arrive before the next block starts.
                    if (incoming_block_number != expected_block_number)
                        error <= 1'b1;

                    // Each 64-bit word must arrive as col lanes 0,1,2,3.
                    if (context_col[1:0] != pack_lane)
                        error <= 1'b1;

                    words_accepted <= words_accepted + 1'b1;
                    words_in_block <= words_in_block + 1'b1;

                    case (context_col[1:0])
                        2'd0: pack_reg[15:0]  <= context_bf16;
                        2'd1: pack_reg[31:16] <= context_bf16;
                        2'd2: pack_reg[47:32] <= context_bf16;
                        2'd3: begin
                            block_mem[target_beat] <=
                                {context_bf16, pack_reg[47:0]};
                        end
                    endcase

                    if (context_col[1:0] == 2'd3)
                        pack_lane <= 2'd0;
                    else
                        pack_lane <= context_col[1:0] + 1'b1;

                    if (words_in_block == BLOCK_WORDS-1) begin
                        block_full <= 1'b1;
                        if (context_col[1:0] != 2'd3)
                            error <= 1'b1;
                    end

                    if (context_global_last) begin
                        final_seen <= 1'b1;
                        if (words_accepted != TOTAL_WORDS-1 ||
                            words_in_block != BLOCK_WORDS-1 ||
                            context_col[1:0] != 2'd3)
                            error <= 1'b1;
                    end
                end

                if (block_full && !write_active && wr_ready) begin
                    write_beat   <= '0;
                    write_active <= 1'b1;
                    wr_start     <= 1'b1;
                end

                if (write_active && wr_fifo_re) begin
                    if ($unsigned(write_beat) + 1 < BLOCK_BEATS)
                        write_beat <= write_beat + 1'b1;
                end

                if (write_active && wr_done) begin
                    write_active  <= 1'b0;
                    bytes_written <= bytes_written + BLOCK_BYTES;
                    block_full    <= 1'b0;
                    words_in_block <= '0;
                    write_beat    <= '0;
                    pack_reg      <= '0;
                    pack_lane     <= '0;

                    if (final_seen) begin
                        if (words_accepted != TOTAL_WORDS)
                            error <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end
        end
    end

    initial begin
        if (TILE_ROWS != 4)
            $error("fpt_context_ddr_writer: this version requires TILE_ROWS=4");
        if ((HEAD_DIM % 4) != 0)
            $error("fpt_context_ddr_writer: HEAD_DIM must be divisible by four");
        if (BLOCK_BEATS != (TILE_ROWS*HEAD_DIM)/4)
            $error("fpt_context_ddr_writer: BLOCK_BEATS must cover four rows");
        if ((TOTAL_WORDS % BLOCK_WORDS) != 0)
            $error("fpt_context_ddr_writer: total words must divide into blocks");
        if (BLOCK_BEATS < 1 || BLOCK_BEATS > 256)
            $error("fpt_context_ddr_writer: BLOCK_BEATS must be 1..256");
    end
endmodule
