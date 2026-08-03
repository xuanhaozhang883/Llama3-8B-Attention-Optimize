`timescale 1ns/1ps

// Synthesizable BF16 V-cache used by the B+C system wrapper.
//
// Storage is vectorized at LANES BF16 values per RAM word.  The PV loader
// always requests an aligned feature tile, so this organization implements one
// registered RAM read per request and maps cleanly to a simple dual-port BRAM:
// one vector load/write port and one vector read port.
module bf16_v_cache #(
    parameter int NUM_KV_HEADS = 8,
    parameter int SEQ_LEN      = 128,
    parameter int HEAD_DIM     = 128,
    parameter int LANES        = 2,
    parameter int ADDR_W       = ((NUM_KV_HEADS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
                                 $clog2(NUM_KV_HEADS*SEQ_LEN*HEAD_DIM)
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // Initialization/update port. load_addr is the scalar BF16 address of
    // lane zero and must be LANES-aligned.
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [ADDR_W-1:0]      load_addr,
    input  logic [LANES*16-1:0]    load_data,

    // One-outstanding elastic read channel used by pv_input_loader.
    input  logic                   req_valid,
    output logic                   req_ready,
    input  logic [ADDR_W-1:0]      req_addr,
    output logic                   rsp_valid,
    input  logic                   rsp_ready,
    output logic [LANES*16-1:0]    rsp_data,

    output logic                   protocol_error
);
    localparam int TOTAL_SCALARS = NUM_KV_HEADS * SEQ_LEN * HEAD_DIM;
    localparam int DEPTH         = TOTAL_SCALARS / LANES;
    localparam int LANE_SHIFT    = (LANES <= 1) ? 0 : $clog2(LANES);
    localparam int MEM_ADDR_W    = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    (* ram_style = "block" *) logic [LANES*16-1:0] v_mem [0:DEPTH-1];

    logic [MEM_ADDR_W-1:0] load_mem_addr;
    logic [MEM_ADDR_W-1:0] req_mem_addr;
    logic load_addr_valid;
    logic req_addr_valid;
    logic rsp_valid_reg;
    logic [LANES*16-1:0] rsp_data_reg;

    assign load_mem_addr = $unsigned(load_addr) >> LANE_SHIFT;
    assign req_mem_addr  = $unsigned(req_addr)  >> LANE_SHIFT;

    assign load_addr_valid =
        (($unsigned(load_addr) & (LANES-1)) == 0) &&
        ($unsigned(load_addr) <= TOTAL_SCALARS-LANES);
    assign req_addr_valid =
        (($unsigned(req_addr) & (LANES-1)) == 0) &&
        ($unsigned(req_addr) <= TOTAL_SCALARS-LANES);

    assign load_ready = rst_n;
    assign req_ready  = rst_n && (!rsp_valid_reg || rsp_ready);
    assign rsp_valid  = rsp_valid_reg;
    assign rsp_data   = rsp_data_reg;

    // Memory payload is intentionally not reset.  The host/loader must fill
    // every address that a run can access before asserting start.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rsp_valid_reg <= 1'b0;
            rsp_data_reg  <= '0;
            protocol_error <= 1'b0;
        end else begin
            if (rsp_valid_reg && rsp_ready)
                rsp_valid_reg <= 1'b0;

            if (load_valid && load_ready) begin
                if (load_addr_valid)
                    v_mem[load_mem_addr] <= load_data;
                else
                    protocol_error <= 1'b1;
            end

            if (req_valid && req_ready) begin
                if (req_addr_valid)
                    rsp_data_reg <= v_mem[req_mem_addr];
                else begin
                    rsp_data_reg  <= '0;
                    protocol_error <= 1'b1;
                end
                rsp_valid_reg <= 1'b1;
            end
        end
    end

    initial begin
        if ((NUM_KV_HEADS < 1) || (SEQ_LEN < 1) || (HEAD_DIM < 1))
            $error("bf16_v_cache: dimensions must be positive");
        if ((LANES < 1) || ((LANES & (LANES-1)) != 0))
            $error("bf16_v_cache: LANES must be a positive power of two");
        if ((HEAD_DIM % LANES) != 0)
            $error("bf16_v_cache: LANES must divide HEAD_DIM");
        if ((TOTAL_SCALARS % LANES) != 0)
            $error("bf16_v_cache: total scalar count must divide by LANES");
    end
endmodule
