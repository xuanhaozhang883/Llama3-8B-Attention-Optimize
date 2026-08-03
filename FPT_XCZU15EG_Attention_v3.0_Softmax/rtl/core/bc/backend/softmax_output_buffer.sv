`timescale 1ns/1ps

// Buffers Softmax probabilities in groups of TILE complete rows.
// Input order must be [q_head][q_row][k_col], with k_col contiguous.
// Two banks allow Softmax to fill one row tile while the PV loader drains the
// other. Each RAM word contains all TILE P values at one reduce index.
module softmax_output_buffer #(
    parameter int Q_HEADS = 4,
    parameter int SEQ_LEN = 128,
    parameter int TILE    = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [2:0] active_group_id,

    input  logic        s_valid,
    output logic        s_ready,
    input  logic [15:0] s_data,
    input  logic [2:0]  s_group_id,
    input  logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] s_head,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] s_row,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] s_col,
    input  logic        s_first,
    input  logic        s_last,
    input  logic        s_group_last,

    output logic        p_tile_valid,
    input  logic        p_tile_ready,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] p_tile_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] p_tile_row_base,

    input  logic        p_req_valid,
    output logic        p_req_ready,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] p_req_reduce_index,
    output logic        p_rsp_valid,
    input  logic        p_rsp_ready,
    output logic [TILE*16-1:0] p_rsp_data,

    input  logic        p_tile_release,

    output logic        input_done,
    output logic        busy,
    output logic        protocol_error
);

    localparam int HEAD_W  = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int SEQ_W   = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);
    localparam int LOCAL_W = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int P_DEPTH = 2 * SEQ_LEN;
    localparam int P_ADDR_W = (P_DEPTH <= 1) ? 1 : $clog2(P_DEPTH);

    // The bank bit is folded into the address.  Each TILE lane has a separate
    // 16-bit simple dual-port RAM so scalar Softmax writes use a full-word
    // write enable.  A single TILE*16 RAM with a variable 16-bit part-select
    // write expands into many one-bit BRAMs in Vivado 2019.2.

    logic [1:0] bank_full;
    logic [HEAD_W-1:0] bank_head [0:1];
    logic [SEQ_W-1:0] bank_row_base [0:1];

    logic wr_bank;
    logic [LOCAL_W-1:0] wr_local_row;
    logic [SEQ_W-1:0] wr_col;
    logic [HEAD_W-1:0] expected_head;
    logic [SEQ_W-1:0] expected_row_base;

    logic rd_bank;
    logic tile_active;

    logic p_rsp_valid_reg;
    logic [15:0] p_rsp_lane_reg [0:TILE-1];
    logic run_active;
    logic [P_ADDR_W-1:0] wr_mem_addr;
    logic [P_ADDR_W-1:0] rd_mem_addr;
    logic [2:0] group_id_reg;

    function automatic [P_ADDR_W-1:0] bank_address(
        input logic bank,
        input logic [SEQ_W-1:0] reduce_index
    );
        begin
            bank_address = $unsigned(reduce_index);
            if (bank)
                bank_address = SEQ_LEN + $unsigned(reduce_index);
        end
    endfunction

    // Do not accept a stale Softmax beat before the top-level start pulse.
    assign s_ready = run_active && !input_done && !bank_full[wr_bank];

    assign p_tile_valid    = !tile_active && bank_full[rd_bank];
    assign p_tile_head     = bank_head[rd_bank];
    assign p_tile_row_base = bank_row_base[rd_bank];

    assign p_req_ready = tile_active && (!p_rsp_valid_reg || p_rsp_ready);
    assign p_rsp_valid = p_rsp_valid_reg;
    integer pack_lane;
    always_comb begin
        p_rsp_data = '0;
        for (pack_lane = 0; pack_lane < TILE; pack_lane = pack_lane + 1)
            p_rsp_data[pack_lane*16 +: 16] = p_rsp_lane_reg[pack_lane];
    end

    assign wr_mem_addr = bank_address(wr_bank, wr_col);
    assign rd_mem_addr = bank_address(rd_bank, p_req_reduce_index);

    assign busy = run_active &&
                  (!input_done || tile_active || p_rsp_valid_reg || (|bank_full));

    // Independent full-word write and registered read ports form one BRAM
    // inference template per lane. Memory contents do not need reset;
    // bank_full protects them.
    genvar p_lane;
    generate
        for (p_lane = 0; p_lane < TILE; p_lane = p_lane + 1) begin : GEN_P_LANE
            (* ram_style = "block" *) logic [15:0] p_mem_lane [0:P_DEPTH-1];

            always_ff @(posedge clk) begin
                if (!rst_n || start) begin
                    p_rsp_lane_reg[p_lane] <= '0;
                end else begin
                    if (s_valid && s_ready &&
                        ($unsigned(wr_local_row) == p_lane))
                        p_mem_lane[wr_mem_addr] <= s_data;

                    if (p_req_valid && p_req_ready) begin
                        if ($unsigned(p_req_reduce_index) >= SEQ_LEN)
                            p_rsp_lane_reg[p_lane] <= '0;
                        else
                            p_rsp_lane_reg[p_lane] <= p_mem_lane[rd_mem_addr];
                    end
                end
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            bank_full          <= 2'b00;
            bank_head[0]       <= '0;
            bank_head[1]       <= '0;
            bank_row_base[0]   <= '0;
            bank_row_base[1]   <= '0;
            wr_bank            <= 1'b0;
            wr_local_row       <= '0;
            wr_col             <= '0;
            expected_head      <= '0;
            expected_row_base  <= '0;
            rd_bank            <= 1'b0;
            tile_active        <= 1'b0;
            p_rsp_valid_reg    <= 1'b0;
            run_active         <= rst_n && start;
            group_id_reg       <= active_group_id;
            input_done         <= 1'b0;
            protocol_error     <= 1'b0;
        end else begin
            if (p_rsp_valid_reg && p_rsp_ready)
                p_rsp_valid_reg <= 1'b0;

            if (p_tile_valid && p_tile_ready)
                tile_active <= 1'b1;

            // One registered wide P read; the response is elastic.
            if (p_req_valid && p_req_ready) begin
                if ($unsigned(p_req_reduce_index) >= SEQ_LEN)
                    protocol_error <= 1'b1;
                p_rsp_valid_reg <= 1'b1;
            end

            if (p_tile_release) begin
                if (!tile_active || p_rsp_valid_reg) begin
                    protocol_error <= 1'b1;
                end else begin
                    bank_full[rd_bank] <= 1'b0;
                    rd_bank     <= ~rd_bank;
                    tile_active <= 1'b0;
                end
            end

            // Softmax output is already row-major. Pack the same k_col from
            // TILE adjacent rows into one wide P-memory word.
            if (s_valid && s_ready) begin
                if ((s_group_id != group_id_reg) ||
                    (s_head != expected_head) ||
                    ($unsigned(s_row) !=
                     ($unsigned(expected_row_base) + $unsigned(wr_local_row))) ||
                    (s_col != wr_col) ||
                    (s_first != (wr_col == 0)) ||
                    (s_last != (wr_col == SEQ_LEN-1)) ||
                    (s_group_last != ((expected_head == Q_HEADS-1) &&
                                      (expected_row_base == SEQ_LEN-TILE) &&
                                      (wr_local_row == TILE-1) &&
                                      (wr_col == SEQ_LEN-1)))) begin
                    protocol_error <= 1'b1;
                end

                if (wr_col == SEQ_LEN-1) begin
                    wr_col <= '0;
                    if (wr_local_row == TILE-1) begin
                        bank_full[wr_bank]     <= 1'b1;
                        bank_head[wr_bank]     <= expected_head;
                        bank_row_base[wr_bank] <= expected_row_base;
                        wr_bank      <= ~wr_bank;
                        wr_local_row <= '0;

                        if ((expected_head == Q_HEADS-1) &&
                            (expected_row_base == SEQ_LEN-TILE)) begin
                            input_done <= 1'b1;
                        end else if (expected_row_base + TILE < SEQ_LEN) begin
                            expected_row_base <= expected_row_base + TILE;
                        end else begin
                            expected_row_base <= '0;
                            expected_head <= expected_head + 1'b1;
                        end
                    end else begin
                        wr_local_row <= wr_local_row + 1'b1;
                    end
                end else begin
                    wr_col <= wr_col + 1'b1;
                end
            end
        end
    end

    initial begin
        if (Q_HEADS < 1)
            $error("softmax_output_buffer: Q_HEADS must be >= 1");
        if (SEQ_LEN < 1)
            $error("softmax_output_buffer: SEQ_LEN must be >= 1");
        if ((TILE < 1) || (TILE > SEQ_LEN))
            $error("softmax_output_buffer: TILE must be in [1, SEQ_LEN]");
        if ((SEQ_LEN % TILE) != 0)
            $error("softmax_output_buffer: SEQ_LEN must be divisible by TILE");
        if ((TILE & (TILE - 1)) != 0)
            $error("softmax_output_buffer: TILE must be a power of two");
    end

endmodule
