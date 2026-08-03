`timescale 1ns/1ps

// Complete-tile FIFO for the QK -> Softmax boundary.
//
// The upstream QK engine keeps its scalar ready/valid interface. Each accepted
// scalar is written into a reserved tile slot, but the slot is not visible to
// the downstream consumer until all TILE*TILE scalars have been accepted.
// Consequently a partial score tile can never enter Softmax.
//
// Storage is a narrow scalar array with an asynchronous read. For the required
// TILE=4 configuration this maps naturally to distributed RAM and allows two
// committed tiles to be replayed back-to-back without an inserted bubble.
module flash_score_tile_fifo #(
    parameter int TILE       = 4,
    parameter int FIFO_DEPTH = 8,
    parameter int HEAD_W     = 2,
    parameter int POS_W      = 7
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Clears per-group counters and sticky status. The FIFO must be idle.
    input  logic                  status_clear,

    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [15:0]           in_score_bf16,
    input  logic [HEAD_W-1:0]     in_score_head,
    input  logic [POS_W-1:0]      in_score_row,
    input  logic [POS_W-1:0]      in_score_col,
    input  logic                  in_score_last,

    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [15:0]           out_score_bf16,
    output logic [HEAD_W-1:0]     out_score_head,
    output logic [POS_W-1:0]      out_score_row,
    output logic [POS_W-1:0]      out_score_col,
    output logic                  out_score_last,

    output logic                  busy,
    output logic [31:0]           tiles_enqueued,
    output logic [31:0]           tiles_dequeued,
    output logic [31:0]           input_backpressure_cycles,
    output logic [7:0]            occupancy,
    output logic [7:0]            max_occupancy,
    output logic                  protocol_error
);
    localparam int ITEMS      = TILE*TILE;
    localparam int ITEM_W     = 16 + HEAD_W + POS_W + POS_W + 1;
    localparam int ITEM_IDX_W = (ITEMS <= 1) ? 1 : $clog2(ITEMS);
    localparam int PTR_W      = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam int OCC_W      = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH+1);
    localparam int MEM_ITEMS  = FIFO_DEPTH*ITEMS;
    localparam int ADDR_W     = (MEM_ITEMS <= 1) ? 1 : $clog2(MEM_ITEMS);

    (* ram_style = "distributed" *)
    logic [ITEM_W-1:0] item_mem [0:MEM_ITEMS-1];

    logic [PTR_W-1:0] wr_ptr;
    logic [PTR_W-1:0] rd_ptr;
    logic [ITEM_IDX_W-1:0] wr_item_idx;
    logic [ITEM_IDX_W-1:0] rd_item_idx;
    logic [OCC_W-1:0] occupancy_reg;
    logic [OCC_W-1:0] occupancy_next;

    logic [HEAD_W-1:0] tile_head;
    logic [POS_W-1:0] tile_row_base;
    logic [POS_W-1:0] tile_col_base;

    logic [ITEM_W-1:0] in_item;
    logic [ITEM_W-1:0] out_item;
    logic [ADDR_W-1:0] wr_addr;
    logic [ADDR_W-1:0] rd_addr;
    logic write_item;
    logic write_tile_commit;
    logic read_item;
    logic read_tile_commit;

    function automatic logic [PTR_W-1:0] ptr_inc(
        input logic [PTR_W-1:0] ptr
    );
        if ($unsigned(ptr) == FIFO_DEPTH-1)
            ptr_inc = '0;
        else
            ptr_inc = ptr + 1'b1;
    endfunction

    function automatic logic [ADDR_W-1:0] item_addr(
        input logic [PTR_W-1:0] slot,
        input logic [ITEM_IDX_W-1:0] item_index
    );
        item_addr = ($unsigned(slot)*ITEMS) + $unsigned(item_index);
    endfunction

    function automatic logic [7:0] occ_to_u8(
        input logic [OCC_W-1:0] value
    );
        integer bit_index;
        begin
            occ_to_u8 = 8'd0;
            for (bit_index = 0; (bit_index < OCC_W) && (bit_index < 8);
                 bit_index = bit_index + 1)
                occ_to_u8[bit_index] = value[bit_index];
        end
    endfunction

    assign in_item = {
        in_score_last,
        in_score_col,
        in_score_row,
        in_score_head,
        in_score_bf16
    };

    assign wr_addr = item_addr(wr_ptr, wr_item_idx);
    assign rd_addr = item_addr(rd_ptr, rd_item_idx);

    assign out_valid = rst_n && (occupancy_reg != 0);
    assign out_item = out_valid ? item_mem[rd_addr] : '0;
    assign out_score_bf16 = out_item[0 +: 16];
    assign out_score_head = out_item[16 +: HEAD_W];
    assign out_score_row  = out_item[16+HEAD_W +: POS_W];
    assign out_score_col  = out_item[16+HEAD_W+POS_W +: POS_W];
    assign out_score_last = out_item[ITEM_W-1];

    assign read_item = out_valid && out_ready;
    assign read_tile_commit = read_item && (rd_item_idx == ITEMS-1);

    // A partial input tile owns the current write slot. If no partial tile is
    // present, a new tile may start when a slot is free, or when the final item
    // of the oldest tile releases a slot in this same cycle.
    assign in_ready = rst_n &&
        ((wr_item_idx != 0) ||
         ($unsigned(occupancy_reg) < FIFO_DEPTH) ||
         read_tile_commit);
    assign write_item = in_valid && in_ready;
    assign write_tile_commit =
        write_item && (wr_item_idx == ITEMS-1);

    always_comb begin
        occupancy_next = occupancy_reg;
        case ({write_tile_commit, read_tile_commit})
            2'b10: occupancy_next = occupancy_reg + 1'b1;
            2'b01: occupancy_next = occupancy_reg - 1'b1;
            default: occupancy_next = occupancy_reg;
        endcase
    end

    assign busy = (occupancy_reg != 0) || (wr_item_idx != 0);
    assign occupancy = occ_to_u8(occupancy_reg);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            wr_item_idx <= '0;
            rd_item_idx <= '0;
            occupancy_reg <= '0;
            tile_head <= '0;
            tile_row_base <= '0;
            tile_col_base <= '0;
            tiles_enqueued <= '0;
            tiles_dequeued <= '0;
            input_backpressure_cycles <= '0;
            max_occupancy <= '0;
            protocol_error <= 1'b0;
        end else begin
            if (status_clear) begin
                tiles_enqueued <= '0;
                tiles_dequeued <= '0;
                input_backpressure_cycles <= '0;
                max_occupancy <= occ_to_u8(occupancy_reg);
                protocol_error <= busy;
            end else begin
                if (in_valid && !in_ready)
                    input_backpressure_cycles <=
                        input_backpressure_cycles + 1'b1;

                if (write_tile_commit)
                    tiles_enqueued <= tiles_enqueued + 1'b1;
                if (read_tile_commit)
                    tiles_dequeued <= tiles_dequeued + 1'b1;

                if (occ_to_u8(occupancy_next) > max_occupancy)
                    max_occupancy <= occ_to_u8(occupancy_next);

                // These conditions are unreachable under legal ready/valid
                // traffic. Keeping them sticky makes integration failures easy
                // to diagnose in simulation or with an ILA.
                if (write_tile_commit && !read_tile_commit &&
                    ($unsigned(occupancy_reg) == FIFO_DEPTH))
                    protocol_error <= 1'b1;
                if (read_tile_commit && !write_tile_commit &&
                    (occupancy_reg == 0))
                    protocol_error <= 1'b1;
            end

            if (write_item) begin
                item_mem[wr_addr] <= in_item;

                if (wr_item_idx == 0) begin
                    tile_head <= in_score_head;
                    tile_row_base <= in_score_row;
                    tile_col_base <= in_score_col;
                    if ((($unsigned(in_score_row) % TILE) != 0) ||
                        (($unsigned(in_score_col) % TILE) != 0))
                        protocol_error <= 1'b1;
                end else begin
                    if ((in_score_head != tile_head) ||
                        ($unsigned(in_score_row) !=
                         ($unsigned(tile_row_base) +
                          ($unsigned(wr_item_idx) / TILE))) ||
                        ($unsigned(in_score_col) !=
                         ($unsigned(tile_col_base) +
                          ($unsigned(wr_item_idx) % TILE))))
                        protocol_error <= 1'b1;
                end

                if (in_score_last && (wr_item_idx != ITEMS-1))
                    protocol_error <= 1'b1;

                if (write_tile_commit) begin
                    wr_ptr <= ptr_inc(wr_ptr);
                    wr_item_idx <= '0;
                end else begin
                    wr_item_idx <= wr_item_idx + 1'b1;
                end
            end

            if (read_item) begin
                if (read_tile_commit) begin
                    rd_ptr <= ptr_inc(rd_ptr);
                    rd_item_idx <= '0;
                end else begin
                    rd_item_idx <= rd_item_idx + 1'b1;
                end
            end

            occupancy_reg <= occupancy_next;
        end
    end

    initial begin
        if (TILE != 4)
            $error("flash_score_tile_fifo: current integration requires TILE=4");
        if (FIFO_DEPTH < 2)
            $error("flash_score_tile_fifo: FIFO_DEPTH must be at least 2");
        if (FIFO_DEPTH > 255)
            $error("flash_score_tile_fifo: occupancy output is 8 bit");
        if (HEAD_W < 1 || POS_W < 1)
            $error("flash_score_tile_fifo: metadata widths must be positive");
    end
endmodule
