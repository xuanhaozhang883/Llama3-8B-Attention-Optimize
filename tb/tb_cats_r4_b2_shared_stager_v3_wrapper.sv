`timescale 1ns/1ps

module tb_cats_r4_b2_shared_stager_v3_wrapper;
    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic counter_clear = 0;

    logic row_valid = 0;
    logic row_ready;
    logic [15:0] row_epoch = 0;
    logic [2:0] row_group = 0;
    logic [4:0] row_global_q_head = 0;
    logic [6:0] row_index = 0;
    logic [1:0] row_slot_id = 0;
    logic [1:0] row_numeric_mode = 0;
    logic [15:0] row_max_bf16 = 0;

    logic score_valid = 0;
    logic score_ready;
    logic [15:0] score_epoch = 0;
    logic [2:0] score_group = 0;
    logic [4:0] score_global_q_head = 0;
    logic [6:0] score_row = 0;
    logic [1:0] score_slot_id = 0;
    logic [1:0] score_numeric_mode = 0;
    logic [6:0] score_key = 0;
    logic [15:0] score_bf16 = 0;
    logic score_last = 0;

    logic weight_wr_valid;
    logic weight_wr_ready = 0;
    logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group;
    logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row;
    logic [1:0] weight_wr_slot_id;
    logic [1:0] weight_wr_numeric_mode;
    logic [6:0] weight_wr_key;
    logic weight_wr_mask;
    logic [31:0] weight_wr_data;
    logic weight_wr_last;

    logic row_commit_valid;
    logic row_commit_ready = 0;
    logic [15:0] row_commit_epoch;
    logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head;
    logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id;
    logic [1:0] row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32;
    logic [31:0] row_commit_inv_sum_fp32;

    logic row_error_valid;
    logic row_error_ready = 0;
    logic [15:0] row_error_epoch;
    logic [2:0] row_error_group;
    logic [4:0] row_error_global_q_head;
    logic [6:0] row_error_row;
    logic [1:0] row_error_slot_id;
    logic [1:0] row_error_numeric_mode;
    logic [3:0] row_error_code;
    logic [6:0] row_error_bad_key;

    logic slot_release_valid = 0;
    logic slot_release_ready;
    logic [15:0] slot_release_epoch = 0;
    logic [2:0] slot_release_group = 0;
    logic [4:0] slot_release_global_q_head = 0;
    logic [6:0] slot_release_row = 0;
    logic [1:0] slot_release_slot_id = 0;
    logic [1:0] slot_release_numeric_mode = 0;

    logic [2:0] slot_owned_state;
    logic [5:0] slot_mode_state;
    logic [63:0] rows_issue;
    logic [63:0] rows_result;
    logic [63:0] exp_issue;
    logic [63:0] exp_result;
    logic [63:0] exp_commit;
    logic [63:0] sum_issue;
    logic [63:0] sum_result;
    logic [63:0] sum_commit;
    logic [63:0] reciprocal_issue;
    logic [63:0] reciprocal_result;
    logic [63:0] reciprocal_commit;
    logic [63:0] staged_weight_accept;
    logic [63:0] weight_wr_accept;
    logic [63:0] row_commit_count;
    logic [63:0] slot_release_count;
    logic [63:0] protocol_error_count;
    logic [63:0] numeric_error_count;
    logic [63:0] owner_error_count;
    logic [63:0] mask_error_count;
    logic [63:0] mode_error_count;
    logic [63:0] weight_conflict_cycles;
    logic [63:0] finalize_conflict_cycles;
    logic [63:0] output_stall_cycles;
    logic [63:0] exp_stall_cycles;
    logic [63:0] sum_stall_cycles;
    logic [63:0] reciprocal_busy_stall_cycles;
    logic [63:0] reciprocal_output_stall_cycles;
    logic error_sticky;

    integer seed = 32'h5a17;
    integer ready_state;
    integer input_state;
    integer write_count [0:2];
    integer commit_count [0:2];
    integer error_count = 0;
    integer total_writes = 0;
    integer total_commits = 0;
    integer cycle_count = 0;
    logic [63:0] preclear_rows;
    logic [63:0] preclear_staged;
    logic [63:0] preclear_protocol_errors;
    logic [63:0] preclear_output_stalls;
    logic [63:0] preclear_weight_conflicts;
    logic [63:0] preclear_finalize_conflicts;

    logic weight_was_stalled = 0;
    logic commit_was_stalled = 0;
    logic error_was_stalled = 0;
    logic [75:0] stalled_weight_payload;
    logic [98:0] stalled_commit_payload;
    logic [45:0] stalled_error_payload;

    wire [75:0] weight_payload = {
        weight_wr_epoch, weight_wr_group, weight_wr_global_q_head,
        weight_wr_row, weight_wr_slot_id, weight_wr_numeric_mode,
        weight_wr_key, weight_wr_mask, weight_wr_data, weight_wr_last
    };
    wire [98:0] commit_payload = {
        row_commit_epoch, row_commit_group, row_commit_global_q_head,
        row_commit_row, row_commit_slot_id, row_commit_numeric_mode,
        row_commit_sum_fp32, row_commit_inv_sum_fp32
    };
    wire [45:0] error_payload = {
        row_error_epoch, row_error_group, row_error_global_q_head,
        row_error_row, row_error_slot_id, row_error_numeric_mode,
        row_error_code, row_error_bad_key
    };

    always #5 clk = ~clk;

    cats_r4_b2_shared_stager_v3_wrapper dut (.*);

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        ready_state = seed;
        input_state = seed ^ 32'h6b2f91d3;
        repeat (100000) @(posedge clk);
        $fatal(1,
            "timeout seed=%0d writes=%0d commits=%0d errors=%0d owned=%b",
            seed, total_writes, total_commits, error_count,
            slot_owned_state);
    end

    // Reproducible pseudo-random C-side backpressure.  Inputs obey the
    // ready/valid hold rule in the tasks below.
    always @(negedge clk) begin
        if (!rst_n) begin
            weight_wr_ready = 0;
            row_commit_ready = 0;
            row_error_ready = 0;
        end else begin
            ready_state = ready_state * 1103515245 + 12345;
            weight_wr_ready = ready_state[0] || ready_state[3];
            row_commit_ready = ready_state[1] || ready_state[5];
            row_error_ready = ready_state[2] || ready_state[7];
        end
    end

    always @(posedge clk) begin
        integer slot;
        integer key;
        logic [31:0] expected_data;
        if (rst_n && !clear) begin
            cycle_count = cycle_count + 1;

            if (weight_was_stalled &&
                (!weight_wr_valid || weight_payload != stalled_weight_payload))
                $fatal(1, "weight payload changed under backpressure");
            if (commit_was_stalled &&
                (!row_commit_valid || commit_payload != stalled_commit_payload))
                $fatal(1, "commit payload changed under backpressure");
            if (error_was_stalled &&
                (!row_error_valid || error_payload != stalled_error_payload))
                $fatal(1, "error payload changed under backpressure");

            weight_was_stalled = weight_wr_valid && !weight_wr_ready;
            commit_was_stalled = row_commit_valid && !row_commit_ready;
            error_was_stalled = row_error_valid && !row_error_ready;
            if (weight_was_stalled)
                stalled_weight_payload = weight_payload;
            if (commit_was_stalled)
                stalled_commit_payload = commit_payload;
            if (error_was_stalled)
                stalled_error_payload = error_payload;

            if (weight_wr_valid && weight_wr_ready) begin
                slot = weight_wr_slot_id;
                key = write_count[slot];
                if (slot > 1 || weight_wr_key != key[6:0] ||
                    weight_wr_row != 7'd1 ||
                    weight_wr_mask != (key > 1) ||
                    weight_wr_last != (key == 127))
                    $fatal(1,
                        "weight shape mismatch slot=%0d key=%0d got_key=%0d",
                        slot, key, weight_wr_key);
                expected_data = key > 1 ? 32'd0 :
                    (slot == 0 ? 32'h00003f80 : 32'h3f800000);
                if (weight_wr_data != expected_data)
                    $fatal(1,
                        "weight data mismatch slot=%0d key=%0d got=%h expected=%h",
                        slot, key, weight_wr_data, expected_data);
                if (slot == 0 &&
                    (weight_wr_epoch != 16'h0010 ||
                     weight_wr_global_q_head != 5'd0 ||
                     weight_wr_group != 3'd0 ||
                     weight_wr_numeric_mode != 2'd0))
                    $fatal(1, "Compatibility publish token changed");
                if (slot == 1 &&
                    (weight_wr_epoch != 16'h0010 ||
                     weight_wr_global_q_head != 5'd4 ||
                     weight_wr_group != 3'd1 ||
                     weight_wr_numeric_mode != 2'd1))
                    $fatal(1, "Accuracy publish token changed");
                write_count[slot] = write_count[slot] + 1;
                total_writes = total_writes + 1;
            end

            if (row_commit_valid && row_commit_ready) begin
                slot = row_commit_slot_id;
                if (slot > 1 || write_count[slot] != 128 ||
                    commit_count[slot] != 0 ||
                    row_commit_sum_fp32 != 32'h40000000 ||
                    row_commit_inv_sum_fp32 != 32'h3f000000)
                    $fatal(1,
                        "commit mismatch slot=%0d writes=%0d sum=%h inv=%h",
                        slot, write_count[slot], row_commit_sum_fp32,
                        row_commit_inv_sum_fp32);
                if (row_commit_numeric_mode != slot[1:0])
                    $fatal(1, "commit mode does not match slot owner");
                commit_count[slot] = commit_count[slot] + 1;
                total_commits = total_commits + 1;
            end

            if (row_error_valid && row_error_ready) begin
                if (row_error_epoch != 16'h0020 ||
                    row_error_global_q_head != 5'd8 ||
                    row_error_group != 3'd2 || row_error_row != 7'd1 ||
                    row_error_slot_id != 2'd0 ||
                    row_error_numeric_mode != 2'd1 ||
                    row_error_code == 0)
                    $fatal(1,
                        "error token mismatch epoch=%h head=%0d slot=%0d mode=%0d code=%0d",
                        row_error_epoch, row_error_global_q_head,
                        row_error_slot_id, row_error_numeric_mode,
                        row_error_code);
                error_count = error_count + 1;
            end
        end else begin
            weight_was_stalled = 0;
            commit_was_stalled = 0;
            error_was_stalled = 0;
        end
    end

    task automatic random_input_gap;
        integer gap_cycles;
        begin
            input_state = input_state * 1664525 + 1013904223;
            gap_cycles = input_state[9:8];
            repeat (gap_cycles + 1) @(negedge clk);
        end
    endtask

    task automatic send_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [1:0] mode,
        input logic [15:0] maximum
    );
        begin
            random_input_gap();
            row_valid = 1;
            row_epoch = epoch;
            row_group = head[4:2];
            row_global_q_head = head;
            row_index = row;
            row_slot_id = slot;
            row_numeric_mode = mode;
            row_max_bf16 = maximum;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 0;
        end
    endtask

    task automatic send_score(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [1:0] mode,
        input logic [6:0] key,
        input logic [15:0] score,
        input logic last
    );
        begin
            random_input_gap();
            score_valid = 1;
            score_epoch = epoch;
            score_group = head[4:2];
            score_global_q_head = head;
            score_row = row;
            score_slot_id = slot;
            score_numeric_mode = mode;
            score_key = key;
            score_bf16 = score;
            score_last = last;
            do @(posedge clk); while (!score_ready);
            @(negedge clk);
            score_valid = 0;
        end
    endtask

    task automatic send_release(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [1:0] mode
    );
        begin
            random_input_gap();
            slot_release_valid = 1;
            slot_release_epoch = epoch;
            slot_release_group = head[4:2];
            slot_release_global_q_head = head;
            slot_release_row = row;
            slot_release_slot_id = slot;
            slot_release_numeric_mode = mode;
            do @(posedge clk); while (!slot_release_ready);
            @(negedge clk);
            slot_release_valid = 0;
        end
    endtask

    task automatic send_normal_interleaved_scores;
        integer beat;
        begin
            @(negedge clk);
            score_valid = 1;
            for (beat = 0; beat < 4; beat = beat + 1) begin
                if ((beat & 1) == 0) begin
                    score_epoch = 16'h0010;
                    score_group = 3'd0;
                    score_global_q_head = 5'd0;
                    score_row = 7'd1;
                    score_slot_id = 2'd0;
                    score_numeric_mode = 2'd0;
                end else begin
                    score_epoch = 16'h0010;
                    score_group = 3'd1;
                    score_global_q_head = 5'd4;
                    score_row = 7'd1;
                    score_slot_id = 2'd1;
                    score_numeric_mode = 2'd1;
                end
                score_key = beat[1:1];
                score_bf16 = 16'h3f80;
                score_last = beat >= 2;
                do @(posedge clk); while (!score_ready);
                if (beat != 3)
                    @(negedge clk);
            end
            @(negedge clk);
            score_valid = 0;
        end
    endtask

    initial begin
        write_count[0] = 0;
        write_count[1] = 0;
        write_count[2] = 0;
        commit_count[0] = 0;
        commit_count[1] = 0;
        commit_count[2] = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // Occupy all three shared slots before any score arrives, then use
        // clear as the transaction/epoch cancellation path.  This checks
        // that capacity is exactly three and that no pre-clear owner leaks.
        send_row(16'h0001, 5'd0, 7'd1, 2'd0, 2'd0, 16'h3f80);
        send_row(16'h0001, 5'd4, 7'd1, 2'd1, 2'd1, 16'h3f80);
        send_row(16'h0001, 5'd8, 7'd1, 2'd2, 2'd0, 16'h3f80);
        if (slot_owned_state != 3'b111)
            $fatal(1, "three-slot capacity was not fully occupied");
        @(negedge clk);
        clear = 1;
        @(posedge clk);
        @(negedge clk);
        clear = 0;
        repeat (3) @(posedge clk);
        if (slot_owned_state != 0 || error_sticky)
            $fatal(1,
                "three-slot clear/release leaked state owned=%b sticky=%0d",
                slot_owned_state, error_sticky);
        @(negedge clk);
        counter_clear = 1;
        @(posedge clk);
        @(negedge clk);
        counter_clear = 0;
        @(posedge clk);
        if (rows_issue != 0 || staged_weight_accept != 0)
            $fatal(1, "preflight counter_clear did not reset counters");

        // Two independent arithmetic modes reserve distinct shared slots.
        send_row(16'h0010, 5'd0, 7'd1, 2'd0, 2'd0, 16'h3f80);
        send_row(16'h0010, 5'd4, 7'd1, 2'd1, 2'd1, 16'h3f80);
        if (slot_owned_state[1:0] != 2'b11 ||
            slot_mode_state[1:0] != 2'd0 ||
            slot_mode_state[3:2] != 2'd1)
            $fatal(1, "per-slot mode ownership was not latched");

        // Interleave score ownership.  Both rows are equal-score softmax rows
        // with two causal keys, so sum=2 and reciprocal=0.5.
        send_normal_interleaved_scores();
        wait (total_commits == 2);
        @(negedge clk);
        if (total_writes != 256 || weight_wr_accept != 256 ||
            row_commit_count != 2)
            $fatal(1,
                "normal shared publication count mismatch writes=%0d hw=%0d commits=%0d",
                total_writes, weight_wr_accept, row_commit_count);

        // A committed slot is not reusable until the matching release.  Keep
        // the new row payload stable while releasing the old owner.
        @(negedge clk);
        row_valid = 1;
        row_epoch = 16'h0020;
        row_group = 3'd2;
        row_global_q_head = 5'd8;
        row_index = 7'd1;
        row_slot_id = 2'd0;
        row_numeric_mode = 2'd1;
        row_max_bf16 = 16'h3f80;
        @(posedge clk);
        if (row_ready)
            $fatal(1, "slot was reused before release");
        @(negedge clk);
        slot_release_valid = 1;
        slot_release_epoch = 16'h0010;
        slot_release_group = 3'd0;
        slot_release_global_q_head = 5'd0;
        slot_release_row = 7'd1;
        slot_release_slot_id = 2'd0;
        slot_release_numeric_mode = 2'd0;
        do @(posedge clk); while (!slot_release_ready);
        @(negedge clk);
        slot_release_valid = 0;
        do @(posedge clk); while (!row_ready);
        @(negedge clk);
        row_valid = 0;
        if (slot_mode_state[1:0] != 2'd1)
            $fatal(1, "slot mode did not update on legal reuse");

        send_release(16'h0010, 5'd4, 7'd1, 2'd1, 2'd1);

        // Incoming score mode changes while busy.  Routing stays with the
        // slot's latched Accuracy owner, but the row is rejected before any
        // shared-stager publication reaches C.
        send_score(16'h0020, 5'd8, 7'd1, 2'd0, 2'd0,
                   7'd0, 16'h3f80, 0);
        send_score(16'h0020, 5'd8, 7'd1, 2'd0, 2'd0,
                   7'd1, 16'h3f80, 1);
        wait (error_count == 1);
        if (total_writes != 256 || total_commits != 2 ||
            mode_error_count != 2)
            $fatal(1,
                "bad-mode row leaked or was not counted writes=%0d commits=%0d mode_errors=%0d",
                total_writes, total_commits, mode_error_count);
        send_release(16'h0020, 5'd8, 7'd1, 2'd0, 2'd1);

        if (slot_owned_state != 0 || slot_release_count != 3 ||
            owner_error_count != 0 || mask_error_count != 0 ||
            output_stall_cycles == 0 || !error_sticky)
            $fatal(1,
                "pre-clear counters mismatch owned=%b releases=%0d owner=%0d mask=%0d stalls=%0d sticky=%0d",
                slot_owned_state, slot_release_count, owner_error_count,
                mask_error_count, output_stall_cycles, error_sticky);
        preclear_rows = rows_issue;
        preclear_staged = staged_weight_accept;
        preclear_protocol_errors = protocol_error_count;
        preclear_output_stalls = output_stall_cycles;
        preclear_weight_conflicts = weight_conflict_cycles;
        preclear_finalize_conflicts = finalize_conflict_cycles;

        // A partial old-epoch row is removed by global clear and must never
        // leak a weight, commit, or error into the next epoch.
        send_row(16'h0030, 5'd0, 7'd1, 2'd2, 2'd0, 16'h3f80);
        send_score(16'h0030, 5'd0, 7'd1, 2'd2, 2'd0,
                   7'd0, 16'h3f80, 0);
        repeat (4) @(posedge clk);
        @(negedge clk);
        clear = 1;
        @(posedge clk);
        @(negedge clk);
        clear = 0;
        repeat (40) @(posedge clk);
        if (slot_owned_state != 0 || total_writes != 256 ||
            total_commits != 2 || error_count != 1 || weight_wr_valid ||
            row_commit_valid || row_error_valid || error_sticky)
            $fatal(1,
                "clear failed to discard old epoch owned=%b writes=%0d commits=%0d errors=%0d sticky=%0d",
                slot_owned_state, total_writes, total_commits, error_count,
                error_sticky);

        // counter_clear is a quiescent observability reset.  It must not
        // resurrect the cleared epoch, and it clears every B-owned aggregate
        // counter/sticky indication before the next transaction starts.
        @(negedge clk);
        counter_clear = 1;
        @(posedge clk);
        @(negedge clk);
        counter_clear = 0;
        @(posedge clk);
        if (rows_issue != 0 || rows_result != 0 || exp_issue != 0 ||
            exp_result != 0 || exp_commit != 0 || sum_issue != 0 ||
            sum_result != 0 || sum_commit != 0 || reciprocal_issue != 0 ||
            reciprocal_result != 0 || reciprocal_commit != 0 ||
            staged_weight_accept != 0 || weight_wr_accept != 0 ||
            row_commit_count != 0 || slot_release_count != 0 ||
            protocol_error_count != 0 || numeric_error_count != 0 ||
            owner_error_count != 0 || mask_error_count != 0 ||
            mode_error_count != 0 || weight_conflict_cycles != 0 ||
            finalize_conflict_cycles != 0 || output_stall_cycles != 0 ||
            exp_stall_cycles != 0 || sum_stall_cycles != 0 ||
            reciprocal_busy_stall_cycles != 0 ||
            reciprocal_output_stall_cycles != 0 || error_sticky)
            $fatal(1, "counter_clear did not reset shared B2 observability");

        $display(
            "PASS shared_stager seed=%0d rows=%0d weights_staged=%0d writes=%0d commits=%0d releases=%0d mode_errors=%0d protocol_errors=%0d output_stalls=%0d conflicts=%0d/%0d cycles=%0d",
            seed, preclear_rows, preclear_staged, total_writes,
            total_commits, 3, 2, preclear_protocol_errors,
            preclear_output_stalls, preclear_weight_conflicts,
            preclear_finalize_conflicts, cycle_count);
        $finish;
    end
endmodule
