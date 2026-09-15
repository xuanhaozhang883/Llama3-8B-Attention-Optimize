`timescale 1ns/1ps

module cats_r4_a4_group_job_adapter #(
    parameter integer CLUSTERS = 2,
    parameter integer CLUSTER_ID = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        counter_clear,

    input  logic        txn_active,
    input  logic [15:0] txn_epoch,
    input  logic [1:0]  txn_numeric_mode,

    input  logic        group_cmd_valid,
    output logic        group_cmd_ready,
    input  logic [15:0] group_cmd_epoch,
    input  logic [2:0]  group_cmd_group,
    input  logic [2:0]  group_cmd_local_index,
    input  logic [1:0]  group_cmd_numeric_mode,
    input  logic        group_cmd_kv_buffer,

    output logic        job_valid,
    input  logic        job_ready,
    output logic [15:0] job_epoch,
    output logic [2:0]  job_group,
    output logic [4:0]  job_global_q_head,
    output logic [2:0]  job_row_window,
    output logic        group_kv_buffer,

    input  logic        retire_valid,
    input  logic        retire_ready,
    input  logic [15:0] retire_epoch,
    input  logic [2:0]  retire_group,
    input  logic [4:0]  retire_head,
    input  logic [2:0]  retire_window,
    input  logic [63:0] context_words,
    input  logic [63:0] final_release_count,
    input  logic [5:0]  slot_owner,
    input  logic        cluster_quiescent,
    input  logic        cluster_error_seen,
    input  logic        group_abort,

    output logic        group_done_valid,
    input  logic        group_done_ready,
    output logic [15:0] group_done_epoch,
    output logic [2:0]  group_done_group,
    output logic [2:0]  group_done_local_index,
    output logic [1:0]  group_done_numeric_mode,
    output logic        group_done_aborted,
    output logic        group_done_error,

    output logic        protocol_error_valid,
    input  logic        protocol_error_ready,
    output logic [3:0]  protocol_error_code,
    output logic [15:0] protocol_error_epoch,
    output logic [2:0]  protocol_error_group,
    output logic [2:0]  protocol_error_local_index,

    output logic        busy,
    output logic [63:0] groups_accepted,
    output logic [63:0] groups_completed,
    output logic [63:0] groups_aborted,
    output logic [63:0] jobs_accepted,
    output logic [63:0] retires_accepted
);
    localparam logic [3:0] ERR_NO_TRANSACTION = 4'd1;
    localparam logic [3:0] ERR_MODE            = 4'd2;
    localparam logic [3:0] ERR_EPOCH           = 4'd3;
    localparam logic [3:0] ERR_OWNER           = 4'd4;
    localparam logic [3:0] ERR_LOCAL_INDEX     = 4'd5;
    localparam logic [3:0] ERR_CONTROL_CHANGED = 4'd6;
    localparam logic [3:0] ERR_RETIRE_TOKEN    = 4'd7;
    localparam logic [3:0] ERR_COUNTER_RANGE   = 4'd8;
    localparam logic [3:0] ERR_COUNTER_CLEAR   = 4'd9;

    typedef enum logic [1:0] {ST_IDLE, ST_ACTIVE, ST_DONE} state_t;
    state_t state;

    logic [15:0] active_epoch;
    logic [2:0] active_group, active_local_index;
    logic [1:0] active_mode;
    logic active_kv_buffer;
    logic [2:0] expected_local_index;
    logic [5:0] job_index, retire_count;
    logic [63:0] context_base, release_base;
    logic faulted, abort_latched;
    logic done_error_r, done_aborted_r;

    logic cmd_legal;
    logic cmd_fire, job_fire, retire_fire, done_fire;
    logic retire_matches;
    logic normal_complete, fault_complete;
    logic violation_valid;
    logic [3:0] violation_code;
    logic [15:0] violation_epoch;
    logic [2:0] violation_group, violation_local_index;

    wire [63:0] context_delta = context_words - context_base;
    wire [63:0] release_delta = final_release_count - release_base;

    assign busy = state != ST_IDLE;
    assign group_cmd_ready = state == ST_IDLE && !protocol_error_valid;
    assign cmd_fire = group_cmd_valid && group_cmd_ready;
    assign cmd_legal = txn_active &&
                       group_cmd_numeric_mode < 2 &&
                       group_cmd_numeric_mode == txn_numeric_mode &&
                       group_cmd_epoch == txn_epoch &&
                       (group_cmd_group % CLUSTERS) == CLUSTER_ID &&
                       group_cmd_local_index == (group_cmd_group / CLUSTERS) &&
                       group_cmd_local_index == expected_local_index;

    assign job_valid = state == ST_ACTIVE && !faulted && !abort_latched &&
                       job_index < 32;
    assign job_epoch = active_epoch;
    assign job_group = active_group;
    assign job_global_q_head = {active_group, 2'b00} + (job_index >> 3);
    assign job_row_window = job_index[2:0];
    assign group_kv_buffer = active_kv_buffer;
    assign job_fire = job_valid && job_ready;

    assign retire_fire = retire_valid && retire_ready;
    assign retire_matches = retire_epoch == active_epoch &&
                            retire_group == active_group &&
                            retire_head == ({active_group, 2'b00} +
                                            (retire_count >> 3)) &&
                            retire_window == retire_count[2:0] &&
                            retire_count < 32;

    assign normal_complete = state == ST_ACTIVE && !faulted &&
                             !abort_latched && job_index == 32 &&
                             retire_count == 32 &&
                             context_delta == 64'd65536 &&
                             release_delta == 64'd512 &&
                             slot_owner == 0 && cluster_quiescent;
    assign fault_complete = state == ST_ACTIVE &&
                            (faulted || abort_latched) && cluster_quiescent;

    assign group_done_valid = state == ST_DONE;
    assign group_done_epoch = active_epoch;
    assign group_done_group = active_group;
    assign group_done_local_index = active_local_index;
    assign group_done_numeric_mode = active_mode;
    assign group_done_aborted = done_aborted_r;
    assign group_done_error = done_error_r;
    assign done_fire = group_done_valid && group_done_ready;

    always_comb begin
        violation_valid = 1'b0;
        violation_code = 0;
        violation_epoch = state == ST_ACTIVE ? active_epoch : group_cmd_epoch;
        violation_group = state == ST_ACTIVE ? active_group : group_cmd_group;
        violation_local_index = state == ST_ACTIVE ? active_local_index :
                                                     group_cmd_local_index;
        if (cmd_fire && !cmd_legal) begin
            violation_valid = 1'b1;
            if (!txn_active)
                violation_code = ERR_NO_TRANSACTION;
            else if (group_cmd_numeric_mode >= 2 ||
                     group_cmd_numeric_mode != txn_numeric_mode)
                violation_code = ERR_MODE;
            else if (group_cmd_epoch != txn_epoch)
                violation_code = ERR_EPOCH;
            else if ((group_cmd_group % CLUSTERS) != CLUSTER_ID)
                violation_code = ERR_OWNER;
            else
                violation_code = ERR_LOCAL_INDEX;
        end else if (state == ST_ACTIVE && !faulted &&
                     (!txn_active || txn_epoch != active_epoch ||
                      txn_numeric_mode != active_mode)) begin
            violation_valid = 1'b1;
            violation_code = ERR_CONTROL_CHANGED;
        end else if (state == ST_ACTIVE && !faulted &&
                     retire_fire && !retire_matches) begin
            violation_valid = 1'b1;
            violation_code = ERR_RETIRE_TOKEN;
        end else if (state == ST_ACTIVE && !faulted &&
                     (context_delta > 64'd65536 || release_delta > 64'd512)) begin
            violation_valid = 1'b1;
            violation_code = ERR_COUNTER_RANGE;
        end else if (counter_clear && state != ST_IDLE) begin
            violation_valid = 1'b1;
            violation_code = ERR_COUNTER_CLEAR;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            active_epoch <= 0;
            active_group <= 0;
            active_local_index <= 0;
            active_mode <= 0;
            active_kv_buffer <= 0;
            expected_local_index <= 0;
            job_index <= 0;
            retire_count <= 0;
            context_base <= 0;
            release_base <= 0;
            faulted <= 0;
            abort_latched <= 0;
            done_error_r <= 0;
            done_aborted_r <= 0;
            protocol_error_valid <= 0;
            protocol_error_code <= 0;
            protocol_error_epoch <= 0;
            protocol_error_group <= 0;
            protocol_error_local_index <= 0;
        end else if (clear) begin
            state <= ST_IDLE;
            expected_local_index <= 0;
            job_index <= 0;
            retire_count <= 0;
            faulted <= 0;
            abort_latched <= 0;
            done_error_r <= 0;
            done_aborted_r <= 0;
            protocol_error_valid <= 0;
        end else begin
            if (protocol_error_valid && protocol_error_ready)
                protocol_error_valid <= 1'b0;
            if (violation_valid) begin
                if (!protocol_error_valid || protocol_error_ready) begin
                    protocol_error_valid <= 1'b1;
                    protocol_error_code <= violation_code;
                    protocol_error_epoch <= violation_epoch;
                    protocol_error_group <= violation_group;
                    protocol_error_local_index <= violation_local_index;
                end
                if (state == ST_ACTIVE)
                    faulted <= 1'b1;
            end

            if (cmd_fire && cmd_legal) begin
                state <= ST_ACTIVE;
                active_epoch <= group_cmd_epoch;
                active_group <= group_cmd_group;
                active_local_index <= group_cmd_local_index;
                active_mode <= group_cmd_numeric_mode;
                active_kv_buffer <= group_cmd_kv_buffer;
                job_index <= 0;
                retire_count <= 0;
                context_base <= context_words;
                release_base <= final_release_count;
                faulted <= 0;
                abort_latched <= 0;
                done_error_r <= 0;
                done_aborted_r <= 0;
            end
            if (job_fire)
                job_index <= job_index + 1'b1;
            if (retire_fire && retire_matches)
                retire_count <= retire_count + 1'b1;
            if (state == ST_ACTIVE && cluster_error_seen)
                faulted <= 1'b1;
            if (state == ST_ACTIVE && group_abort)
                abort_latched <= 1'b1;

            if (normal_complete) begin
                state <= ST_DONE;
                done_error_r <= 1'b0;
                done_aborted_r <= 1'b0;
            end else if (fault_complete) begin
                state <= ST_DONE;
                done_error_r <= faulted;
                done_aborted_r <= abort_latched;
            end

            if (done_fire) begin
                state <= ST_IDLE;
                if (!done_error_r && !done_aborted_r)
                    expected_local_index <= expected_local_index + 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            groups_accepted <= 0;
            groups_completed <= 0;
            groups_aborted <= 0;
            jobs_accepted <= 0;
            retires_accepted <= 0;
        end else if (counter_clear && state == ST_IDLE) begin
            groups_accepted <= 0;
            groups_completed <= 0;
            groups_aborted <= 0;
            jobs_accepted <= 0;
            retires_accepted <= 0;
        end else if (!clear) begin
            if (cmd_fire && cmd_legal)
                groups_accepted <= groups_accepted + 1'b1;
            if (job_fire)
                jobs_accepted <= jobs_accepted + 1'b1;
            if (retire_fire && retire_matches)
                retires_accepted <= retires_accepted + 1'b1;
            if (done_fire && !done_error_r && !done_aborted_r)
                groups_completed <= groups_completed + 1'b1;
            if (done_fire && (done_error_r || done_aborted_r))
                groups_aborted <= groups_aborted + 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (!(CLUSTERS == 1 || CLUSTERS == 2 || CLUSTERS == 4))
            $fatal(1, "CLUSTERS must be 1, 2, or 4");
        if (CLUSTER_ID < 0 || CLUSTER_ID >= CLUSTERS)
            $fatal(1, "CLUSTER_ID out of range");
    end
`endif
endmodule
