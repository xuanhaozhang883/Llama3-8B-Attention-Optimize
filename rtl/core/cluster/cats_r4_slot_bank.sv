`timescale 1ns/1ps

// CATS-R4 C2 storage primitive (infrastructure only).
//
// Three independent 16-bit row-slot planes (A/B/C) are banked 32 ways,
// with 16 rows per bank.  Two requesters are provided for slot reads and
// writes.  Each physical bank is 1R1W: one read and one write may be accepted
// in a cycle; two reads or two writes to the same bank are arbitrated with
// requester-0 priority and raise collision_seen.  A bank owner token prevents
// a second owner from taking a bank until owner_release is asserted.  The
// FP32 accumulator plane is a separate 32-bank x 16-row 1R1W port.
//
// This wrapper deliberately has no connection to A/B math units, AXI, DMA,
// or a cluster top.  It is not a C2 READY claim.
module cats_r4_slot_bank #(
    parameter int BANKS = 32,
    parameter int ROWS  = 16,
    parameter int OWNER_W = 2,
    parameter int BANK_W = (BANKS <= 1) ? 1 : $clog2(BANKS),
    parameter int ROW_W  = (ROWS  <= 1) ? 1 : $clog2(ROWS)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic [BANKS-1:0] owner_release,

    input  logic [1:0]              wr_valid,
    output logic [1:0]              wr_ready,
    input  logic [1:0][1:0]         wr_owner,
    input  logic [1:0][1:0]         wr_slot,
    input  logic [1:0][BANK_W-1:0]  wr_bank,
    input  logic [1:0][ROW_W-1:0]   wr_row,
    input  logic [1:0][15:0]        wr_data,

    input  logic [1:0]              rd_valid,
    output logic [1:0]              rd_ready,
    input  logic [1:0][1:0]         rd_owner,
    input  logic [1:0][1:0]         rd_slot,
    input  logic [1:0][BANK_W-1:0]  rd_bank,
    input  logic [1:0][ROW_W-1:0]   rd_row,
    output logic [1:0]              rd_rsp_valid,
    input  logic [1:0]              rd_rsp_ready,
    output logic [1:0][15:0]        rd_rsp_data,

    input  logic                    acc_wr_valid,
    output logic                    acc_wr_ready,
    input  logic [OWNER_W-1:0]      acc_wr_owner,
    input  logic [BANK_W-1:0]       acc_wr_bank,
    input  logic [ROW_W-1:0]        acc_wr_row,
    input  logic [31:0]             acc_wr_data,

    input  logic                    acc_rd_valid,
    output logic                    acc_rd_ready,
    input  logic [OWNER_W-1:0]      acc_rd_owner,
    input  logic [BANK_W-1:0]       acc_rd_bank,
    input  logic [ROW_W-1:0]        acc_rd_row,
    output logic                    acc_rsp_valid,
    input  logic                    acc_rsp_ready,
    output logic [31:0]             acc_rsp_data,

    output logic                    collision_seen,
    output logic                    protocol_error
);
    localparam int SLOT_COUNT = 3;

    (* ram_style = "block" *) logic [15:0] slot_mem [0:SLOT_COUNT-1][0:BANKS-1][0:ROWS-1];
    (* ram_style = "block" *) logic [31:0] accum_mem [0:BANKS-1][0:ROWS-1];
    logic [BANKS-1:0] owner_valid;
    logic [BANKS-1:0][OWNER_W-1:0] bank_owner;

    logic [1:0] wr_eligible, rd_eligible;
    logic [1:0] wr_fire, rd_fire;
    logic acc_wr_eligible, acc_rd_eligible;
    logic acc_wr_fire, acc_rd_fire;
    integer i;

    always_comb begin
        wr_eligible = '0;
        rd_eligible = '0;
        for (i = 0; i < 2; i = i + 1) begin
            wr_eligible[i] = wr_valid[i] &&
                ($unsigned(wr_slot[i]) < SLOT_COUNT) &&
                ($unsigned(wr_bank[i]) < BANKS) &&
                ($unsigned(wr_row[i]) < ROWS) &&
                (!owner_valid[wr_bank[i]] ||
                 (bank_owner[wr_bank[i]] == wr_owner[i]));
            rd_eligible[i] = rd_valid[i] &&
                ($unsigned(rd_slot[i]) < SLOT_COUNT) &&
                ($unsigned(rd_bank[i]) < BANKS) &&
                ($unsigned(rd_row[i]) < ROWS) &&
                (!owner_valid[rd_bank[i]] ||
                 (bank_owner[rd_bank[i]] == rd_owner[i]));
        end

        // 1R1W arbitration.  Read and write to one bank are intentionally
        // allowed in the same cycle; same-direction collisions are rejected.
        wr_ready = wr_eligible;
        // Each response register is a one-entry elastic buffer.  Do not
        // accept a new read when its previous response is backpressured;
        // otherwise rd_rsp_data/valid would be overwritten before transfer.
        for (i = 0; i < 2; i = i + 1)
            rd_ready[i] = rd_eligible[i] &&
                (!rd_rsp_valid[i] || rd_rsp_ready[i]);
        if (wr_eligible[0] && wr_eligible[1] &&
            (wr_bank[0] == wr_bank[1]))
            wr_ready[1] = 1'b0;
        if (rd_eligible[0] && rd_eligible[1] &&
            (rd_slot[0] == rd_slot[1]) &&
            (rd_bank[0] == rd_bank[1]))
            rd_ready[1] = 1'b0;

        // Accumulator port is itself 1R1W and is independent of slot ports.
        acc_wr_ready = acc_wr_eligible;
        acc_rd_ready = acc_rd_eligible &&
            (!acc_rsp_valid || acc_rsp_ready);

        // When an unowned bank sees unlike owners in both directions, the
        // write wins ownership for this cycle and the read waits one cycle.
        for (i = 0; i < 2; i = i + 1)
            if (rd_ready[i] && acc_wr_eligible &&
                (rd_bank[i] == acc_wr_bank) && !owner_valid[rd_bank[i]] &&
                (rd_owner[i] != acc_wr_owner))
                rd_ready[i] = 1'b0;
        if (acc_rd_eligible && wr_eligible[0] &&
            (acc_rd_bank == wr_bank[0]) && !owner_valid[acc_rd_bank] &&
            (acc_rd_owner != wr_owner[0]))
            acc_rd_ready = 1'b0;

        wr_fire = wr_valid & wr_ready;
        rd_fire = rd_valid & rd_ready;
        acc_wr_fire = acc_wr_valid && acc_wr_ready;
        acc_rd_fire = acc_rd_valid && acc_rd_ready;
    end

    always_comb begin
        acc_wr_eligible = acc_wr_valid &&
            ($unsigned(acc_wr_bank) < BANKS) &&
            ($unsigned(acc_wr_row) < ROWS) &&
            (!owner_valid[acc_wr_bank] ||
             (bank_owner[acc_wr_bank] == acc_wr_owner));
        acc_rd_eligible = acc_rd_valid &&
            ($unsigned(acc_rd_bank) < BANKS) &&
            ($unsigned(acc_rd_row) < ROWS) &&
            (!owner_valid[acc_rd_bank] ||
             (bank_owner[acc_rd_bank] == acc_rd_owner));
    end

    assign collision_seen = collision_seen_reg;
    logic collision_seen_reg;

    always_ff @(posedge clk) begin : p_storage
        integer s;
        integer b;
        integer r;
        if (!rst_n || clear) begin
            owner_valid       <= '0;
            bank_owner        <= '0;
            rd_rsp_valid      <= '0;
            rd_rsp_data       <= '0;
            acc_rsp_valid     <= 1'b0;
            acc_rsp_data      <= '0;
            collision_seen_reg<= 1'b0;
            protocol_error    <= 1'b0;
        end else begin
            for (b = 0; b < BANKS; b = b + 1)
                if (owner_release[b]) owner_valid[b] <= 1'b0;

            if (wr_valid[0] && wr_valid[1] && (wr_bank[0] == wr_bank[1]))
                collision_seen_reg <= 1'b1;
            if (rd_valid[0] && rd_valid[1] &&
                (rd_slot[0] == rd_slot[1]) &&
                (rd_bank[0] == rd_bank[1]))
                collision_seen_reg <= 1'b1;

            for (i = 0; i < 2; i = i + 1) begin
                if (rd_rsp_valid[i] && rd_rsp_ready[i])
                    rd_rsp_valid[i] <= 1'b0;
                if (wr_valid[i] && !wr_ready[i] &&
                    (($unsigned(wr_slot[i]) >= SLOT_COUNT) ||
                     ($unsigned(wr_bank[i]) >= BANKS) ||
                     ($unsigned(wr_row[i]) >= ROWS)))
                    protocol_error <= 1'b1;
                if (rd_valid[i] && !rd_ready[i] &&
                    (($unsigned(rd_slot[i]) >= SLOT_COUNT) ||
                     ($unsigned(rd_bank[i]) >= BANKS) ||
                     ($unsigned(rd_row[i]) >= ROWS)))
                    protocol_error <= 1'b1;
                if (wr_fire[i]) begin
                    slot_mem[wr_slot[i]][wr_bank[i]][wr_row[i]] <= wr_data[i];
                    if (!owner_valid[wr_bank[i]]) begin
                        owner_valid[wr_bank[i]] <= 1'b1;
                        bank_owner[wr_bank[i]] <= wr_owner[i];
                    end
                end
                if (rd_fire[i]) begin
                    rd_rsp_data[i] <= slot_mem[rd_slot[i]][rd_bank[i]][rd_row[i]];
                    rd_rsp_valid[i] <= 1'b1;
                    if (!owner_valid[rd_bank[i]]) begin
                        owner_valid[rd_bank[i]] <= 1'b1;
                        bank_owner[rd_bank[i]] <= rd_owner[i];
                    end
                end
            end

            if (acc_wr_valid && !acc_wr_ready &&
                (($unsigned(acc_wr_bank) >= BANKS) ||
                 ($unsigned(acc_wr_row) >= ROWS)))
                protocol_error <= 1'b1;
            if (acc_rd_valid && !acc_rd_ready &&
                (($unsigned(acc_rd_bank) >= BANKS) ||
                 ($unsigned(acc_rd_row) >= ROWS)))
                protocol_error <= 1'b1;
            if (acc_rsp_valid && acc_rsp_ready)
                acc_rsp_valid <= 1'b0;
            if (acc_wr_fire) begin
                accum_mem[acc_wr_bank][acc_wr_row] <= acc_wr_data;
                if (!owner_valid[acc_wr_bank]) begin
                    owner_valid[acc_wr_bank] <= 1'b1;
                    bank_owner[acc_wr_bank] <= acc_wr_owner;
                end
            end
            if (acc_rd_fire) begin
                acc_rsp_data  <= accum_mem[acc_rd_bank][acc_rd_row];
                acc_rsp_valid <= 1'b1;
                if (!owner_valid[acc_rd_bank]) begin
                    owner_valid[acc_rd_bank] <= 1'b1;
                    bank_owner[acc_rd_bank] <= acc_rd_owner;
                end
            end
        end
    end

    initial begin
        if (BANKS != 32) $error("cats_r4_slot_bank: CATS-R4 requires BANKS=32");
        if (ROWS != 16)  $error("cats_r4_slot_bank: CATS-R4 requires ROWS=16");
    end
endmodule
