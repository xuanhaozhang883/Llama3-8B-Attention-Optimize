`timescale 1ns/1ps

module cats_r4_qk_q_slab_client (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,

    input  logic          job_valid,
    output logic          job_ready,
    input  logic [15:0]   job_epoch,
    input  logic [2:0]    job_group,
    input  logic [4:0]    job_global_q_head,
    input  logic [2:0]    job_row_window,

    output logic          q_slab_need_valid,
    input  logic          q_slab_need_ready,
    output logic [15:0]   q_slab_need_epoch,
    output logic [2:0]    q_slab_need_group,
    output logic [4:0]    q_slab_need_global_q_head,
    output logic [2:0]    q_slab_need_row_window,

    input  logic          q_slab_ready_valid,
    output logic          q_slab_ready_ready,
    input  logic [15:0]   q_slab_ready_epoch,
    input  logic [2:0]    q_slab_ready_group,
    input  logic [4:0]    q_slab_ready_global_q_head,
    input  logic [2:0]    q_slab_ready_row_window,
    input  logic          q_slab_ready_buffer,

    output logic          engine_start_valid,
    input  logic          engine_start_ready,
    output logic [15:0]   engine_start_epoch,
    output logic [2:0]    engine_start_group,
    output logic [4:0]    engine_start_global_q_head,
    output logic [2:0]    engine_start_row_window,
    output logic [1:0]    engine_start_key_block,
    output logic          engine_start_q_buffer,

    input  logic          engine_done_valid,
    output logic          engine_done_ready,
    input  logic [15:0]   engine_done_epoch,
    input  logic [2:0]    engine_done_group,
    input  logic [4:0]    engine_done_global_q_head,
    input  logic [2:0]    engine_done_row_window,
    input  logic [1:0]    engine_done_key_block,
    input  logic          engine_done_error,

    output logic          q_slab_retire_valid,
    input  logic          q_slab_retire_ready,
    output logic [15:0]   q_slab_retire_epoch,
    output logic [2:0]    q_slab_retire_group,
    output logic [4:0]    q_slab_retire_global_q_head,
    output logic [2:0]    q_slab_retire_row_window,
    output logic          q_slab_retire_buffer,

    output logic [63:0]   jobs_accepted,
    output logic [63:0]   q_slab_needs_transferred,
    output logic [63:0]   q_slab_ready_transferred,
    output logic [63:0]   engine_jobs_started,
    output logic [63:0]   engine_jobs_completed,
    output logic [63:0]   q_slab_retires_transferred,
    output logic [63:0]   protocol_errors,
    output logic [63:0]   epoch_drops,
    output logic          protocol_error_sticky
);
    typedef enum logic [2:0] {
        ST_IDLE       = 3'd0,
        ST_NEED       = 3'd1,
        ST_WAIT_READY = 3'd2,
        ST_START      = 3'd3,
        ST_WAIT_DONE  = 3'd4,
        ST_RETIRE     = 3'd5
    } state_t;

    state_t state;
    logic [15:0] token_epoch;
    logic [2:0] token_group;
    logic [4:0] token_head;
    logic [2:0] token_window;
    logic token_buffer;
    logic [1:0] key_block;
    logic ready_token_match;
    logic done_token_match;

    assign job_ready = state == ST_IDLE &&
                       job_global_q_head[4:2] == job_group;
    assign q_slab_need_valid = state == ST_NEED;
    assign q_slab_ready_ready = state == ST_WAIT_READY;
    assign engine_start_valid = state == ST_START;
    assign engine_done_ready = state == ST_WAIT_DONE;
    assign q_slab_retire_valid = state == ST_RETIRE;

    assign q_slab_need_epoch = token_epoch;
    assign q_slab_need_group = token_group;
    assign q_slab_need_global_q_head = token_head;
    assign q_slab_need_row_window = token_window;

    assign engine_start_epoch = token_epoch;
    assign engine_start_group = token_group;
    assign engine_start_global_q_head = token_head;
    assign engine_start_row_window = token_window;
    assign engine_start_key_block = key_block;
    assign engine_start_q_buffer = token_buffer;

    assign q_slab_retire_epoch = token_epoch;
    assign q_slab_retire_group = token_group;
    assign q_slab_retire_global_q_head = token_head;
    assign q_slab_retire_row_window = token_window;
    assign q_slab_retire_buffer = token_buffer;
    assign ready_token_match =
        q_slab_ready_epoch == token_epoch &&
        q_slab_ready_group == token_group &&
        q_slab_ready_global_q_head == token_head &&
        q_slab_ready_row_window == token_window;
    assign done_token_match =
        engine_done_epoch == token_epoch &&
        engine_done_group == token_group &&
        engine_done_global_q_head == token_head &&
        engine_done_row_window == token_window &&
        engine_done_key_block == key_block &&
        !engine_done_error;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            token_epoch <= '0;
            token_group <= '0;
            token_head <= '0;
            token_window <= '0;
            token_buffer <= 1'b0;
            key_block <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (job_valid && job_ready) begin
                        token_epoch <= job_epoch;
                        token_group <= job_group;
                        token_head <= job_global_q_head;
                        token_window <= job_row_window;
                        key_block <= 0;
                        state <= ST_NEED;
                    end
                end
                ST_NEED: begin
                    if (q_slab_need_valid && q_slab_need_ready)
                        state <= ST_WAIT_READY;
                end
                ST_WAIT_READY: begin
                    if (q_slab_ready_valid && q_slab_ready_ready) begin
                        if (ready_token_match) begin
                            token_buffer <= q_slab_ready_buffer;
                            state <= ST_START;
                        end
                    end
                end
                ST_START: begin
                    if (engine_start_valid && engine_start_ready)
                        state <= ST_WAIT_DONE;
                end
                ST_WAIT_DONE: begin
                    if (engine_done_valid && engine_done_ready) begin
                        if (done_token_match) begin
                            if (key_block == 2'd3) begin
                                state <= ST_RETIRE;
                            end else begin
                                key_block <= key_block + 1'b1;
                                state <= ST_START;
                            end
                        end
                    end
                end
                ST_RETIRE: begin
                    if (q_slab_retire_valid && q_slab_retire_ready)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || counter_clear) begin
            jobs_accepted <= 0;
            q_slab_needs_transferred <= 0;
            q_slab_ready_transferred <= 0;
            engine_jobs_started <= 0;
            engine_jobs_completed <= 0;
            q_slab_retires_transferred <= 0;
            protocol_errors <= 0;
            epoch_drops <= 0;
            protocol_error_sticky <= 0;
        end else if (!clear) begin
            if (job_valid && job_ready)
                jobs_accepted <= jobs_accepted + 1'b1;
            if (q_slab_need_valid && q_slab_need_ready)
                q_slab_needs_transferred <= q_slab_needs_transferred + 1'b1;
            if (q_slab_ready_valid && q_slab_ready_ready && ready_token_match)
                q_slab_ready_transferred <= q_slab_ready_transferred + 1'b1;
            if (q_slab_ready_valid && q_slab_ready_ready &&
                !ready_token_match) begin
                protocol_errors <= protocol_errors + 1'b1;
                protocol_error_sticky <= 1'b1;
                if (q_slab_ready_epoch != token_epoch)
                    epoch_drops <= epoch_drops + 1'b1;
            end
            if (engine_start_valid && engine_start_ready)
                engine_jobs_started <= engine_jobs_started + 1'b1;
            if (engine_done_valid && engine_done_ready && done_token_match)
                engine_jobs_completed <= engine_jobs_completed + 1'b1;
            if (engine_done_valid && engine_done_ready &&
                !done_token_match) begin
                protocol_errors <= protocol_errors + 1'b1;
                protocol_error_sticky <= 1'b1;
                if (engine_done_epoch != token_epoch)
                    epoch_drops <= epoch_drops + 1'b1;
            end
            if (q_slab_retire_valid && q_slab_retire_ready)
                q_slab_retires_transferred <= q_slab_retires_transferred + 1'b1;
        end
    end

endmodule
