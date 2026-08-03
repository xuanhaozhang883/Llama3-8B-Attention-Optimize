`timescale 1ns/1ps

// Correctness-first 8-Group controller.
//
// Per Group:
//   1) launch the verified B+C one-Group pipeline (PV_TILE=2);
//   2) capture/repack its complete TILE2 stream;
//   3) launch the real TILE4 PV engine;
//   4) wait until the final Context result is retired;
//   5) advance to the next Group.
module attention_group_pv_controller #(
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

    output logic [GROUP_W-1:0] active_group_id,

    output logic bc_group_start,
    input  logic bc_group_start_ready,
    input  logic bc_group_done,

    output logic capture_start,
    input  logic capture_complete,

    output logic pv_start,
    output logic pv_feed_enable,
    input  logic pv_done,

    input  logic child_protocol_error,

    output logic group_complete,
    output logic [GROUP_W-1:0] completed_group_id,
    output logic start_while_busy_error,
    output logic protocol_error
);

    typedef enum logic [2:0] {
        S_IDLE          = 3'd0,
        S_LAUNCH_BC     = 3'd1,
        S_WAIT_CAPTURE  = 3'd2,
        S_LAUNCH_PV     = 3'd3,
        S_WAIT_PV       = 3'd4,
        S_ERROR_END     = 3'd5
    } state_t;

    state_t state;
    logic bc_done_seen;

    assign start_ready    = (state == S_IDLE);
    assign busy           = (state != S_IDLE);
    assign bc_group_start = (state == S_LAUNCH_BC);
    assign capture_start  =
        (state == S_LAUNCH_BC) && bc_group_start_ready;
    assign pv_start       = (state == S_LAUNCH_PV);
    assign pv_feed_enable =
        (state == S_LAUNCH_PV) || (state == S_WAIT_PV);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            active_group_id        <= '0;
            bc_done_seen           <= 1'b0;
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

            if (child_protocol_error) begin
                protocol_error <= 1'b1;
                state          <= S_ERROR_END;
            end else begin
                case (state)
                    S_IDLE: begin
                        bc_done_seen <= 1'b0;

                        if (start) begin
                            active_group_id        <= '0;
                            start_while_busy_error <= 1'b0;
                            protocol_error         <= 1'b0;
                            state                  <= S_LAUNCH_BC;
                        end
                    end

                    S_LAUNCH_BC: begin
                        if (bc_group_start_ready) begin
                            bc_done_seen <= 1'b0;
                            state        <= S_WAIT_CAPTURE;
                        end
                    end

                    S_WAIT_CAPTURE: begin
                        if (bc_group_done)
                            bc_done_seen <= 1'b1;

                        if ((bc_done_seen || bc_group_done) &&
                            capture_complete) begin
                            state <= S_LAUNCH_PV;
                        end
                    end

                    S_LAUNCH_PV: begin
                        // pv_start is high for this complete cycle.
                        state <= S_WAIT_PV;
                    end

                    S_WAIT_PV: begin
                        if (pv_done) begin
                            group_complete     <= 1'b1;
                            completed_group_id <= active_group_id;

                            if ($unsigned(active_group_id) ==
                                NUM_GROUPS-1) begin
                                done  <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                active_group_id <= active_group_id + 1'b1;
                                bc_done_seen    <= 1'b0;
                                state           <= S_LAUNCH_BC;
                            end
                        end
                    end

                    S_ERROR_END: begin
                        // End a failed command cleanly instead of hanging.
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end

                    default: begin
                        protocol_error <= 1'b1;
                        state          <= S_ERROR_END;
                    end
                endcase
            end
        end
    end

    initial begin
        if (NUM_GROUPS < 1)
            $error("attention_group_pv_controller: NUM_GROUPS must be >= 1");

        if ((1 << GROUP_W) < NUM_GROUPS)
            $error("attention_group_pv_controller: GROUP_W is too small");
    end

endmodule
