`timescale 1ns/1ps

module tb_cats_r4_b2_compatibility_v3_wrapper;
    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic counter_clear = 0;
    always #5 clk = ~clk;

    logic row_valid, row_ready;
    logic [15:0] row_epoch;
    logic [2:0] row_group;
    logic [4:0] row_global_q_head;
    logic [6:0] row_index;
    logic [1:0] row_slot_id, row_numeric_mode;
    logic [15:0] row_max_bf16;
    logic score_valid, score_ready;
    logic [15:0] score_epoch;
    logic [2:0] score_group;
    logic [4:0] score_global_q_head;
    logic [6:0] score_row;
    logic [1:0] score_slot_id, score_numeric_mode;
    logic [6:0] score_key;
    logic [15:0] score_bf16;
    logic score_last;

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

    logic [63:0] rows_issue, rows_result;
    logic [63:0] exp_issue, exp_result, exp_commit;
    logic [63:0] sum_issue, sum_result, sum_commit;
    logic [63:0] reciprocal_issue, reciprocal_result, reciprocal_commit;
    logic [63:0] staged_weight_accept, weight_wr_accept;
    logic [63:0] row_commit_count, slot_release_count;
    logic [63:0] protocol_error_count, numeric_error_count;
    logic [63:0] output_stall_cycles;
    logic [63:0] owner_error_count, mask_error_count;
    logic error_sticky;

    logic [15:0] expected_epoch [0:2];
    logic [4:0] expected_head [0:2];
    logic [6:0] expected_row [0:2];
    logic [31:0] expected_sum [0:2];
    logic [31:0] expected_inv [0:2];
    integer expected_key [0:2];
    integer writes_per_slot [0:2];
    integer commits_per_slot [0:2];
    integer total_writes = 0;
    integer total_commits = 0;
    logic random_backpressure = 0;
    logic [31:0] lfsr = 32'hc0ffee12;
    logic hold_weight = 0;
    logic [75:0] held_weight;
    logic hold_commit = 0;
    logic [98:0] held_commit;

    cats_r4_b2_compatibility_v3_wrapper #(
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);

    task automatic send_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot
    );
        begin
            @(negedge clk);
            row_epoch = epoch;
            row_group = head[4:2];
            row_global_q_head = head;
            row_index = row_id;
            row_slot_id = slot;
            row_numeric_mode = 0;
            row_max_bf16 = 16'h3f80;
            row_valid = 1;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 0;
            expected_epoch[slot] = epoch;
            expected_head[slot] = head;
            expected_row[slot] = row_id;
            expected_key[slot] = 0;
            writes_per_slot[slot] = 0;
            case (row_id)
                0: begin
                    expected_sum[slot] = 32'h3f800000;
                    expected_inv[slot] = 32'h3f800000;
                end
                1: begin
                    expected_sum[slot] = 32'h40000000;
                    expected_inv[slot] = 32'h3f000000;
                end
                3: begin
                    expected_sum[slot] = 32'h40800000;
                    expected_inv[slot] = 32'h3e800000;
                end
                default: $fatal(1, "unexpected test row");
            endcase
        end
    endtask

    task automatic send_score(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot,
        input logic [6:0] key
    );
        begin
            @(negedge clk);
            score_epoch = epoch;
            score_group = head[4:2];
            score_global_q_head = head;
            score_row = row_id;
            score_slot_id = slot;
            score_numeric_mode = 0;
            score_key = key;
            score_bf16 = 16'h3f80;
            score_last = key == row_id;
            score_valid = 1;
            do @(posedge clk); while (!score_ready);
            @(negedge clk);
            score_valid = 0;
        end
    endtask

    task automatic release_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] slot
    );
        begin
            @(negedge clk);
            slot_release_epoch = epoch;
            slot_release_group = head[4:2];
            slot_release_global_q_head = head;
            slot_release_row = row_id;
            slot_release_slot_id = slot;
            slot_release_numeric_mode = 0;
            slot_release_valid = 1;
            do @(posedge clk); while (!slot_release_ready);
            @(negedge clk);
            slot_release_valid = 0;
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n || clear) begin
            lfsr <= 32'hc0ffee12;
        end else if (random_backpressure) begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            weight_wr_ready <= lfsr[0] || lfsr[2];
            row_commit_ready <= lfsr[4] || lfsr[7];
        end
    end

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            hold_weight <= 0;
            hold_commit <= 0;
        end else begin
            if (hold_weight &&
                {weight_wr_epoch,weight_wr_group,
                 weight_wr_global_q_head,weight_wr_row,
                 weight_wr_slot_id,weight_wr_numeric_mode,
                 weight_wr_key,weight_wr_mask,weight_wr_data,
                 weight_wr_last} !== held_weight)
                $fatal(1, "Compatibility V3 weight changed while stalled");
            if (hold_commit &&
                {row_commit_epoch,row_commit_group,
                 row_commit_global_q_head,row_commit_row,
                 row_commit_slot_id,row_commit_numeric_mode,
                 row_commit_sum_fp32,row_commit_inv_sum_fp32} !== held_commit)
                $fatal(1, "Compatibility V3 commit changed while stalled");
            hold_weight <= weight_wr_valid && !weight_wr_ready;
            if (weight_wr_valid && !weight_wr_ready)
                held_weight <= {weight_wr_epoch,weight_wr_group,
                    weight_wr_global_q_head,weight_wr_row,
                    weight_wr_slot_id,weight_wr_numeric_mode,
                    weight_wr_key,weight_wr_mask,weight_wr_data,
                    weight_wr_last};
            hold_commit <= row_commit_valid && !row_commit_ready;
            if (row_commit_valid && !row_commit_ready)
                held_commit <= {row_commit_epoch,row_commit_group,
                    row_commit_global_q_head,row_commit_row,
                    row_commit_slot_id,row_commit_numeric_mode,
                    row_commit_sum_fp32,row_commit_inv_sum_fp32};
        end

        if (rst_n && !clear && weight_wr_valid && weight_wr_ready) begin
            if (weight_wr_epoch !== expected_epoch[weight_wr_slot_id] ||
                weight_wr_group !== expected_head[weight_wr_slot_id][4:2] ||
                weight_wr_global_q_head !== expected_head[weight_wr_slot_id] ||
                weight_wr_row !== expected_row[weight_wr_slot_id] ||
                weight_wr_numeric_mode !== 0 ||
                weight_wr_key !== expected_key[weight_wr_slot_id] ||
                weight_wr_mask !==
                    (weight_wr_key > expected_row[weight_wr_slot_id]) ||
                weight_wr_last !== (weight_wr_key == 127))
                $fatal(1, "Compatibility V3 weight metadata mismatch");
            if (weight_wr_mask) begin
                if (weight_wr_data !== 0)
                    $fatal(1, "Compatibility masked weight was not zero");
            end else if (weight_wr_data !== 32'h00003f80) begin
                $fatal(1, "Compatibility BF16 payload placement mismatch");
            end
            expected_key[weight_wr_slot_id] =
                expected_key[weight_wr_slot_id] + 1;
            writes_per_slot[weight_wr_slot_id] =
                writes_per_slot[weight_wr_slot_id] + 1;
            total_writes = total_writes + 1;
        end

        if (rst_n && !clear && row_commit_valid && row_commit_ready) begin
            if (writes_per_slot[row_commit_slot_id] != 128 ||
                row_commit_epoch !== expected_epoch[row_commit_slot_id] ||
                row_commit_group !== expected_head[row_commit_slot_id][4:2] ||
                row_commit_global_q_head !== expected_head[row_commit_slot_id] ||
                row_commit_row !== expected_row[row_commit_slot_id] ||
                row_commit_numeric_mode !== 0 ||
                row_commit_sum_fp32 !== expected_sum[row_commit_slot_id] ||
                row_commit_inv_sum_fp32 !== expected_inv[row_commit_slot_id])
                $fatal(1, "Compatibility V3 commit mismatch");
            commits_per_slot[row_commit_slot_id] =
                commits_per_slot[row_commit_slot_id] + 1;
            total_commits = total_commits + 1;
        end
    end

    initial begin
        row_valid = 0;
        row_epoch = 0;
        row_group = 0;
        row_global_q_head = 0;
        row_index = 0;
        row_slot_id = 0;
        row_numeric_mode = 0;
        row_max_bf16 = 0;
        score_valid = 0;
        score_epoch = 0;
        score_group = 0;
        score_global_q_head = 0;
        score_row = 0;
        score_slot_id = 0;
        score_numeric_mode = 0;
        score_key = 0;
        score_bf16 = 0;
        score_last = 0;
        weight_wr_ready = 0;
        row_commit_ready = 0;
        row_error_ready = 1;
        slot_release_valid = 0;
        slot_release_epoch = 0;
        slot_release_group = 0;
        slot_release_global_q_head = 0;
        slot_release_row = 0;
        slot_release_slot_id = 0;
        slot_release_numeric_mode = 0;
        for (integer init_index = 0; init_index < 3;
             init_index = init_index + 1) begin
            expected_epoch[init_index] = 0;
            expected_head[init_index] = 0;
            expected_row[init_index] = 0;
            expected_sum[init_index] = 0;
            expected_inv[init_index] = 0;
            expected_key[init_index] = 0;
            writes_per_slot[init_index] = 0;
            commits_per_slot[init_index] = 0;
        end

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // This mode-specific wrapper must never silently run Accuracy input as
        // Compatibility.  The common transaction wrapper will own the reject
        // counter once Accuracy RTL is present.
        @(negedge clk);
        row_epoch = 16'hc200;
        row_group = 0;
        row_global_q_head = 0;
        row_index = 0;
        row_slot_id = 0;
        row_numeric_mode = 1;
        row_max_bf16 = 16'h3f80;
        row_valid = 1;
        repeat (3) begin
            @(posedge clk);
            if (row_ready)
                $fatal(1, "Compatibility wrapper accepted Accuracy row");
        end
        @(negedge clk);
        row_valid = 0;
        row_numeric_mode = 0;
        if (rows_issue != 0)
            $fatal(1, "unsupported mode reached Compatibility arithmetic");

        // Complete three rows while C is stalled.  No row may publish until
        // its divider result has finalized into the staging slot.
        send_row(16'hc201, 0, 0, 0);
        send_score(16'hc201, 0, 0, 0, 0);
        wait (reciprocal_commit == 1);
        send_row(16'hc201, 1, 1, 1);
        send_score(16'hc201, 1, 1, 1, 0);
        send_score(16'hc201, 1, 1, 1, 1);
        wait (reciprocal_commit == 2);
        send_row(16'hc201, 2, 3, 2);
        send_score(16'hc201, 2, 3, 2, 0);
        send_score(16'hc201, 2, 3, 2, 1);
        send_score(16'hc201, 2, 3, 2, 2);
        send_score(16'hc201, 2, 3, 2, 3);
        wait (reciprocal_commit == 3);
        repeat (3) @(posedge clk);
        if (!weight_wr_valid || weight_wr_accept != 0 ||
            row_commit_count != 0)
            $fatal(1, "staging did not hold the complete rows before C");

        random_backpressure = 1;
        wait (row_commit_count == 3);
        repeat (3) @(posedge clk);
        if (rows_issue != 3 || rows_result != 3 ||
            exp_issue != 7 || exp_result != 7 || exp_commit != 7 ||
            sum_issue != 7 || sum_result != 7 || sum_commit != 7 ||
            reciprocal_issue != 3 || reciprocal_result != 3 ||
            reciprocal_commit != 3 || staged_weight_accept != 7 ||
            weight_wr_accept != 384 || total_writes != 384 ||
            total_commits != 3 || protocol_error_count != 0 ||
            numeric_error_count != 0 || owner_error_count != 0 ||
            mask_error_count != 0 || error_sticky || row_error_valid ||
            output_stall_cycles == 0)
            $fatal(1, "Compatibility V3 counter closure mismatch");

        release_row(16'hc201, 0, 0, 0);
        release_row(16'hc201, 1, 1, 1);
        release_row(16'hc201, 2, 3, 2);
        if (slot_release_count != 3)
            $fatal(1, "Compatibility V3 release closure mismatch");

        $display("PASS: CATS-R4 B2 Compatibility V3 staged rows=%0d exp=%0d staged=%0d weight_wr=%0d commits=%0d releases=%0d",
                 rows_issue, exp_commit, staged_weight_accept,
                 weight_wr_accept, row_commit_count, slot_release_count);
        $finish;
    end
endmodule
