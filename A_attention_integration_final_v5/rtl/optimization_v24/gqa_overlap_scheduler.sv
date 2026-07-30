`timescale 1ns/1ps

// ============================================================================
// gqa_overlap_scheduler
// ----------------------------------------------------------------------------
// Robust two-bank, inter-Group wavefront scheduler.
//
// Steady state:
//   B+C fills Group N+1 while real PV drains Group N from the other bank.
//
// The scheduler first locks a Bank/Group choice in a pending register.  It
// then emits B+C/fill or PV/drain start pulses only when both consumers are
// ready in the same cycle.  This prevents a half-accepted launch.
//
// Buffer states are authoritative:
//   EMPTY(0) -> FILLING(1) -> READY(2) -> DRAINING(3) -> EMPTY(0)
//
// A child/internal protocol fault stops the command and locks start_ready low
// until reset.  Continuing after a datapath protocol fault is intentionally
// forbidden because Bank ownership can no longer be trusted.
// ============================================================================
module gqa_overlap_scheduler #(
    parameter int NUM_GROUPS = 8,
    parameter int GROUP_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS),
    parameter int COUNT_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS+1)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic start_ready,
    output logic busy,
    output logic done,

    // B+C and Buffer-fill form one atomic launch.
    output logic bc_group_start,
    output logic [GROUP_W-1:0] bc_group_id,
    input  logic bc_group_start_ready,
    input  logic bc_group_done,

    output logic fill_start,
    output logic fill_bank,
    output logic [GROUP_W-1:0] fill_group_id,
    input  logic fill_ready,
    input  logic fill_done,
    input  logic fill_done_bank,
    input  logic [GROUP_W-1:0] fill_done_group_id,

    // real-PV and Buffer-drain form one atomic launch.
    output logic pv_start,
    output logic [GROUP_W-1:0] pv_group_id,
    input  logic pv_start_ready,
    input  logic pv_done,

    output logic drain_start,
    output logic drain_bank,
    output logic [GROUP_W-1:0] drain_group_id,
    input  logic drain_ready,

    // Release is asserted in the same cycle in which the active PV reports
    // done, so the Buffer and Scheduler retire the Group on the same edge.
    output logic release_valid,
    output logic release_bank,
    output logic [GROUP_W-1:0] release_group_id,

    input  logic [1:0] bank0_state,
    input  logic [1:0] bank1_state,
    input  logic [GROUP_W-1:0] bank0_group_id,
    input  logic [GROUP_W-1:0] bank1_group_id,

    input  logic child_protocol_error,

    output logic bc_active,
    output logic pv_active,
    output logic [GROUP_W-1:0] bc_active_group_id,
    output logic [GROUP_W-1:0] pv_active_group_id,
    output logic bc_wait_for_empty_bank,
    output logic pv_wait_for_ready_bank,
    output logic group_complete,
    output logic [GROUP_W-1:0] completed_group_id,
    output logic start_while_busy_error,
    output logic protocol_error
);

    localparam logic [1:0] BANK_EMPTY = 2'd0;
    localparam logic [1:0] BANK_READY = 2'd2;

    logic command_active;
    logic fatal_error;
    logic [COUNT_W-1:0] next_bc_count;
    logic [COUNT_W-1:0] next_pv_count;

    logic bc_launch_pending;
    logic bc_pending_bank;
    logic [GROUP_W-1:0] bc_pending_group_id;
    logic bc_active_bank;
    logic bc_done_seen;
    logic fill_done_seen;

    logic pv_launch_pending;
    logic pv_pending_bank;
    logic [GROUP_W-1:0] pv_pending_group_id;
    logic pv_active_bank;

    logic empty_bank_found;
    logic empty_bank_select;
    logic ready_bank_found;
    logic ready_bank_select;
    logic bc_launch_fire;
    logic pv_launch_fire;
    logic fill_done_matches;
    logic internal_fault;

    always_comb begin
        empty_bank_found  = 1'b0;
        empty_bank_select = 1'b0;

        if (bank0_state == BANK_EMPTY) begin
            empty_bank_found  = 1'b1;
            empty_bank_select = 1'b0;
        end else if (bank1_state == BANK_EMPTY) begin
            empty_bank_found  = 1'b1;
            empty_bank_select = 1'b1;
        end

        ready_bank_found  = 1'b0;
        ready_bank_select = 1'b0;

        if ((bank0_state == BANK_READY) &&
            (bank0_group_id == next_pv_count[GROUP_W-1:0])) begin
            ready_bank_found  = 1'b1;
            ready_bank_select = 1'b0;
        end else if ((bank1_state == BANK_READY) &&
                     (bank1_group_id ==
                      next_pv_count[GROUP_W-1:0])) begin
            ready_bank_found  = 1'b1;
            ready_bank_select = 1'b1;
        end

        // One pulse is delivered to both endpoints only when both endpoints
        // are ready. The pending metadata remains stable while either waits.
        bc_launch_fire =
            bc_launch_pending &&
            bc_group_start_ready &&
            fill_ready;

        pv_launch_fire =
            pv_launch_pending &&
            pv_start_ready &&
            drain_ready;

        bc_group_start = bc_launch_fire;
        fill_start     = bc_launch_fire;
        bc_group_id    = bc_launch_pending ?
            bc_pending_group_id : bc_active_group_id;
        fill_group_id  = bc_launch_pending ?
            bc_pending_group_id : bc_active_group_id;
        fill_bank      = bc_launch_pending ?
            bc_pending_bank : bc_active_bank;

        pv_start       = pv_launch_fire;
        drain_start    = pv_launch_fire;
        pv_group_id    = pv_launch_pending ?
            pv_pending_group_id : pv_active_group_id;
        drain_group_id = pv_launch_pending ?
            pv_pending_group_id : pv_active_group_id;
        drain_bank     = pv_launch_pending ?
            pv_pending_bank : pv_active_bank;

        release_valid    = pv_active && pv_done;
        release_bank     = pv_active_bank;
        release_group_id = pv_active_group_id;

        start_ready =
            !command_active &&
            !fatal_error &&
            !bc_launch_pending &&
            !bc_active &&
            !pv_launch_pending &&
            !pv_active;

        busy =
            command_active ||
            bc_launch_pending ||
            bc_active ||
            pv_launch_pending ||
            pv_active;

        bc_wait_for_empty_bank =
            command_active &&
            !bc_active &&
            !bc_launch_pending &&
            ($unsigned(next_bc_count) < NUM_GROUPS) &&
            !empty_bank_found;

        pv_wait_for_ready_bank =
            command_active &&
            !pv_active &&
            !pv_launch_pending &&
            ($unsigned(next_pv_count) < NUM_GROUPS) &&
            !ready_bank_found;

        fill_done_matches =
            fill_done &&
            bc_active &&
            (fill_done_bank == bc_active_bank) &&
            (fill_done_group_id == bc_active_group_id);

        internal_fault =
            (fill_done && !fill_done_matches) ||
            (bc_group_done && !bc_active) ||
            (pv_done && !pv_active);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            command_active         <= 1'b0;
            fatal_error            <= 1'b0;
            next_bc_count          <= '0;
            next_pv_count          <= '0;

            bc_launch_pending      <= 1'b0;
            bc_pending_bank        <= 1'b0;
            bc_pending_group_id    <= '0;
            bc_active              <= 1'b0;
            bc_active_bank         <= 1'b0;
            bc_active_group_id     <= '0;
            bc_done_seen           <= 1'b0;
            fill_done_seen         <= 1'b0;

            pv_launch_pending      <= 1'b0;
            pv_pending_bank        <= 1'b0;
            pv_pending_group_id    <= '0;
            pv_active              <= 1'b0;
            pv_active_bank         <= 1'b0;
            pv_active_group_id     <= '0;

            done                   <= 1'b0;
            group_complete         <= 1'b0;
            completed_group_id     <= '0;
            start_while_busy_error <= 1'b0;
            protocol_error         <= 1'b0;
        end else begin
            done           <= 1'b0;
            group_complete <= 1'b0;

            if (start && !start_ready)
                start_while_busy_error <= 1'b1;

            // Any protocol fault makes Bank ownership untrustworthy.
            if ((child_protocol_error || internal_fault) &&
                (command_active || bc_active || pv_active)) begin
                protocol_error    <= 1'b1;
                fatal_error       <= 1'b1;
                command_active    <= 1'b0;
                bc_launch_pending <= 1'b0;
                bc_active         <= 1'b0;
                pv_launch_pending <= 1'b0;
                pv_active         <= 1'b0;
                done              <= 1'b1;
            end else begin
                if (start && start_ready) begin
                    command_active         <= 1'b1;
                    next_bc_count          <= '0;
                    next_pv_count          <= '0;
                    bc_launch_pending      <= 1'b0;
                    bc_active              <= 1'b0;
                    bc_done_seen           <= 1'b0;
                    fill_done_seen         <= 1'b0;
                    pv_launch_pending      <= 1'b0;
                    pv_active              <= 1'b0;
                    start_while_busy_error <= 1'b0;
                    protocol_error         <= 1'b0;
                end

                // Reserve an EMPTY bank. Metadata is held until the atomic
                // B+C/fill launch can be accepted.
                if (command_active &&
                    !bc_active &&
                    !bc_launch_pending &&
                    ($unsigned(next_bc_count) < NUM_GROUPS) &&
                    empty_bank_found) begin
                    bc_launch_pending   <= 1'b1;
                    bc_pending_bank     <= empty_bank_select;
                    bc_pending_group_id <=
                        next_bc_count[GROUP_W-1:0];
                end

                if (bc_launch_fire) begin
                    bc_launch_pending  <= 1'b0;
                    bc_active          <= 1'b1;
                    bc_active_bank     <= bc_pending_bank;
                    bc_active_group_id <= bc_pending_group_id;
                    bc_done_seen       <= 1'b0;
                    fill_done_seen     <= 1'b0;
                    next_bc_count      <= next_bc_count + 1'b1;
                end

                if (bc_active) begin
                    if (bc_group_done)
                        bc_done_seen <= 1'b1;

                    if (fill_done_matches)
                        fill_done_seen <= 1'b1;

                    if ((bc_done_seen || bc_group_done) &&
                        (fill_done_seen || fill_done_matches)) begin
                        bc_active      <= 1'b0;
                        bc_done_seen   <= 1'b0;
                        fill_done_seen <= 1'b0;
                    end
                end

                // Only the READY bank carrying the next ordered Group may be
                // reserved. Metadata is stable until PV/drain both accept.
                if (command_active &&
                    !pv_active &&
                    !pv_launch_pending &&
                    ($unsigned(next_pv_count) < NUM_GROUPS) &&
                    ready_bank_found) begin
                    pv_launch_pending   <= 1'b1;
                    pv_pending_bank     <= ready_bank_select;
                    pv_pending_group_id <=
                        next_pv_count[GROUP_W-1:0];
                end

                if (pv_launch_fire) begin
                    pv_launch_pending  <= 1'b0;
                    pv_active          <= 1'b1;
                    pv_active_bank     <= pv_pending_bank;
                    pv_active_group_id <= pv_pending_group_id;
                end

                if (pv_active && pv_done) begin
                    pv_active          <= 1'b0;
                    group_complete     <= 1'b1;
                    completed_group_id <= pv_active_group_id;
                    next_pv_count      <= next_pv_count + 1'b1;

                    if ($unsigned(next_pv_count) == NUM_GROUPS-1) begin
                        command_active <= 1'b0;
                        done           <= 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(bc_group_start ^ fill_start))
                else $error("gqa_overlap_scheduler: half B+C/fill launch");

            assert (!(pv_start ^ drain_start))
                else $error("gqa_overlap_scheduler: half PV/drain launch");

            assert (!(bc_active && pv_active &&
                      (bc_active_bank == pv_active_bank)))
                else $error("gqa_overlap_scheduler: same Bank read/write");

            assert (!(pv_launch_fire &&
                      (pv_pending_group_id !=
                       next_pv_count[GROUP_W-1:0])))
                else $error("gqa_overlap_scheduler: PV Group out of order");
        end
    end
`endif

    initial begin
        if (NUM_GROUPS < 1)
            $error("gqa_overlap_scheduler: NUM_GROUPS must be >= 1");

        if ((1 << GROUP_W) < NUM_GROUPS)
            $error("gqa_overlap_scheduler: GROUP_W is too small");
    end

endmodule
