`timescale 1ns/1ps

// One explicit simple-dual-port RAM. Keeping the storage inside a leaf module
// avoids Vivado treating a multi-dimensional aggregate as a giant register.
module rope_cache_bank_ram #(
    parameter int DEPTH = 2048,
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic clk,
    input  logic wr_en,
    input  logic [ADDR_W-1:0] wr_addr,
    input  logic [31:0] wr_data,
    input  logic rd_en,
    input  logic [ADDR_W-1:0] rd_addr,
    output logic [31:0] rd_data
);
    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        if (rd_en)
            rd_data <= mem[rd_addr];
    end
endmodule

// Group-local rotated Q/K store. There are 4 banks per head, selected by
// token % TILE. Each RAM word stores {upper_half, lower_half} for one pair.
module rope_qk_group_cache #(
    parameter int TILE = 4,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int Q_HEADS = 4,
    parameter int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int POS_W = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int PAIR_W = ((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic wr_valid,
    output logic wr_ready,
    input  logic wr_is_k,
    input  logic [HEAD_W-1:0] wr_head,
    input  logic [POS_W-1:0] wr_token,
    input  logic [PAIR_W-1:0] wr_pair,
    input  logic [15:0] wr_y0,
    input  logic [15:0] wr_y1,
    input  logic mark_complete,
    output logic cache_complete,
    input  logic load_enable,
    input  logic [HEAD_W-1:0] req_head,
    input  logic [POS_W-1:0] req_row_base,
    input  logic [POS_W-1:0] req_col_base,
    input  logic [DIM_W-1:0] req_dim,
    output logic vec_valid,
    input  logic vec_ready,
    output logic [TILE*16-1:0] q_vec_bf16,
    output logic [TILE*16-1:0] k_vec_bf16
);
    localparam int HALF_DIM = HEAD_DIM/2;
    localparam int TOKENS_PER_BANK = SEQ_LEN/TILE;
    localparam int BANK_DEPTH = TOKENS_PER_BANK*HALF_DIM;
    localparam int BANK_ADDR_W = (BANK_DEPTH <= 1) ? 1 : $clog2(BANK_DEPTH);

    logic [BANK_ADDR_W-1:0] wr_addr;
    logic [BANK_ADDR_W-1:0] q_rd_addr [0:TILE-1];
    logic [BANK_ADDR_W-1:0] k_rd_addr [0:TILE-1];
    logic [31:0] q_rd_data [0:Q_HEADS-1][0:TILE-1];
    logic [31:0] k_rd_data [0:TILE-1];
    logic [DIM_W-1:0] read_pair;
    logic read_pending;
    logic read_upper;
    logic [HEAD_W-1:0] read_head;
    logic load_request;

    assign wr_ready = rst_n;
    assign wr_addr = (($unsigned(wr_token)/TILE)*HALF_DIM) + $unsigned(wr_pair);
    assign read_pair = (req_dim < HALF_DIM) ? req_dim : req_dim-HALF_DIM;
    // qk_systolic_gqa_top asserts ready independently while it is requesting
    // a beat, so ready is also the request qualifier for this registered RAM.
    assign load_request = !vec_valid && !read_pending && load_enable &&
                          cache_complete && vec_ready;

    genvar gh, gb;
    generate
        for (gb=0; gb<TILE; gb=gb+1) begin : GEN_BANK_ADDR
            assign q_rd_addr[gb] = (((($unsigned(req_row_base)+gb)/TILE)*HALF_DIM) +
                                    $unsigned(read_pair));
            assign k_rd_addr[gb] = (((($unsigned(req_col_base)+gb)/TILE)*HALF_DIM) +
                                    $unsigned(read_pair));
            rope_cache_bank_ram #(.DEPTH(BANK_DEPTH),.ADDR_W(BANK_ADDR_W)) u_k_ram (
                .clk,
                .wr_en(wr_valid && wr_ready && wr_is_k &&
                       (($unsigned(wr_token)%TILE)==gb)),
                .wr_addr, .wr_data({wr_y1,wr_y0}),
                .rd_en(load_request), .rd_addr(k_rd_addr[gb]),
                .rd_data(k_rd_data[gb])
            );
            for (gh=0; gh<Q_HEADS; gh=gh+1) begin : GEN_Q_HEAD
                rope_cache_bank_ram #(.DEPTH(BANK_DEPTH),.ADDR_W(BANK_ADDR_W)) u_q_ram (
                    .clk,
                    .wr_en(wr_valid && wr_ready && !wr_is_k &&
                           ($unsigned(wr_head)==gh) &&
                           (($unsigned(wr_token)%TILE)==gb)),
                    .wr_addr, .wr_data({wr_y1,wr_y0}),
                    .rd_en(load_request && ($unsigned(req_head)==gh)),
                    .rd_addr(q_rd_addr[gb]), .rd_data(q_rd_data[gh][gb])
                );
            end
        end
    endgenerate

    integer lane;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cache_complete <= 1'b0;
            vec_valid <= 1'b0;
            read_pending <= 1'b0;
            read_upper <= 1'b0;
            read_head <= '0;
            q_vec_bf16 <= '0;
            k_vec_bf16 <= '0;
        end else begin
            if (clear) begin
                cache_complete <= 1'b0;
                vec_valid <= 1'b0;
                read_pending <= 1'b0;
            end else begin
                if (mark_complete)
                    cache_complete <= 1'b1;
                if (vec_valid && vec_ready)
                    vec_valid <= 1'b0;

                if (load_request) begin
                    read_pending <= 1'b1;
                    read_upper <= (req_dim >= HALF_DIM);
                    read_head <= req_head;
                end else if (read_pending) begin
                    for (lane=0; lane<TILE; lane=lane+1) begin
                        q_vec_bf16[lane*16 +:16] <= read_upper ?
                            q_rd_data[read_head][lane][31:16] :
                            q_rd_data[read_head][lane][15:0];
                        k_vec_bf16[lane*16 +:16] <= read_upper ?
                            k_rd_data[lane][31:16] : k_rd_data[lane][15:0];
                    end
                    read_pending <= 1'b0;
                    vec_valid <= 1'b1;
                end
            end
        end
    end

    initial begin
        if ((SEQ_LEN % TILE) != 0)
            $error("rope_qk_group_cache: TILE must divide SEQ_LEN");
        if ((HEAD_DIM % 2) != 0)
            $error("rope_qk_group_cache: HEAD_DIM must be even");
        if (Q_HEADS != 4)
            $error("rope_qk_group_cache: formal integration requires Q_HEADS=4");
    end
endmodule
