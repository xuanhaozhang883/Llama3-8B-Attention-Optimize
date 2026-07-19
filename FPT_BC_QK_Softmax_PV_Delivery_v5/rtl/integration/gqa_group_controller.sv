`timescale 1ns/1ps

// Reference A-side launcher for the completed B+C one-Group pipeline.
// A single system start executes Group 0 through Group NUM_GROUPS-1 in order.
module gqa_group_controller #(
    parameter int NUM_GROUPS = 8,
    parameter int GROUP_W    = (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS)
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 start,
    output logic                 start_ready,
    output logic                 busy,
    output logic                 done,

    output logic                 group_start,
    input  logic                 group_start_ready,
    output logic [GROUP_W-1:0]   group_id,
    input  logic                 group_done,
    input  logic                 group_protocol_error,

    output logic                 group_complete,
    output logic [GROUP_W-1:0]   completed_group_id,
    output logic                 start_while_busy_error,
    output logic                 protocol_error
);
    typedef enum logic [1:0] {S_IDLE, S_LAUNCH, S_WAIT} state_t;
    state_t state;
    logic [GROUP_W-1:0] current_group;

    assign start_ready = (state == S_IDLE);
    assign busy        = (state != S_IDLE);
    assign group_start = (state == S_LAUNCH);
    assign group_id    = current_group;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            current_group          <= '0;
            completed_group_id     <= '0;
            done                   <= 1'b0;
            group_complete         <= 1'b0;
            start_while_busy_error <= 1'b0;
            protocol_error         <= 1'b0;
        end else begin
            done           <= 1'b0;
            group_complete <= 1'b0;

            if (start && !start_ready)
                start_while_busy_error <= 1'b1;

            if (group_protocol_error) begin
                protocol_error <= 1'b1;
                state          <= S_IDLE;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (start) begin
                            current_group          <= '0;
                            start_while_busy_error <= 1'b0;
                            protocol_error         <= 1'b0;
                            state                  <= S_LAUNCH;
                        end
                    end

                    S_LAUNCH: begin
                        if (group_start && group_start_ready)
                            state <= S_WAIT;
                    end

                    S_WAIT: begin
                        if (group_done) begin
                            group_complete     <= 1'b1;
                            completed_group_id <= current_group;
                            if ($unsigned(current_group) == NUM_GROUPS-1) begin
                                done  <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                current_group <= current_group + 1'b1;
                                state         <= S_LAUNCH;
                            end
                        end
                    end

                    default: begin
                        protocol_error <= 1'b1;
                        state          <= S_IDLE;
                    end
                endcase
            end
        end
    end

    initial begin
        if (NUM_GROUPS < 1)
            $error("gqa_group_controller: NUM_GROUPS must be positive");
        if ((1 << GROUP_W) < NUM_GROUPS)
            $error("gqa_group_controller: GROUP_W is too small");
    end
endmodule
