`timescale 1ns/1ps

module tb_cats_r4_b2_weight_stager;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic counter_clear = 1'b0;
    always #5 clk = ~clk;

    logic stage_begin_valid, stage_begin_ready;
    logic [15:0] stage_begin_epoch;
    logic [2:0] stage_begin_group;
    logic [4:0] stage_begin_global_q_head;
    logic [6:0] stage_begin_row;
    logic [1:0] stage_begin_slot_id, stage_begin_numeric_mode;
    logic stage_weight_valid, stage_weight_ready;
    logic [15:0] stage_weight_epoch;
    logic [2:0] stage_weight_group;
    logic [4:0] stage_weight_global_q_head;
    logic [6:0] stage_weight_row;
    logic [1:0] stage_weight_slot_id, stage_weight_numeric_mode;
    logic [6:0] stage_weight_key;
    logic [31:0] stage_weight_data;
    logic stage_weight_last;
    logic stage_finalize_valid, stage_finalize_ready;
    logic [15:0] stage_finalize_epoch;
    logic [2:0] stage_finalize_group;
    logic [4:0] stage_finalize_global_q_head;
    logic [6:0] stage_finalize_row;
    logic [1:0] stage_finalize_slot_id, stage_finalize_numeric_mode;
    logic [31:0] stage_finalize_sum_fp32;
    logic [31:0] stage_finalize_inv_sum_fp32;
    logic stage_finalize_numeric_error;

    logic weight_wr_valid, weight_wr_ready;
    logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group;
    logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row;
    logic [1:0] weight_wr_slot_id, weight_wr_numeric_mode;
    logic [6:0] weight_wr_key;
    logic weight_wr_mask;
    logic [31:0] weight_wr_data;
    logic weight_wr_last;
    logic row_commit_valid, row_commit_ready;
    logic [15:0] row_commit_epoch;
    logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head;
    logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id, row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32, row_commit_inv_sum_fp32;

    logic row_error_valid, row_error_ready;
    logic [15:0] row_error_epoch;
    logic [2:0] row_error_group;
    logic [4:0] row_error_global_q_head;
    logic [6:0] row_error_row;
    logic [1:0] row_error_slot_id, row_error_numeric_mode;
    logic [3:0] row_error_code;
    logic [6:0] row_error_bad_key;
    logic slot_release_valid, slot_release_ready;
    logic [15:0] slot_release_epoch;
    logic [2:0] slot_release_group;
    logic [4:0] slot_release_global_q_head;
    logic [6:0] slot_release_row;
    logic [1:0] slot_release_slot_id, slot_release_numeric_mode;

    logic [8:0] slot_state;
    logic [63:0] rows_begin, stage_weight_accept, rows_validated;
    logic [63:0] rows_error, weight_wr_accept, row_commit_count;
    logic [63:0] slot_release_count, output_stall_cycles;
    logic [63:0] protocol_error_count, numeric_error_count;
    logic [63:0] last_error_count, mode_error_count, epoch_drop_count;
    logic [63:0] owner_error_count, mask_error_count;
    logic error_sticky;

    logic random_backpressure = 1'b0;
    logic [31:0] lfsr = 32'h5a17c0de;
    integer expected_key [0:2];
    integer expected_writes [0:2];
    integer observed_commits [0:2];
    logic [15:0] expected_epoch [0:2];
    logic [4:0] expected_head [0:2];
    logic [6:0] expected_row [0:2];
    logic [1:0] expected_mode [0:2];
    logic [31:0] expected_sum [0:2];
    logic [31:0] expected_inv [0:2];
    integer monitor_commits = 0;
    integer monitor_writes = 0;
    integer monitor_errors = 0;
    integer loop_index;

    logic hold_weight;
    logic [75:0] held_weight_payload;
    logic hold_commit;
    logic [98:0] held_commit_payload;
    logic hold_error;
    logic [45:0] held_error_payload;

    cats_r4_b2_weight_stager dut (.*);

    function automatic logic [31:0] one_weight(input logic [1:0] mode);
        begin
            one_weight = mode == 0 ? 32'h00003f80 : 32'h3f800000;
        end
    endfunction

    task automatic begin_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot,
        input logic [1:0] mode
    );
        begin
            @(negedge clk);
            stage_begin_epoch = epoch;
            stage_begin_group = head[4:2];
            stage_begin_global_q_head = head;
            stage_begin_row = row_id;
            stage_begin_slot_id = slot;
            stage_begin_numeric_mode = mode;
            stage_begin_valid = 1'b1;
            do @(posedge clk); while (!stage_begin_ready);
            @(negedge clk);
            stage_begin_valid = 1'b0;
            expected_epoch[slot] = epoch;
            expected_head[slot] = head;
            expected_row[slot] = row_id;
            expected_mode[slot] = mode;
            expected_key[slot] = 0;
            expected_writes[slot] = 0;
        end
    endtask

    task automatic stage_one_weight(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot,
        input logic [1:0] mode,
        input logic [6:0] key,
        input logic [31:0] data,
        input logic last
    );
        begin
            @(negedge clk);
            stage_weight_epoch = epoch;
            stage_weight_group = head[4:2];
            stage_weight_global_q_head = head;
            stage_weight_row = row_id;
            stage_weight_slot_id = slot;
            stage_weight_numeric_mode = mode;
            stage_weight_key = key;
            stage_weight_data = data;
            stage_weight_last = last;
            stage_weight_valid = 1'b1;
            do @(posedge clk); while (!stage_weight_ready);
            @(negedge clk);
            stage_weight_valid = 1'b0;
        end
    endtask

    task automatic finalize_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot,
        input logic [1:0] mode,
        input logic [31:0] sum_value,
        input logic [31:0] inv_value,
        input logic numeric_error
    );
        begin
            @(negedge clk);
            stage_finalize_epoch = epoch;
            stage_finalize_group = head[4:2];
            stage_finalize_global_q_head = head;
            stage_finalize_row = row_id;
            stage_finalize_slot_id = slot;
            stage_finalize_numeric_mode = mode;
            stage_finalize_sum_fp32 = sum_value;
            stage_finalize_inv_sum_fp32 = inv_value;
            stage_finalize_numeric_error = numeric_error;
            stage_finalize_valid = 1'b1;
            do @(posedge clk); while (!stage_finalize_ready);
            @(negedge clk);
            stage_finalize_valid = 1'b0;
            if (!numeric_error) begin
                expected_sum[slot] = sum_value;
                expected_inv[slot] = inv_value;
            end
        end
    endtask

    task automatic release_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot,
        input logic [1:0] mode
    );
        begin
            @(negedge clk);
            slot_release_epoch = epoch;
            slot_release_group = head[4:2];
            slot_release_global_q_head = head;
            slot_release_row = row_id;
            slot_release_slot_id = slot;
            slot_release_numeric_mode = mode;
            slot_release_valid = 1'b1;
            do @(posedge clk); while (!slot_release_ready);
            @(negedge clk);
            slot_release_valid = 1'b0;
        end
    endtask

    task automatic accept_error(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot,
        input logic [1:0] mode,
        input logic [3:0] code,
        input logic [6:0] bad_key
    );
        begin
            wait (row_error_valid);
            if (row_error_epoch !== epoch ||
                row_error_group !== head[4:2] ||
                row_error_global_q_head !== head ||
                row_error_row !== row_id || row_error_slot_id !== slot ||
                row_error_numeric_mode !== mode ||
                row_error_code !== code || row_error_bad_key !== bad_key)
                $fatal(1, "row error payload mismatch");
            repeat (3) @(posedge clk);
            if (!row_error_valid)
                $fatal(1, "stalled row error disappeared");
            @(negedge clk);
            row_error_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            row_error_ready = 1'b0;
            release_row(epoch, head, row_id, slot, mode);
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n || clear) begin
            lfsr <= 32'h5a17c0de;
            if (random_backpressure) begin
                weight_wr_ready <= 1'b0;
                row_commit_ready <= 1'b0;
            end
        end else if (random_backpressure) begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            weight_wr_ready <= lfsr[0] || lfsr[3];
            row_commit_ready <= lfsr[5] || lfsr[9];
        end
    end

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            hold_weight <= 1'b0;
            hold_commit <= 1'b0;
            hold_error <= 1'b0;
        end else begin
            if (hold_weight &&
                {weight_wr_epoch,weight_wr_group,
                 weight_wr_global_q_head,weight_wr_row,
                 weight_wr_slot_id,weight_wr_numeric_mode,
                 weight_wr_key,weight_wr_mask,weight_wr_data,
                 weight_wr_last} !== held_weight_payload)
                $fatal(1, "weight payload changed while stalled");
            if (hold_commit &&
                {row_commit_epoch,row_commit_group,
                 row_commit_global_q_head,row_commit_row,
                 row_commit_slot_id,row_commit_numeric_mode,
                 row_commit_sum_fp32,row_commit_inv_sum_fp32} !==
                held_commit_payload)
                $fatal(1, "row commit payload changed while stalled");
            if (hold_error &&
                {row_error_epoch,row_error_group,row_error_global_q_head,
                 row_error_row,row_error_slot_id,row_error_numeric_mode,
                 row_error_code,row_error_bad_key} !== held_error_payload)
                $fatal(1, "row error payload changed while stalled");

            hold_weight <= weight_wr_valid && !weight_wr_ready;
            if (weight_wr_valid && !weight_wr_ready)
                held_weight_payload <=
                    {weight_wr_epoch,weight_wr_group,
                     weight_wr_global_q_head,weight_wr_row,
                     weight_wr_slot_id,weight_wr_numeric_mode,
                     weight_wr_key,weight_wr_mask,weight_wr_data,
                     weight_wr_last};
            hold_commit <= row_commit_valid && !row_commit_ready;
            if (row_commit_valid && !row_commit_ready)
                held_commit_payload <=
                    {row_commit_epoch,row_commit_group,
                     row_commit_global_q_head,row_commit_row,
                     row_commit_slot_id,row_commit_numeric_mode,
                     row_commit_sum_fp32,row_commit_inv_sum_fp32};
            hold_error <= row_error_valid && !row_error_ready;
            if (row_error_valid && !row_error_ready)
                held_error_payload <=
                    {row_error_epoch,row_error_group,
                     row_error_global_q_head,row_error_row,
                     row_error_slot_id,row_error_numeric_mode,
                     row_error_code,row_error_bad_key};
        end

        if (rst_n && !clear && weight_wr_valid && weight_wr_ready) begin
            if (weight_wr_epoch !== expected_epoch[weight_wr_slot_id] ||
                weight_wr_group !==
                    expected_head[weight_wr_slot_id][4:2] ||
                weight_wr_global_q_head !== expected_head[weight_wr_slot_id] ||
                weight_wr_row !== expected_row[weight_wr_slot_id] ||
                weight_wr_numeric_mode !== expected_mode[weight_wr_slot_id] ||
                weight_wr_key !== expected_key[weight_wr_slot_id] ||
                weight_wr_last !== (weight_wr_key == 127) ||
                weight_wr_mask !==
                    (weight_wr_key > expected_row[weight_wr_slot_id]))
                $fatal(1, "weight V3 metadata/order mismatch");
            if (weight_wr_mask) begin
                if (weight_wr_data !== 0)
                    $fatal(1, "masked weight was not zero");
            end else if (weight_wr_data !==
                         one_weight(expected_mode[weight_wr_slot_id])) begin
                $fatal(1, "valid staged weight data mismatch");
            end
            expected_key[weight_wr_slot_id] =
                expected_key[weight_wr_slot_id] + 1;
            expected_writes[weight_wr_slot_id] =
                expected_writes[weight_wr_slot_id] + 1;
            monitor_writes = monitor_writes + 1;
        end

        if (rst_n && !clear && row_commit_valid && row_commit_ready) begin
            if (expected_writes[row_commit_slot_id] != 128 ||
                row_commit_epoch !== expected_epoch[row_commit_slot_id] ||
                row_commit_group !== expected_head[row_commit_slot_id][4:2] ||
                row_commit_global_q_head !== expected_head[row_commit_slot_id] ||
                row_commit_row !== expected_row[row_commit_slot_id] ||
                row_commit_numeric_mode !== expected_mode[row_commit_slot_id] ||
                row_commit_sum_fp32 !== expected_sum[row_commit_slot_id] ||
                row_commit_inv_sum_fp32 !== expected_inv[row_commit_slot_id])
                $fatal(1, "row commit before 128 writes or metadata mismatch");
            observed_commits[row_commit_slot_id] =
                observed_commits[row_commit_slot_id] + 1;
            monitor_commits = monitor_commits + 1;
        end

        if (rst_n && !clear && row_error_valid && row_error_ready)
            monitor_errors = monitor_errors + 1;
    end

    initial begin
        stage_begin_valid = 0;
        stage_begin_epoch = 0;
        stage_begin_group = 0;
        stage_begin_global_q_head = 0;
        stage_begin_row = 0;
        stage_begin_slot_id = 0;
        stage_begin_numeric_mode = 0;
        stage_weight_valid = 0;
        stage_weight_epoch = 0;
        stage_weight_group = 0;
        stage_weight_global_q_head = 0;
        stage_weight_row = 0;
        stage_weight_slot_id = 0;
        stage_weight_numeric_mode = 0;
        stage_weight_key = 0;
        stage_weight_data = 0;
        stage_weight_last = 0;
        stage_finalize_valid = 0;
        stage_finalize_epoch = 0;
        stage_finalize_group = 0;
        stage_finalize_global_q_head = 0;
        stage_finalize_row = 0;
        stage_finalize_slot_id = 0;
        stage_finalize_numeric_mode = 0;
        stage_finalize_sum_fp32 = 0;
        stage_finalize_inv_sum_fp32 = 0;
        stage_finalize_numeric_error = 0;
        weight_wr_ready = 0;
        row_commit_ready = 0;
        row_error_ready = 0;
        slot_release_valid = 0;
        slot_release_epoch = 0;
        slot_release_group = 0;
        slot_release_global_q_head = 0;
        slot_release_row = 0;
        slot_release_slot_id = 0;
        slot_release_numeric_mode = 0;
        hold_weight = 0;
        hold_commit = 0;
        hold_error = 0;
        for (loop_index = 0; loop_index < 3; loop_index = loop_index + 1) begin
            expected_key[loop_index] = 0;
            expected_writes[loop_index] = 0;
            observed_commits[loop_index] = 0;
            expected_epoch[loop_index] = 0;
            expected_head[loop_index] = 0;
            expected_row[loop_index] = 0;
            expected_mode[loop_index] = 0;
            expected_sum[loop_index] = 0;
            expected_inv[loop_index] = 0;
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // A row cannot leak to C before finalize.
        begin_row(16'h1001, 5'd0, 7'd2, 2'd0, 2'd0);
        stage_one_weight(16'h1001, 0, 2, 0, 0, 0,
                         32'h00003f80, 0);
        stage_one_weight(16'h1001, 0, 2, 0, 0, 1,
                         32'h00003f80, 0);
        stage_one_weight(16'h1001, 0, 2, 0, 0, 2,
                         32'h00003f80, 1);
        repeat (3) @(posedge clk);
        if (weight_wr_valid || row_commit_valid)
            $fatal(1, "row published before validated finalize");
        finalize_row(16'h1001, 0, 2, 0, 0,
                     32'h40400000, 32'h3eaaaaab, 0);

        // Fill all three approved staging slots while C is stalled.
        begin_row(16'h1001, 5'd1, 7'd0, 2'd1, 2'd1);
        stage_one_weight(16'h1001, 1, 0, 1, 1, 0,
                         32'h3f800000, 1);
        finalize_row(16'h1001, 1, 0, 1, 1,
                     32'h3f800000, 32'h3f800000, 0);
        begin_row(16'h1001, 5'd2, 7'd1, 2'd2, 2'd1);
        stage_one_weight(16'h1001, 2, 1, 2, 1, 0,
                         32'h3f800000, 0);
        stage_one_weight(16'h1001, 2, 1, 2, 1, 1,
                         32'h3f800000, 1);
        finalize_row(16'h1001, 2, 1, 2, 1,
                     32'h3fc00000, 32'h3f2aaaab, 0);
        repeat (3) @(posedge clk);
        if (stage_begin_ready || slot_state[2:0] == 0 ||
            slot_state[5:3] == 0 || slot_state[8:6] == 0)
            $fatal(1, "three-slot capacity was not held");

        random_backpressure = 1'b1;
        wait (row_commit_count == 3);
        repeat (3) @(posedge clk);
        if (weight_wr_accept != 384 || monitor_writes != 384 ||
            monitor_commits != 3 || output_stall_cycles == 0)
            $fatal(1, "three-slot publish counter mismatch");

        // A stale full-token release cannot free a HELD slot and is counted
        // once even when valid remains asserted for multiple cycles.
        @(negedge clk);
        slot_release_epoch = 16'h1000;
        slot_release_group = 0;
        slot_release_global_q_head = 0;
        slot_release_row = 2;
        slot_release_slot_id = 0;
        slot_release_numeric_mode = 0;
        slot_release_valid = 1;
        repeat (3) begin
            @(posedge clk);
            if (slot_release_ready)
                $fatal(1, "stale release was accepted");
        end
        @(negedge clk);
        slot_release_valid = 0;
        if (owner_error_count != 1 || epoch_drop_count != 1)
            $fatal(1, "stale release counter mismatch");
        release_row(16'h1001, 0, 2, 0, 0);
        release_row(16'h1001, 1, 0, 1, 1);
        release_row(16'h1001, 2, 1, 2, 1);

        // Wrong last is detected before any new C write and the error payload
        // remains stable under backpressure.
        random_backpressure = 1'b0;
        weight_wr_ready = 1'b1;
        row_commit_ready = 1'b1;
        begin_row(16'h1002, 3, 1, 0, 0);
        stage_one_weight(16'h1002, 3, 1, 0, 0, 0,
                         32'h00003f80, 1);
        accept_error(16'h1002, 3, 1, 0, 0, 4'd3, 0);
        if (weight_wr_accept != 384 || row_commit_count != 3)
            $fatal(1, "bad-last row wrote C");

        // Old-epoch staged completion is rejected and counted.
        begin_row(16'h1003, 4, 0, 1, 1);
        stage_one_weight(16'h1004, 4, 0, 1, 1, 0,
                         32'h3f800000, 1);
        accept_error(16'h1003, 4, 0, 1, 1, 4'd1, 0);
        if (epoch_drop_count != 2)
            $fatal(1, "old epoch was not counted");

        // Upstream numeric failure may terminate before any weight exists.
        begin_row(16'h1005, 5, 7, 2, 1);
        finalize_row(16'h1005, 5, 7, 2, 1,
                     32'h3f800000, 32'h3f800000, 1);
        accept_error(16'h1005, 5, 7, 2, 1, 4'd7, 0);
        if (numeric_error_count != 1 || monitor_errors != 3 ||
            weight_wr_accept != 384 || row_commit_count != 3)
            $fatal(1, "error-path closure mismatch");

        // Non-finite Accuracy weight and row metadata are also rejected before
        // publication.  The explicit mode check covers unsupported 2/3.
        begin_row(16'h1006, 6, 0, 0, 1);
        stage_one_weight(16'h1006, 6, 0, 0, 1, 0,
                         32'h7f800000, 1);
        accept_error(16'h1006, 6, 0, 0, 1, 4'd5, 0);
        begin_row(16'h1007, 7, 0, 1, 1);
        stage_one_weight(16'h1007, 7, 0, 1, 1, 0,
                         32'h3f800000, 1);
        finalize_row(16'h1007, 7, 0, 1, 1,
                     32'h7f800000, 32'h3f800000, 0);
        accept_error(16'h1007, 7, 0, 1, 1, 4'd6, 1);
        begin_row(16'h1008, 8, 0, 2, 2);
        accept_error(16'h1008, 8, 0, 2, 2, 4'd4, 0);
        if (numeric_error_count != 3 || mode_error_count != 1 ||
            monitor_errors != 6 || weight_wr_accept != 384 ||
            row_commit_count != 3)
            $fatal(1, "nonfinite/mode error closure mismatch");

        // Mid-row clear discards old state and resets all counters.
        begin_row(16'h2000, 0, 127, 0, 1);
        stage_one_weight(16'h2000, 0, 127, 0, 1, 0,
                         32'h3f800000, 0);
        @(negedge clk); clear = 1'b1;
        @(posedge clk);
        @(negedge clk); clear = 1'b0;
        repeat (2) @(posedge clk);
        if (slot_state != 0 || rows_begin != 0 ||
            stage_weight_accept != 0 || rows_validated != 0 ||
            weight_wr_accept != 0 || row_commit_count != 0 ||
            error_sticky)
            $fatal(1, "clear failed to discard staging state/counters");

        // Full causal accounting: 32 heads x 128 rows.  A release stub models
        // the later B3/C release only for this B2 unit test.
        random_backpressure = 1'b1;
        monitor_writes = 0;
        monitor_commits = 0;
        monitor_errors = 0;
        for (loop_index = 0; loop_index < 3; loop_index = loop_index + 1)
            observed_commits[loop_index] = 0;
        for (integer head_index = 0; head_index < 32;
             head_index = head_index + 1) begin
            for (integer row_index = 0; row_index < 128;
                 row_index = row_index + 1) begin
                integer selected_slot;
                logic [1:0] selected_mode;
                selected_slot = (head_index + row_index) % 3;
                selected_mode = head_index[0];
                begin_row(16'hb200, head_index[4:0], row_index[6:0],
                          selected_slot[1:0], selected_mode);
                for (integer key_index = 0; key_index <= row_index;
                     key_index = key_index + 1)
                    stage_one_weight(
                        16'hb200, head_index[4:0], row_index[6:0],
                        selected_slot[1:0], selected_mode,
                        key_index[6:0], one_weight(selected_mode),
                        key_index == row_index);
                finalize_row(16'hb200, head_index[4:0], row_index[6:0],
                             selected_slot[1:0], selected_mode,
                             32'h3f800000, 32'h3f800000, 0);
                wait (observed_commits[selected_slot] != 0);
                observed_commits[selected_slot] = 0;
                release_row(16'hb200, head_index[4:0], row_index[6:0],
                            selected_slot[1:0], selected_mode);
            end
        end
        repeat (5) @(posedge clk);
        if (rows_begin != 4096 || stage_weight_accept != 264192 ||
            rows_validated != 4096 || weight_wr_accept != 524288 ||
            row_commit_count != 4096 || slot_release_count != 4096 ||
            rows_error != 0 || owner_error_count != 0 ||
            mask_error_count != 0 || error_sticky || monitor_errors != 0 ||
            monitor_writes != 524288 || monitor_commits != 4096)
            $fatal(1, "full causal staging/publication closure failed");

        $display("PASS: CATS-R4 B2 scheme-A stager rows=%0d valid_weights=%0d weight_wr=%0d commits=%0d releases=%0d stalls=%0d",
                 rows_begin, stage_weight_accept, weight_wr_accept,
                 row_commit_count, slot_release_count,
                 output_stall_cycles);
        $finish;
    end
endmodule
