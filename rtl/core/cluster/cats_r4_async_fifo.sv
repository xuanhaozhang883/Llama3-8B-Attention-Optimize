`timescale 1ns/1ps

// CATS-R4 CDC primitive: dual-clock, Gray-pointer asynchronous FIFO.
//
// The memory is intentionally written only in wr_clk and read only in rd_clk.
// Full/empty decisions use synchronized Gray pointers; no multi-bit payload
// crosses the domains without a storage location.  This module is an
// infrastructure primitive and does not own any CATS numerical semantics.
module cats_r4_async_fifo #(
    parameter int DATA_WIDTH = 64,
    parameter int ADDR_WIDTH = 4
) (
    input  logic                  wr_clk,
    input  logic                  wr_rst_n,
    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,
    output logic                  wr_full,
    output logic [ADDR_WIDTH:0]   wr_level,

    input  logic                  rd_clk,
    input  logic                  rd_rst_n,
    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  rd_empty,
    output logic [ADDR_WIDTH:0]   rd_level
);
    localparam int DEPTH = 1 << ADDR_WIDTH;

    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_WIDTH:0] wr_bin, wr_gray;
    logic [ADDR_WIDTH:0] rd_bin, rd_gray;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [ADDR_WIDTH:0] rd_gray_wr_meta, rd_gray_wr_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [ADDR_WIDTH:0] wr_gray_rd_meta, wr_gray_rd_sync;
    logic [ADDR_WIDTH:0] wr_bin_next, wr_gray_next;
    logic [ADDR_WIDTH:0] rd_bin_next, rd_gray_next;
    logic wr_full_next, rd_empty_next;

    function automatic [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] value);
        bin2gray = (value >> 1) ^ value;
    endfunction

    // Invert the two MSBs for the asynchronous FIFO full comparison.
    function automatic [ADDR_WIDTH:0] full_gray(input [ADDR_WIDTH:0] value);
        logic [ADDR_WIDTH:0] tmp;
        begin
            tmp = value;
            tmp[ADDR_WIDTH:ADDR_WIDTH-1] = ~value[ADDR_WIDTH:ADDR_WIDTH-1];
            full_gray = tmp;
        end
    endfunction

    // Continuous next-state equations avoid simulator-dependent always_comb
    // re-triggering on intermediate next-state signals.  All cross-domain
    // operands remain the two-stage synchronized Gray pointers.
    assign wr_bin_next  = wr_bin + ((wr_en && !wr_full) ? 1'b1 : 1'b0);
    assign wr_gray_next = bin2gray(wr_bin_next);
    assign wr_full_next = (wr_gray_next == full_gray(rd_gray_wr_sync));
    assign wr_level     = wr_bin - gray_to_bin(rd_gray_wr_sync);

    assign rd_bin_next   = rd_bin + ((rd_en && !rd_empty) ? 1'b1 : 1'b0);
    assign rd_gray_next  = bin2gray(rd_bin_next);
    assign rd_empty_next = (rd_gray_next == wr_gray_rd_sync);
    assign rd_level      = gray_to_bin(wr_gray_rd_sync) - rd_bin;

    function automatic [ADDR_WIDTH:0] gray_to_bin(input [ADDR_WIDTH:0] value);
        integer i;
        begin
            gray_to_bin[ADDR_WIDTH] = value[ADDR_WIDTH];
            for (i = ADDR_WIDTH-1; i >= 0; i = i - 1)
                gray_to_bin[i] = gray_to_bin[i+1] ^ value[i];
        end
    endfunction

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= '0;
            wr_gray <= '0;
            wr_full <= 1'b0;
            rd_gray_wr_meta <= '0;
            rd_gray_wr_sync <= '0;
        end else begin
            rd_gray_wr_meta <= rd_gray;
            rd_gray_wr_sync <= rd_gray_wr_meta;
            if (wr_en && !wr_full)
                mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            wr_bin <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= '0;
            rd_gray <= '0;
            rd_empty <= 1'b1;
            wr_gray_rd_meta <= '0;
            wr_gray_rd_sync <= '0;
            rd_data <= '0;
        end else begin
            wr_gray_rd_meta <= wr_gray;
            wr_gray_rd_sync <= wr_gray_rd_meta;
            if (rd_en && !rd_empty)
                rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin <= rd_bin_next;
            rd_gray <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    initial begin
        if (DATA_WIDTH < 1)
            $error("cats_r4_async_fifo: DATA_WIDTH must be positive");
        if (ADDR_WIDTH < 1)
            $error("cats_r4_async_fifo: ADDR_WIDTH must be positive");
    end
endmodule
