`timescale 1ns/1ps

// Cross-GQA-group Ping-Pong scheduler.
//
// The B+C path and the real PV engine are launched independently.  While one
// complete Group bank is DRAINING into real PV, the other bank may be FILLING
// from the next B+C Group.  Group order is still strictly preserved.
module attention_group_pingpong_controller #(
    parameter int NUM_GROUPS = 8,
    parameter int GROUP_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic start_ready,
    output logic busy,
    output logic done,

    output logic buffer_start,

    output logic fill_start_valid,
    input  logic fill_start_ready,
    output logic [GROUP_W-1:0] fill_start_group_id,

    output logic bc_group_start,
    input  logic bc_group_start_ready,
    output logic [GROUP_W-1:0] bc_group_id,
    input  logic bc_group_done,
    input  logic bc_busy,

    input  logic capture_done,

    input  logic drain_valid,
    output logic drain_ready,
    input  logic [GROUP_W-1:0] drain_group_id,

    output logic pv_start,
    output logic pv_feed_enable,
    output logic [GROUP_W-1:0] pv_group_id,
    input  logic pv_done,
    input  logic pv_busy,

    output logic drain_release,

    input  logic child_protocol_error,

    output logic group_complete,
    output logic [GROUP_W-1:0] completed_group_id,
    output logic [GROUP_W-1:0] active_group_id,
    output logic start_while_busy_error,
    output logic protocol_error
);

    localparam int COUNT_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS + 1);

    logic run_active;
    logic bc_inflight;
    logic pv_inflight;
    logic capture_seen;
    logic [COUNT_W-1:0] bc_launched;
    logic [COUNT_W-1:0] pv_completed;
    logic [GROUP_W-1:0] next_bc_group;
    logic [GROUP_W-1:0] next_pv_group;
    logic [GROUP_W-1:0] bc_group_reg;
    logic [GROUP_W-1:0] pv_group_reg;

    logic bc_launch_fire;
    logic pv_launch_fire;

    assign start_ready = !run_active;
    assign busy        = run_active;

    assign bc_launch_fire =
        run_active &&
        !buffer_start &&
        !bc_inflight &&
        ($unsigned(bc_launched) < NUM_GROUPS) &&
        fill_start_ready &&
        bc_group_start_ready;

    assign fill_start_valid    = bc_launch_fire;
    assign fill_start_group_id = next_bc_group;
    assign bc_group_start      = bc_launch_fire;
    assign bc_group_id         = next_bc_group;

    assign drain_ready =
        run_active &&
        !pv_inflight &&
        !pv_busy;

    assign pv_launch_fire = drain_valid && drain_ready;
    assign pv_start       = pv_launch_fire;
    assign pv_feed_enable = pv_inflight || pv_launch_fire;
    assign pv_group_id    = pv_launch_fire ? drain_group_id : pv_group_reg;

    assign drain_release =
        run_active && pv_inflight && pv_done;

    // Debug/status preserves the old single active_group_id port.  Once PV is
    // active it reports the Group whose Context stream is being produced;
    // before the first PV launch it reports the B+C Group being prepared.
    assign active_group_id =
        pv_inflight ? pv_group_reg :
        bc_inflight ? bc_group_reg :
        next_bc_group;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run_active             <= 1'b0;
            done                   <= 1'b0;
            buffer_start           <= 1'b0;
            bc_inflight            <= 1'b0;
            pv_inflight            <= 1'b0;
            capture_seen           <= 1'b0;
            bc_launched            <= '0;
            pv_completed           <= '0;
            next_bc_group          <= '0;
            next_pv_group          <= '0;
            bc_group_reg           <= '0;
            pv_group_reg           <= '0;
            group_complete         <= 1'b0;
            completed_group_id     <= '0;
            start_while_busy_error <= 1'b0;
            protocol_error         <= 1'b0;
        end else begin
            done           <= 1'b0;
            buffer_start   <= 1'b0;
            group_complete <= 1'b0;

            if (start && start_ready) begin
                run_active             <= 1'b1;
                buffer_start           <= 1'b1;
                bc_inflight            <= 1'b0;
                pv_inflight            <= 1'b0;
                capture_seen           <= 1'b0;
                bc_launched            <= '0;
                pv_completed           <= '0;
                next_bc_group          <= '0;
                next_pv_group          <= '0;
                bc_group_reg           <= '0;
                pv_group_reg           <= '0;
                completed_group_id     <= '0;
                start_while_busy_error <= 1'b0;
                protocol_error         <= 1'b0;
            end else if (start && !start_ready) begin
                start_while_busy_error <= 1'b1;
                protocol_error         <= 1'b1;
            end

            if (run_active) begin
                if (bc_launch_fire) begin
                    bc_inflight   <= 1'b1;
                    capture_seen  <= 1'b0;
                    bc_group_reg  <= next_bc_group;
                    bc_launched   <= bc_launched + 1'b1;

                    if ($unsigned(next_bc_group) < NUM_GROUPS-1)
                        next_bc_group <= next_bc_group + 1'b1;
                end

                if (capture_done) begin
                    if (!bc_inflight)
                        protocol_error <= 1'b1;
                    capture_seen <= 1'b1;
                end

                if (bc_group_done) begin
                    if (!bc_inflight) begin
                        protocol_error <= 1'b1;
                    end else if (!capture_seen && !capture_done) begin
                        // B+C must not retire before its final vector has
                        // completed the Group-bank capture.
                        protocol_error <= 1'b1;
                    end
                    bc_inflight <= 1'b0;
                end

                if (pv_launch_fire) begin
                    if (drain_group_id != next_pv_group)
                        protocol_error <= 1'b1;
                    pv_group_reg <= drain_group_id;
                    pv_inflight  <= 1'b1;
                end

                if (pv_done) begin
                    if (!pv_inflight) begin
                        protocol_error <= 1'b1;
                    end else begin
                        pv_inflight        <= 1'b0;
                        pv_completed       <= pv_completed + 1'b1;
                        group_complete     <= 1'b1;
                        completed_group_id <= pv_group_reg;

                        if ($unsigned(next_pv_group) < NUM_GROUPS-1)
                            next_pv_group <= next_pv_group + 1'b1;

                        if ($unsigned(pv_completed) == NUM_GROUPS-1) begin
                            run_active <= 1'b0;
                            done       <= 1'b1;
                        end
                    end
                end

                if (child_protocol_error) begin
                    protocol_error <= 1'b1;
                    run_active     <= 1'b0;
                    done           <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (NUM_GROUPS < 1)
            $error(
                "attention_group_pingpong_controller: NUM_GROUPS must be >= 1"
            );
        if ((1 << GROUP_W) < NUM_GROUPS)
            $error(
                "attention_group_pingpong_controller: GROUP_W is too small"
            );
    end

    wire unused_bc_busy = bc_busy;

endmodule
