`timescale 1ns/1ps

// ============================================================================
// gqa_overlap_scheduler
// ----------------------------------------------------------------------------
// Two-bank, inter-Group wavefront scheduler.
//
// Steady-state schedule:
//   B+C fills Group N+1 into one bank while real PV drains Group N from the
//   other bank.
//
// A bank progresses through:
//   EMPTY -> FILLING -> READY -> DRAINING -> EMPTY
//
// Important interface semantics:
//   * bc_group_done means the B+C computation for the active Group completed.
//   * fill_complete means the final B+C output beat was accepted by the bank.
//   * A bank becomes READY only after both events have been observed.
//   * pv_done means the final Context output for the active Group was accepted.
//   * bc_group_start and pv_start remain asserted until their ready handshake.
//   * fill_start is a one-cycle pulse on the B+C start handshake.
//
// The scheduler does not alter arithmetic ordering inside a Group.
// ============================================================================
module gqa_overlap_scheduler #(
    parameter int NUM_GROUPS = 8,
    parameter int GROUP_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS),
    parameter int PERF_W = 64
) (
    input  logic clk,
    input  logic rst_n,

    // Command interface.
    input  logic start,
    output logic start_ready,
    output logic busy,
    output logic done,

    // B+C producer launch interface.
    output logic                   bc_group_start,
    input  logic                   bc_group_start_ready,
    output logic [GROUP_W-1:0]     bc_group_id,
    output logic                   bc_write_bank,
    input  logic                   bc_group_done,

    // Ping-pong bank fill interface.
    output logic                   fill_start,
    output logic                   fill_bank,
    output logic [GROUP_W-1:0]     fill_group_id,
    input  logic                   fill_complete,

    // Real-PV consumer launch interface.
    output logic                   pv_start,
    input  logic                   pv_start_ready,
    output logic [GROUP_W-1:0]     pv_group_id,
    output logic                   pv_read_bank,
    output logic                   pv_feed_enable,
    input  logic                   pv_done,

    // Child error input. A child error terminates the current command and
    // requires reset before another command can be accepted.
    input  logic                   child_protocol_error,

    // Completion monitor.
    output logic                   group_complete,
    output logic [GROUP_W-1:0]     completed_group_id,

    // Performance counters, cleared on every accepted command.
    output logic [PERF_W-1:0]      total_cycles,
    output logic [PERF_W-1:0]      bc_active_cycles,
    output logic [PERF_W-1:0]      pv_active_cycles,
    output logic [PERF_W-1:0]      overlap_cycles,
    output logic [PERF_W-1:0]      bc_wait_bank_cycles,
    output logic [PERF_W-1:0]      pv_wait_ready_cycles,

    // Debug/status.
    output logic [1:0]             bank0_state,
    output logic [1:0]             bank1_state,
    output logic [GROUP_W-1:0]     bank0_group_id,
    output logic [GROUP_W-1:0]     bank1_group_id,
    output logic                   bc_active,
    output logic                   pv_active,
    output logic [7:0]             error_bitmap,
    output logic                   protocol_error
);

    localparam logic [1:0] BANK_EMPTY    = 2'd0;
    localparam logic [1:0] BANK_FILLING  = 2'd1;
    localparam logic [1:0] BANK_READY    = 2'd2;
    localparam logic [1:0] BANK_DRAINING = 2'd3;

    localparam int COUNT_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS + 1);

    logic [1:0] bank_state [0:1];
    logic [GROUP_W-1:0] bank_group [0:1];

    logic command_active;
    logic fatal_error;

    logic [COUNT_W-1:0] next_bc_group;
    logic [COUNT_W-1:0] next_pv_group;
    logic [COUNT_W-1:0] completed_groups;

    logic bc_launch_pending;
    logic bc_pending_bank;
    logic [GROUP_W-1:0] bc_pending_group;
    logic bc_running;
    logic bc_running_bank;
    logic bc_done_seen;
    logic fill_done_seen;

    logic pv_launch_pending;
    logic pv_pending_bank;
    logic [GROUP_W-1:0] pv_pending_group;
    logic pv_running;
    logic pv_running_bank;

    logic empty_bank_found;
    logic selected_empty_bank;
    logic ready_bank_found;
    logic selected_ready_bank;

    logic bc_start_fire;
    logic pv_start_fire;

    // Prefer Bank 0 only when both banks are equally eligible. Correctness
    // depends on state and Group ID, not on fixed bank alternation.
    always_comb begin
        empty_bank_found   = 1'b0;
        selected_empty_bank = 1'b0;

        if (bank_state[0] == BANK_EMPTY) begin
            empty_bank_found    = 1'b1;
            selected_empty_bank = 1'b0;
        end else if (bank_state[1] == BANK_EMPTY) begin
            empty_bank_found    = 1'b1;
            selected_empty_bank = 1'b1;
        end

        ready_bank_found    = 1'b0;
        selected_ready_bank = 1'b0;

        if ((bank_state[0] == BANK_READY) &&
            ($unsigned(bank_group[0]) == $unsigned(next_pv_group))) begin
            ready_bank_found    = 1'b1;
            selected_ready_bank = 1'b0;
        end else if ((bank_state[1] == BANK_READY) &&
                     ($unsigned(bank_group[1]) ==
                      $unsigned(next_pv_group))) begin
            ready_bank_found    = 1'b1;
            selected_ready_bank = 1'b1;
        end
    end

    assign start_ready =
        !command_active &&
        !fatal_error &&
        !bc_launch_pending &&
        !bc_running &&
        !pv_launch_pending &&
        !pv_running;

    assign busy =
        command_active ||
        bc_launch_pending ||
        bc_running ||
        pv_launch_pending ||
        pv_running;

    assign bc_group_start = bc_launch_pending;
    assign bc_group_id    = bc_pending_group;
    assign bc_write_bank  = bc_pending_bank;
    assign bc_start_fire  = bc_group_start && bc_group_start_ready;

    // The buffer begins capture on exactly the accepted B+C launch.
    assign fill_start    = bc_start_fire;
    assign fill_bank     = bc_pending_bank;
    assign fill_group_id = bc_pending_group;

    assign pv_start      = pv_launch_pending;
    assign pv_group_id   = pv_pending_group;
    assign pv_read_bank  = pv_pending_bank;
    assign pv_start_fire = pv_start && pv_start_ready;

    // Include the launch handshake cycle so an immediately active PV request
    // cannot observe feed_enable low.
    assign pv_feed_enable = pv_running || pv_start_fire;

    assign bank0_state    = bank_state[0];
    assign bank1_state    = bank_state[1];
    assign bank0_group_id = bank_group[0];
    assign bank1_group_id = bank_group[1];
    assign bc_active      = bc_running;
    assign pv_active      = pv_running;
    assign protocol_error = |error_bitmap;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_state[0]       <= BANK_EMPTY;
            bank_state[1]       <= BANK_EMPTY;
            bank_group[0]       <= '0;
            bank_group[1]       <= '0;

            command_active      <= 1'b0;
            fatal_error         <= 1'b0;
            next_bc_group       <= '0;
            next_pv_group       <= '0;
            completed_groups    <= '0;

            bc_launch_pending   <= 1'b0;
            bc_pending_bank     <= 1'b0;
            bc_pending_group    <= '0;
            bc_running          <= 1'b0;
            bc_running_bank     <= 1'b0;
            bc_done_seen        <= 1'b0;
            fill_done_seen      <= 1'b0;

            pv_launch_pending   <= 1'b0;
            pv_pending_bank     <= 1'b0;
            pv_pending_group    <= '0;
            pv_running          <= 1'b0;
            pv_running_bank     <= 1'b0;

            done                <= 1'b0;
            group_complete      <= 1'b0;
            completed_group_id  <= '0;

            total_cycles        <= '0;
            bc_active_cycles    <= '0;
            pv_active_cycles    <= '0;
            overlap_cycles      <= '0;
            bc_wait_bank_cycles <= '0;
            pv_wait_ready_cycles<= '0;

            error_bitmap        <= '0;
        end else begin
            done           <= 1'b0;
            group_complete <= 1'b0;

            // Performance accounting describes the current registered state.
            if (command_active) begin
                total_cycles <= total_cycles + 1'b1;

                if (bc_running)
                    bc_active_cycles <= bc_active_cycles + 1'b1;

                if (pv_running)
                    pv_active_cycles <= pv_active_cycles + 1'b1;

                if (bc_running && pv_running)
                    overlap_cycles <= overlap_cycles + 1'b1;

                if (!bc_running &&
                    !bc_launch_pending &&
                    ($unsigned(next_bc_group) < NUM_GROUPS) &&
                    !empty_bank_found)
                    bc_wait_bank_cycles <= bc_wait_bank_cycles + 1'b1;

                if (!pv_running &&
                    !pv_launch_pending &&
                    ($unsigned(next_pv_group) < NUM_GROUPS) &&
                    !ready_bank_found)
                    pv_wait_ready_cycles <= pv_wait_ready_cycles + 1'b1;
            end

            // Non-fatal command misuse is recorded without corrupting the
            // command already in flight.
            if (start && !start_ready)
                error_bitmap[0] <= 1'b1;

            // A child error is fatal because the child pipeline may no longer
            // have a trustworthy ready/busy state. Reset is required.
            if (child_protocol_error && command_active) begin
                error_bitmap[1] <= 1'b1;
                fatal_error     <= 1'b1;
                command_active  <= 1'b0;
                bc_launch_pending <= 1'b0;
                bc_running        <= 1'b0;
                pv_launch_pending <= 1'b0;
                pv_running        <= 1'b0;
                bank_state[0]     <= BANK_EMPTY;
                bank_state[1]     <= BANK_EMPTY;
                done              <= 1'b1;
            end else begin
                // Accept a new complete 8-Group command.
                if (start && start_ready) begin
                    command_active       <= 1'b1;
                    next_bc_group        <= '0;
                    next_pv_group        <= '0;
                    completed_groups     <= '0;

                    bank_state[0]        <= BANK_EMPTY;
                    bank_state[1]        <= BANK_EMPTY;
                    bank_group[0]        <= '0;
                    bank_group[1]        <= '0;

                    bc_launch_pending    <= 1'b0;
                    bc_running           <= 1'b0;
                    bc_done_seen         <= 1'b0;
                    fill_done_seen       <= 1'b0;
                    pv_launch_pending    <= 1'b0;
                    pv_running           <= 1'b0;

                    total_cycles         <= '0;
                    bc_active_cycles     <= '0;
                    pv_active_cycles     <= '0;
                    overlap_cycles       <= '0;
                    bc_wait_bank_cycles  <= '0;
                    pv_wait_ready_cycles <= '0;
                    error_bitmap         <= '0;
                end

                // Launch the selected B+C Group and reserve its bank.
                if (bc_start_fire) begin
                    if (bank_state[bc_pending_bank] != BANK_EMPTY)
                        error_bitmap[6] <= 1'b1;

                    bank_state[bc_pending_bank] <= BANK_FILLING;
                    bank_group[bc_pending_bank] <= bc_pending_group;
                    bc_running_bank             <= bc_pending_bank;
                    bc_running                  <= 1'b1;
                    bc_launch_pending           <= 1'b0;
                    bc_done_seen                <= 1'b0;
                    fill_done_seen              <= 1'b0;
                    next_bc_group               <= next_bc_group + 1'b1;
                end

                // B+C and buffer completion may arrive in either order.
                if (bc_group_done) begin
                    if (bc_running)
                        bc_done_seen <= 1'b1;
                    else
                        error_bitmap[2] <= 1'b1;
                end

                if (fill_complete) begin
                    if (bc_running)
                        fill_done_seen <= 1'b1;
                    else
                        error_bitmap[3] <= 1'b1;
                end

                if (bc_running &&
                    (bc_done_seen || bc_group_done) &&
                    (fill_done_seen || fill_complete)) begin
                    if (bank_state[bc_running_bank] != BANK_FILLING)
                        error_bitmap[6] <= 1'b1;

                    bank_state[bc_running_bank] <= BANK_READY;
                    bc_running                 <= 1'b0;
                    bc_done_seen               <= 1'b0;
                    fill_done_seen             <= 1'b0;
                end

                // Launch PV only from the bank containing the next ordered
                // Group. This prevents READY banks from being consumed out of
                // order if completion timing changes.
                if (pv_start_fire) begin
                    if ((bank_state[pv_pending_bank] != BANK_READY) ||
                        (bank_group[pv_pending_bank] != pv_pending_group) ||
                        ($unsigned(pv_pending_group) !=
                         $unsigned(next_pv_group)))
                        error_bitmap[5] <= 1'b1;

                    bank_state[pv_pending_bank] <= BANK_DRAINING;
                    pv_running_bank             <= pv_pending_bank;
                    pv_running                  <= 1'b1;
                    pv_launch_pending           <= 1'b0;
                    next_pv_group               <= next_pv_group + 1'b1;
                end

                // A bank is not reusable until the final Context result for
                // that Group has retired.
                if (pv_done) begin
                    if (!pv_running) begin
                        error_bitmap[4] <= 1'b1;
                    end else begin
                        if (bank_state[pv_running_bank] != BANK_DRAINING)
                            error_bitmap[6] <= 1'b1;

                        bank_state[pv_running_bank] <= BANK_EMPTY;
                        pv_running                 <= 1'b0;
                        group_complete             <= 1'b1;
                        completed_group_id          <=
                            bank_group[pv_running_bank];
                        completed_groups            <=
                            completed_groups + 1'b1;

                        if ($unsigned(completed_groups) ==
                            NUM_GROUPS-1) begin
                            command_active <= 1'b0;
                            done           <= 1'b1;
                        end
                    end
                end

                // Create a pending B+C launch. It remains stable until ready.
                if (command_active &&
                    !bc_running &&
                    !bc_launch_pending &&
                    ($unsigned(next_bc_group) < NUM_GROUPS) &&
                    empty_bank_found) begin
                    bc_launch_pending <= 1'b1;
                    bc_pending_bank   <= selected_empty_bank;
                    bc_pending_group  <=
                        next_bc_group[GROUP_W-1:0];
                end

                // Create a pending ordered PV launch. It remains stable until
                // ready, independently of B+C backpressure.
                if (command_active &&
                    !pv_running &&
                    !pv_launch_pending &&
                    ($unsigned(next_pv_group) < NUM_GROUPS) &&
                    ready_bank_found) begin
                    pv_launch_pending <= 1'b1;
                    pv_pending_bank   <= selected_ready_bank;
                    pv_pending_group  <=
                        next_pv_group[GROUP_W-1:0];
                end

                // Defensive internal invariants.
                if (bc_running && pv_running &&
                    (bc_running_bank == pv_running_bank))
                    error_bitmap[6] <= 1'b1;

                if (($unsigned(next_pv_group) >
                     $unsigned(next_bc_group)) ||
                    ($unsigned(completed_groups) >
                     $unsigned(next_pv_group)))
                    error_bitmap[7] <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // Simulation-time checks intentionally mirror hardware-visible errors.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(bc_running && pv_running &&
                      (bc_running_bank == pv_running_bank)))
                else $error("gqa_overlap_scheduler: same bank read/write");

            assert ($unsigned(next_pv_group) <=
                    $unsigned(next_bc_group))
                else $error("gqa_overlap_scheduler: PV passed B+C");

            assert ($unsigned(completed_groups) <=
                    $unsigned(next_pv_group))
                else $error("gqa_overlap_scheduler: completion overflow");

            assert (!(pv_start_fire &&
                      (bank_group[pv_pending_bank] != pv_pending_group)))
                else $error("gqa_overlap_scheduler: wrong PV Group");
        end
    end
`endif

    initial begin
        if (NUM_GROUPS < 1)
            $error("gqa_overlap_scheduler: NUM_GROUPS must be >= 1");

        if ((1 << GROUP_W) < NUM_GROUPS)
            $error("gqa_overlap_scheduler: GROUP_W is too small");

        if (PERF_W < 1)
            $error("gqa_overlap_scheduler: PERF_W must be >= 1");
    end

endmodule
