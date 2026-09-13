`timescale 1ns/1ps

module tb_cats_r4_a3_error_join;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n, clear, counter_clear;
    logic a_valid, a_ready;
    logic [15:0] a_epoch;
    logic [2:0] a_group;
    logic [4:0] a_global_q_head;
    logic [6:0] a_row;
    logic [1:0] a_slot_id, a_numeric_mode;
    logic [2:0] a_code;
    logic [6:0] a_bad_key;
    logic b_valid, b_ready;
    logic [15:0] b_epoch;
    logic [2:0] b_group;
    logic [4:0] b_global_q_head;
    logic [6:0] b_row;
    logic [1:0] b_slot_id, b_numeric_mode;
    logic [3:0] b_code;
    logic [6:0] b_bad_key;
    logic error_valid, error_ready;
    logic [1:0] error_source;
    logic [15:0] error_epoch;
    logic [2:0] error_group;
    logic [4:0] error_global_q_head;
    logic [6:0] error_row;
    logic [1:0] error_slot_id, error_numeric_mode;
    logic [3:0] error_code;
    logic [6:0] error_bad_key;
    logic [63:0] a_errors_accepted, b_errors_accepted;
    logic [63:0] errors_delivered, simultaneous_errors, error_stall_cycles;

    logic [45:0] a_queue [0:31];
    logic [45:0] b_queue [0:31];
    integer a_put, a_get, b_put, b_get;
    integer a_seen, b_seen;
    integer last_source, opposing_run;
    logic scoreboard_enable;
    logic [45:0] held_payload;
    logic a_fire_sample, b_fire_sample;
    logic [63:0] held_a_count, held_b_count, held_delivered_count;
    logic [63:0] held_simultaneous_count, held_stall_count;

    wire [45:0] a_payload = {a_epoch, a_group, a_global_q_head, a_row,
                             a_slot_id, a_numeric_mode, {1'b0, a_code}, a_bad_key};
    wire [45:0] b_payload = {b_epoch, b_group, b_global_q_head, b_row,
                             b_slot_id, b_numeric_mode, b_code, b_bad_key};
    wire [45:0] error_payload = {error_epoch, error_group, error_global_q_head,
                                 error_row, error_slot_id, error_numeric_mode,
                                 error_code, error_bad_key};

    cats_r4_a3_error_join dut (
        .clk, .rst_n, .clear, .counter_clear,
        .a_valid, .a_ready, .a_epoch, .a_group, .a_global_q_head, .a_row,
        .a_slot_id, .a_numeric_mode, .a_code, .a_bad_key,
        .b_valid, .b_ready, .b_epoch, .b_group, .b_global_q_head, .b_row,
        .b_slot_id, .b_numeric_mode, .b_code, .b_bad_key,
        .error_valid, .error_ready, .error_source, .error_epoch, .error_group,
        .error_global_q_head, .error_row, .error_slot_id, .error_numeric_mode,
        .error_code, .error_bad_key, .a_errors_accepted, .b_errors_accepted,
        .errors_delivered, .simultaneous_errors, .error_stall_cycles
    );

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic set_a(input integer n);
        begin
            a_epoch = 16'ha100 + n; a_group = n[2:0];
            a_global_q_head = n + 1; a_row = 7'd10 + n;
            a_slot_id = n[1:0]; a_numeric_mode = n[1:0];
            a_code = (n + 1) & 7; a_bad_key = 7'd20 + n;
        end
    endtask

    task automatic set_b(input integer n);
        begin
            b_epoch = 16'hb400 + n; b_group = n[2:0];
            b_global_q_head = 5'd16 + n; b_row = 7'd70 + n;
            b_slot_id = n[1:0]; b_numeric_mode = (n + 1) & 3;
            b_code = 4'd8 + n; b_bad_key = 7'd90 + n;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && !clear && scoreboard_enable) begin
            if (a_valid && a_ready) begin
                a_queue[a_put] = a_payload;
                a_put = a_put + 1;
            end
            if (b_valid && b_ready) begin
                b_queue[b_put] = b_payload;
                b_put = b_put + 1;
            end
            if (error_valid && error_ready) begin
                if (error_source === 2'd0) begin
                    if (a_get >= a_put || error_payload !== a_queue[a_get])
                        $fatal(1, "A error loss/duplication/order mismatch");
                    a_get = a_get + 1;
                    a_seen = a_seen + 1;
                end else if (error_source === 2'd1) begin
                    if (b_get >= b_put || error_payload !== b_queue[b_get])
                        $fatal(1, "B4 error loss/duplication/order mismatch");
                    b_get = b_get + 1;
                    b_seen = b_seen + 1;
                end else begin
                    $fatal(1, "invalid unified error source");
                end
                if (a_valid && b_valid) begin
                    if (last_source == error_source)
                        opposing_run = opposing_run + 1;
                    else
                        opposing_run = 0;
                    if (opposing_run > 0)
                        $fatal(1, "fairness violation: source won twice while both active");
                    last_source = error_source;
                end
            end
        end
    end

    initial begin
        repeat (200) tick();
        $fatal(1, "A3 error join timeout");
    end

    initial begin
        rst_n = 0; clear = 0; counter_clear = 0;
        a_valid = 0; b_valid = 0; error_ready = 0;
        set_a(0); set_b(0);
        a_put = 0; a_get = 0; b_put = 0; b_get = 0;
        a_seen = 0; b_seen = 0; last_source = -1; opposing_run = 0;
        scoreboard_enable = 1;
        repeat (3) tick(); rst_n = 1; tick();

        // prefer_b=1: adding B to an A-only stall must not change the winner.
        @(negedge clk); error_ready = 1; set_a(20); a_valid = 1;
        tick();
        @(negedge clk); a_valid = 0;
        tick();
        @(negedge clk); error_ready = 0; set_a(21); a_valid = 1;
        tick();
        @(negedge clk); a_valid = 0;
        held_payload = error_payload;
        if (!error_valid || error_source !== 0)
            $fatal(1, "failed to construct A-only stalled output");
        @(negedge clk); set_b(21); b_valid = 1;
        tick();
        @(negedge clk); b_valid = 0;
        repeat (3) begin
            if (!error_valid || error_source !== 0 ||
                error_payload !== held_payload)
                $fatal(1, "B arrival changed locked stalled A output");
            tick();
        end
        @(negedge clk); error_ready = 1;
        tick();
        if (!error_valid || error_source !== 1)
            $fatal(1, "B did not follow locked stalled A exactly once");
        tick();

        // prefer_b=0: adding A to a B-only stall is the symmetric case.
        @(negedge clk); error_ready = 0; set_b(22); b_valid = 1;
        tick();
        @(negedge clk); b_valid = 0;
        held_payload = error_payload;
        if (!error_valid || error_source !== 1)
            $fatal(1, "failed to construct B-only stalled output");
        @(negedge clk); set_a(22); a_valid = 1;
        tick();
        @(negedge clk); a_valid = 0;
        repeat (3) begin
            if (!error_valid || error_source !== 1 ||
                error_payload !== held_payload)
                $fatal(1, "A arrival changed locked stalled B output");
            tick();
        end
        @(negedge clk); error_ready = 1;
        tick();
        if (!error_valid || error_source !== 0)
            $fatal(1, "A did not follow locked stalled B exactly once");
        tick();

        // clear suppresses every public handshake and drops pending state only.
        @(negedge clk); error_ready = 0; set_a(23); a_valid = 1;
        tick();
        @(negedge clk); a_valid = 0;
        @(negedge clk); set_a(24); set_b(24); a_valid = 1; b_valid = 1;
        error_ready = 1; clear = 1;
        held_a_count = a_errors_accepted;
        held_b_count = b_errors_accepted;
        held_delivered_count = errors_delivered;
        held_simultaneous_count = simultaneous_errors;
        held_stall_count = error_stall_cycles;
        #1;
        if (error_valid !== 0 || a_ready !== 0 || b_ready !== 0)
            $fatal(1, "clear exposed a public error handshake");
        tick();
        if (a_errors_accepted !== held_a_count ||
            b_errors_accepted !== held_b_count ||
            errors_delivered !== held_delivered_count ||
            simultaneous_errors !== held_simultaneous_count ||
            error_stall_cycles !== held_stall_count)
            $fatal(1, "clear created phantom error accounting");
        @(negedge clk); clear = 0; a_valid = 0; b_valid = 0;
        a_put = 0; a_get = 0; b_put = 0; b_get = 0;
        a_seen = 0; b_seen = 0; last_source = -1; opposing_run = 0;
        counter_clear = 1;
        tick();
        @(negedge clk); counter_clear = 0; error_ready = 1;
        set_a(25); set_b(25); a_valid = 1; b_valid = 1;
        tick();
        @(negedge clk); a_valid = 0; b_valid = 0;
        tick();
        if (a_seen !== 1 || b_seen !== 0 || error_source !== 1)
            $fatal(1, "post-clear restart did not deliver A first");
        tick();
        if (a_seen !== 1 || b_seen !== 1 || error_valid)
            $fatal(1, "post-clear restart did not deliver B second");

        // Begin the original counter-exact regression from an empty epoch.
        @(negedge clk); counter_clear = 1;
        tick();
        @(negedge clk); counter_clear = 0; error_ready = 0;
        a_put = 0; a_get = 0; b_put = 0; b_get = 0;
        a_seen = 0; b_seen = 0; last_source = -1; opposing_run = 0;
        set_a(0); set_b(0);

        // Both empty buffers accept independently, with reset preference A.
        @(negedge clk); a_valid = 1; b_valid = 1;
        #1;
        if (a_ready !== 1 || b_ready !== 1)
            $fatal(1, "empty buffers did not accept simultaneous errors");
        tick();
        @(negedge clk); a_valid = 0; b_valid = 0;
        #1;
        if (!error_valid || error_source !== 0 || error_payload !== a_queue[0])
            $fatal(1, "simultaneous capture did not present A first");
        held_payload = error_payload;
        repeat (4) begin
            tick();
            if (!error_valid || error_source !== 0 || error_payload !== held_payload)
                $fatal(1, "unified error changed during four-cycle stall");
        end
        if (error_stall_cycles !== 4)
            $fatal(1, "stall counter mismatch after four full cycles");
        @(negedge clk); error_ready = 1;
        tick();
        if (!error_valid || error_source !== 1 || error_payload !== b_queue[0])
            $fatal(1, "B4 error did not follow simultaneous A error");
        tick();
        if (error_valid) $fatal(1, "initial buffers did not drain");

        // Four tokens per continuously-valid source; replacements happen on drain.
        @(negedge clk); set_a(1); set_b(1); a_valid = 1; b_valid = 1;
        while ((a_seen + b_seen) < 10) begin
            @(posedge clk);
            a_fire_sample = a_valid && a_ready;
            b_fire_sample = b_valid && b_ready;
            #1;
            @(negedge clk);
            if (a_fire_sample) begin
                if (a_put == 5) a_valid = 0;
                else set_a(a_put);
            end
            if (b_fire_sample) begin
                if (b_put == 5) b_valid = 0;
                else set_b(b_put);
            end
        end
        @(negedge clk); a_valid = 0; b_valid = 0;
        tick();
        if (a_seen !== 5 || b_seen !== 5 || a_get !== a_put || b_get !== b_put)
            $fatal(1, "continuous fairness scoreboard did not drain 5+5 tokens");
        if (a_errors_accepted !== 5 || b_errors_accepted !== 5 ||
            errors_delivered !== 10 || simultaneous_errors !== 2 ||
            error_stall_cycles !== 4)
            $fatal(1, "continuous phase counter mismatch");

        // One-sided A traffic remains work-conserving.
        @(negedge clk); set_a(6); a_valid = 1;
        tick();
        @(negedge clk); a_valid = 0;
        tick();
        if (a_seen !== 6 || error_valid)
            $fatal(1, "one-sided A traffic did not drain");

        // counter_clear does not discard a buffered, stalled B4 report.
        @(negedge clk); error_ready = 0; set_b(6); b_valid = 1;
        tick();
        @(negedge clk); b_valid = 0; counter_clear = 1;
        tick();
        @(negedge clk); counter_clear = 0;
        if (!error_valid || error_source !== 1 || error_payload !== b_queue[b_get])
            $fatal(1, "counter_clear discarded buffered B4 error");
        if (a_errors_accepted !== 0 || b_errors_accepted !== 0 ||
            errors_delivered !== 0 || simultaneous_errors !== 0 ||
            error_stall_cycles !== 0)
            $fatal(1, "counter_clear did not clear counters");
        @(negedge clk); error_ready = 1;
        tick();
        if (errors_delivered !== 1 || error_valid)
            $fatal(1, "post-counter_clear buffered report did not drain");

        // Datapath clear drops pending reports and restores A preference.
        @(negedge clk); error_ready = 0; set_a(7); set_b(7);
        a_valid = 1; b_valid = 1;
        tick();
        @(negedge clk); a_valid = 0; b_valid = 0; clear = 1;
        tick();
        @(negedge clk); clear = 0;
        tick();
        if (error_valid || !a_ready || !b_ready)
            $fatal(1, "clear did not invalidate both buffers");

        @(negedge clk); set_a(8); set_b(8); a_valid = 1; b_valid = 1;
        tick();
        @(negedge clk); a_valid = 0; b_valid = 0;
        if (!error_valid || error_source !== 0)
            $fatal(1, "clear did not restore A-first arbitration");
        @(negedge clk); clear = 1;
        tick();
        @(negedge clk); clear = 0;

        scoreboard_enable = 0;
        $display("PASS: CATS-R4 A3 buffered error join simultaneous capture, fairness, stalls, replacement, clear, and counters");
        $finish;
    end
endmodule
