`timescale 1ns/1ps

// Dedicated simple-dual-port storage for score_rowtile_buffer.
//
// Keeping the memory in this small module is intentional: Vivado 2019.2 did
// not recognize the previous memory access embedded in the reorder FSM as a
// block-RAM template, even with ram_style="block".  This is the standard
// common-clock SDP form: one full-word write port and one registered,
// full-word read port.  The payload is never reset; the parent only exposes
// data after all addressed locations have been written.
module score_rowtile_payload_bram #(
    parameter int DATA_W = 17,
    parameter int DEPTH  = 512,
    parameter int ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input  logic                clk,

    input  logic                wr_en,
    input  logic [ADDR_W-1:0]   wr_addr,
    input  logic [DATA_W-1:0]   wr_data,

    input  logic                rd_en,
    input  logic [ADDR_W-1:0]   rd_addr,
    output logic [DATA_W-1:0]   rd_data
);
    (* ram_style = "block" *) logic [DATA_W-1:0] mem [0:DEPTH-1];

    // Do not add reset logic to this process.  Resetting the memory or its
    // complete read datapath can prevent portable BRAM inference.
    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;

        if (rd_en)
            rd_data <= mem[rd_addr];
    end

    initial begin
        if (DATA_W < 1)
            $error("score_rowtile_payload_bram: DATA_W must be >= 1");
        if (DEPTH < 1)
            $error("score_rowtile_payload_bram: DEPTH must be >= 1");
        if ((1 << ADDR_W) < DEPTH)
            $error("score_rowtile_payload_bram: ADDR_W is too small");
    end
endmodule
