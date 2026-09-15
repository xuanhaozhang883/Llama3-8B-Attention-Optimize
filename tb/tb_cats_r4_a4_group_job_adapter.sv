`timescale 1ns/1ps

module tb_cats_r4_a4_group_job_adapter #(
    parameter integer CLUSTERS = 2,
    parameter integer CLUSTER_ID = 0
);
    localparam logic [15:0] EPOCH = 16'h4401;
    localparam integer FIRST_GROUP = CLUSTER_ID;
    localparam integer SECOND_GROUP = CLUSTER_ID + CLUSTERS;
    logic clk = 0; always #1 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic txn_active = 0; logic [15:0] txn_epoch = EPOCH;
    logic [1:0] txn_numeric_mode = 1;
    logic group_cmd_valid = 0, group_cmd_ready;
    logic [15:0] group_cmd_epoch = EPOCH;
    logic [2:0] group_cmd_group = 0, group_cmd_local_index = 0;
    logic [1:0] group_cmd_numeric_mode = 1; logic group_cmd_kv_buffer = 0;
    logic job_valid, job_ready = 0; logic [15:0] job_epoch;
    logic [2:0] job_group; logic [4:0] job_global_q_head;
    logic [2:0] job_row_window; logic group_kv_buffer;
    logic retire_valid = 0, retire_ready = 1; logic [15:0] retire_epoch = EPOCH;
    logic [2:0] retire_group = 0; logic [4:0] retire_head = 0;
    logic [2:0] retire_window = 0;
    logic [63:0] context_words = 0, final_release_count = 0;
    logic [5:0] slot_owner = 0; logic cluster_quiescent = 0;
    logic cluster_error_seen = 0, group_abort = 0;
    logic group_done_valid, group_done_ready = 0;
    logic [15:0] group_done_epoch; logic [2:0] group_done_group;
    logic [2:0] group_done_local_index; logic [1:0] group_done_numeric_mode;
    logic group_done_aborted, group_done_error;
    logic protocol_error_valid, protocol_error_ready = 0;
    logic [3:0] protocol_error_code; logic [15:0] protocol_error_epoch;
    logic [2:0] protocol_error_group, protocol_error_local_index;
    logic busy;
    logic [63:0] groups_accepted, groups_completed, groups_aborted;
    logic [63:0] jobs_accepted, retires_accepted;

    cats_r4_a4_group_job_adapter #(.CLUSTERS(CLUSTERS), .CLUSTER_ID(CLUSTER_ID)) dut (.*);

    task automatic send_command(
        input logic [2:0] group_id,
        input logic [2:0] local_index,
        input logic [1:0] mode
    );
        begin
            @(negedge clk);
            group_cmd_group = group_id;
            group_cmd_local_index = local_index;
            group_cmd_numeric_mode = mode;
            group_cmd_valid = 1;
            do @(posedge clk); while (!group_cmd_ready);
            @(negedge clk); group_cmd_valid = 0;
        end
    endtask

    task automatic accept_error(input logic [3:0] expected_code);
        logic [37:0] held;
        begin
            while (!protocol_error_valid) @(posedge clk);
            if (protocol_error_code !== expected_code) $fatal(1, "error code %0d expected %0d", protocol_error_code, expected_code);
            held = {protocol_error_code,protocol_error_epoch,protocol_error_group,protocol_error_local_index,12'b0};
            repeat (3) begin
                @(posedge clk);
                if (!protocol_error_valid || {protocol_error_code,protocol_error_epoch,protocol_error_group,protocol_error_local_index,12'b0} !== held)
                    $fatal(1, "protocol error changed while stalled");
            end
            @(negedge clk); protocol_error_ready = 1;
            @(posedge clk); @(negedge clk); protocol_error_ready = 0;
        end
    endtask

    task automatic drive_all_jobs(input logic [2:0] group_id);
        integer count;
        logic [26:0] held;
        begin
            count = 0;
            while (count < 32) begin
                @(negedge clk);
                job_ready = (count != 0);
                if (job_valid && !job_ready) begin
                    held = {job_epoch,job_group,job_global_q_head,job_row_window};
                    @(posedge clk); @(negedge clk);
                    if (!job_valid || {job_epoch,job_group,job_global_q_head,job_row_window} !== held)
                        $fatal(1, "job payload changed while stalled");
                    job_ready = 1;
                end
                @(posedge clk);
                if (job_valid && job_ready) begin
                    if (job_epoch !== EPOCH || job_group !== group_id ||
                        job_global_q_head !== (group_id * 4 + count / 8) ||
                        job_row_window !== count % 8)
                        $fatal(1, "job mapping mismatch count=%0d head=%0d window=%0d", count, job_global_q_head, job_row_window);
                    count = count + 1;
                end
            end
            @(negedge clk); job_ready = 0;
        end
    endtask

    task automatic drive_all_retires(input logic [2:0] group_id);
        integer count;
        logic [63:0] retire_base;
        begin
            for (count = 0; count < 32; count = count + 1) begin
                @(negedge clk);
                retire_epoch = EPOCH;
                retire_group = group_id;
                retire_head = group_id * 4 + count / 8;
                retire_window = count % 8;
                retire_valid = 1;
                if (count == 0) begin
                    retire_base = retires_accepted;
                    retire_ready = 0;
                    @(posedge clk);
                    if (retires_accepted !== retire_base)
                        $fatal(1, "retire counted without ready");
                    @(negedge clk); retire_ready = 1;
                end
                @(posedge clk);
                if (!retire_ready) $fatal(1, "retire unexpectedly blocked");
                @(negedge clk); retire_valid = 0;
            end
        end
    endtask

    task automatic accept_done(
        input logic [2:0] expected_group,
        input logic expected_aborted,
        input logic expected_error
    );
        logic [25:0] held;
        begin
            while (!group_done_valid) @(posedge clk);
            if (group_done_group !== expected_group ||
                group_done_aborted !== expected_aborted ||
                group_done_error !== expected_error)
                $fatal(1, "done payload mismatch group=%0d abort=%b error=%b", group_done_group, group_done_aborted, group_done_error);
            held = {group_done_epoch,group_done_group,group_done_local_index,
                    group_done_numeric_mode,group_done_aborted,group_done_error};
            repeat (3) begin
                @(posedge clk);
                if (!group_done_valid || {group_done_epoch,group_done_group,
                    group_done_local_index,group_done_numeric_mode,
                    group_done_aborted,group_done_error} !== held)
                    $fatal(1, "group done changed while stalled");
            end
            @(negedge clk); group_done_ready = 1;
            @(posedge clk); @(negedge clk); group_done_ready = 0;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1; txn_active = 1;

        // An invalid owner (or invalid local index for N=1) is reported.
        if (CLUSTERS == 1) begin
            send_command(0, 1, 1);
            accept_error(5);
        end else begin
            send_command((CLUSTER_ID + 1) % CLUSTERS, 0, 1);
            accept_error(4);
        end
        if (busy) $fatal(1, "invalid command made adapter busy");

        // First local group: exact 32-job mapping and exact drain conditions.
        send_command(FIRST_GROUP, 0, 1);
        if (!busy || group_kv_buffer !== 0) $fatal(1, "valid command not latched");
        @(negedge clk);
        group_cmd_valid = 1;
        repeat (3) begin
            @(posedge clk);
            if (group_cmd_ready) $fatal(1, "duplicate command accepted while busy");
        end
        @(negedge clk); group_cmd_valid = 0;
        drive_all_jobs(FIRST_GROUP);
        drive_all_retires(FIRST_GROUP);
        @(negedge clk);
        context_words = 65536;
        slot_owner = 0;
        cluster_quiescent = 1;
        repeat (3) begin
            @(posedge clk);
            if (group_done_valid) $fatal(1, "done preceded final releases");
        end
        @(negedge clk); final_release_count = 512;
        accept_done(FIRST_GROUP, 0, 0);

        // The second static group is next. A mode change while busy is illegal.
        cluster_quiescent = 0;
        group_cmd_kv_buffer = 1;
        send_command(SECOND_GROUP, 1, 1);
        if (group_kv_buffer !== 1) $fatal(1, "K/V selector was not latched");
        @(negedge clk); txn_numeric_mode = 0;
        accept_error(6);
        repeat (3) begin
            @(posedge clk);
            if (protocol_error_valid) $fatal(1, "control violation was reported more than once");
        end
        @(negedge clk); cluster_quiescent = 1;
        accept_done(SECOND_GROUP, 0, 1);

        // Coordinated clear resets the local-group sequence; abort is terminal.
        @(negedge clk); clear = 1;
        @(posedge clk); @(negedge clk); clear = 0;
        txn_numeric_mode = 1;
        context_words = 70000;
        final_release_count = 600;
        cluster_quiescent = 0;
        group_cmd_kv_buffer = 0;
        send_command(FIRST_GROUP, 0, 1);
        @(negedge clk); group_abort = 1;
        @(posedge clk); @(negedge clk); group_abort = 0; cluster_quiescent = 1;
        accept_done(FIRST_GROUP, 1, 0);

        if (groups_accepted !== 3 || groups_completed !== 1 || groups_aborted !== 2)
            $fatal(1, "group counters mismatch accepted=%0d completed=%0d aborted=%0d", groups_accepted, groups_completed, groups_aborted);
        if (jobs_accepted !== 32 || retires_accepted !== 32)
            $fatal(1, "work counters mismatch jobs=%0d retires=%0d", jobs_accepted, retires_accepted);

        @(negedge clk); counter_clear = 1;
        @(posedge clk); @(negedge clk); counter_clear = 0;
        if (groups_accepted || groups_completed || groups_aborted || jobs_accepted || retires_accepted)
            $fatal(1, "counter_clear failed");

        // A mismatched retire token faults the active group exactly once.
        cluster_quiescent = 0;
        send_command(FIRST_GROUP, 0, 1);
        @(negedge clk);
        retire_group = FIRST_GROUP;
        retire_head = FIRST_GROUP * 4 + 1;
        retire_window = 0;
        retire_valid = 1;
        @(posedge clk); @(negedge clk); retire_valid = 0;
        accept_error(7);
        @(negedge clk); cluster_quiescent = 1;
        accept_done(FIRST_GROUP, 0, 1);

        // counter_clear while busy is rejected and turns the group into error.
        @(negedge clk); clear = 1;
        @(posedge clk); @(negedge clk); clear = 0; cluster_quiescent = 0;
        send_command(FIRST_GROUP, 0, 1);
        @(negedge clk); counter_clear = 1;
        @(posedge clk); @(negedge clk); counter_clear = 0;
        accept_error(9);
        @(negedge clk); cluster_quiescent = 1;
        accept_done(FIRST_GROUP, 0, 1);

        $display("PASS A4 GROUP JOB ADAPTER clusters=%0d cluster_id=%0d mapping=32 normal=1 faults=3 abort=1", CLUSTERS, CLUSTER_ID);
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "watchdog");
    end
endmodule
