`timescale 1ns/1ps

// One independently addressed Context lane.  Splitting the 16 PE lanes into
// separate banks avoids presenting Vivado with a single 16-write-port 3-D RAM
// and allows each 32-bit x feature-tile store to map to distributed RAM.
module online_context_bank #(
    parameter int DEPTH  = 32,
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic              clk,
    input  logic              clear_write,
    input  logic [ADDR_W-1:0] clear_addr,
    input  logic              write_en,
    input  logic [ADDR_W-1:0] write_addr,
    input  logic [31:0]       write_data,
    input  logic [ADDR_W-1:0] read_addr,
    output logic [31:0]       read_data
);
    (* ram_style = "distributed" *) logic [31:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (clear_write)
            mem[clear_addr] <= 32'h0000_0000;
        else if (write_en)
            mem[write_addr] <= write_data;
    end

    assign read_data = mem[read_addr];
endmodule
