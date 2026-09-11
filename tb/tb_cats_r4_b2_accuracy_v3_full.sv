`timescale 1ns/1ps

// Full-shape control/count regression for Accuracy mode.  Equal BF16 scores
// make every legal exp result exactly FP32 1.0, isolating causal row lengths,
// key-ordered sums, reciprocal metadata, whole-row staging, and 128-write
// scheme-A publication for all 32 heads x 128 rows.
module tb_cats_r4_b2_accuracy_v3_full;
`ifdef CATS_R4_COMPATIBILITY_FULL
    localparam logic [1:0] TEST_MODE = 2'd0;
`else
    localparam logic [1:0] TEST_MODE = 2'd1;
`endif
    localparam integer HEADS = 32;
    localparam integer ROWS_PER_HEAD = 128;
    localparam integer TOTAL_ROWS = HEADS * ROWS_PER_HEAD;
    localparam integer TOTAL_SCORES = HEADS * 8256;
    localparam integer TOTAL_WRITES = TOTAL_ROWS * 128;

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
    logic row_error_ready = 1;
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
    logic [2:0] slot_owned_state;
    logic [5:0] slot_mode_state;
    logic [63:0] mode_error_count;
    logic [63:0] weight_conflict_cycles;
    logic [63:0] finalize_conflict_cycles;
    logic [63:0] output_stall_cycles;
    logic [63:0] exp_stall_cycles;
    logic [63:0] sum_stall_cycles;
    logic [63:0] reciprocal_busy_stall_cycles;
    logic [63:0] reciprocal_output_stall_cycles;
    logic error_sticky;

    logic [79:0] row_metadata [0:TOTAL_ROWS-1];
`ifdef CATS_R4_STORED_VECTOR
    logic [47:0] score_vectors [0:TOTAL_SCORES-1];
`endif
    logic [31:0] sink_lfsr = 32'hB2F0_2026;
    logic [31:0] source_lfsr = 32'hA55A_1EAF;
    string metadata_path;
    integer cycle_count = 0;
    integer write_count = 0;
    integer commit_count = 0;
    integer error_count = 0;
    integer input_score_stalls = 0;
    integer input_score_cursor = 0;
    integer output_score_cursor = 0;

    always #5 clk = ~clk;

`ifdef CATS_R4_SHARED_INTEGRATION
    cats_r4_b2_shared_stager_v3_wrapper #(
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);
`else
    cats_r4_b2_accuracy_v3_wrapper dut (.*);
`endif

    initial begin
`ifdef CATS_R4_STORED_VECTOR
        string score_path;
        // Icarus keeps its command-line overrides; XSim on this Windows
        // installation requires relative defaults because its wrapper does
        // not preserve '=' payloads in --testplusarg.
        metadata_path = "rows.hex";
        score_path = "scores.hex";
        if ($value$plusargs("ROWS=%s", metadata_path)) begin end
        if ($value$plusargs("SCORES=%s", score_path)) begin end
        $readmemh(metadata_path, row_metadata);
        $readmemh(score_path, score_vectors);
`else
        metadata_path = "equal_row_metadata.hex";
        if ($value$plusargs("META=%s", metadata_path)) begin end
        $readmemh(metadata_path, row_metadata, 0, 127);
`endif
    end

    initial begin
        repeat (4000000) @(posedge clk);
        $fatal(1,
            "timeout cycles=%0d rows=%0d scores=%0d writes=%0d commits=%0d",
            cycle_count, rows_issue, exp_issue, write_count, commit_count);
    end

    always @(posedge clk) begin
        if (rst_n)
            cycle_count <= cycle_count + 1;
        if (rst_n && score_valid && !score_ready)
            input_score_stalls <= input_score_stalls + 1;
    end

    always @(negedge clk) begin
        if (rst_n) begin
            sink_lfsr = {sink_lfsr[30:0],
                sink_lfsr[31] ^ sink_lfsr[21] ^ sink_lfsr[1] ^ sink_lfsr[0]};
            weight_wr_ready = sink_lfsr[0] | sink_lfsr[3];
            row_commit_ready = sink_lfsr[1] | sink_lfsr[5];
            row_error_ready = sink_lfsr[2] | sink_lfsr[7];
        end
    end

    always @(posedge clk) begin
        integer block;
        integer key;
        integer expected_head;
        integer expected_row;
        integer expected_slot;
        if (rst_n && weight_wr_valid && weight_wr_ready) begin
            block = write_count / 128;
            key = write_count % 128;
            expected_head = block / 128;
            expected_row = block % 128;
            expected_slot = block % 3;
            if (block >= TOTAL_ROWS ||
                weight_wr_epoch != 16'hB200 ||
                weight_wr_group != (expected_head >> 2) ||
                weight_wr_global_q_head != expected_head ||
                weight_wr_row != expected_row ||
                weight_wr_slot_id != expected_slot ||
                weight_wr_numeric_mode != TEST_MODE ||
                weight_wr_key != key ||
                weight_wr_mask != (key > expected_row) ||
`ifdef CATS_R4_COMPATIBILITY_FULL
                weight_wr_data != ((key <= expected_row) ?
                    32'h00003F80 : 32'h00000000) ||
`elsif CATS_R4_STORED_VECTOR
                weight_wr_data != ((key <= expected_row) ?
                    score_vectors[output_score_cursor][31:0] :
                    32'h00000000) ||
`else
                weight_wr_data != ((key <= expected_row) ?
                    32'h3F800000 : 32'h00000000) ||
`endif
                weight_wr_last != (key == 127))
                $fatal(1,
                    "write mismatch n=%0d head=%0d row=%0d slot=%0d key=%0d mask=%0d data=%h last=%0d",
                    write_count, weight_wr_global_q_head, weight_wr_row,
                    weight_wr_slot_id, weight_wr_key, weight_wr_mask,
                    weight_wr_data, weight_wr_last);
`ifdef CATS_R4_STORED_VECTOR
            if (key <= expected_row)
                output_score_cursor = output_score_cursor + 1;
`endif
            write_count = write_count + 1;
        end

        if (rst_n && row_commit_valid && row_commit_ready) begin
            block = commit_count;
            expected_head = block / 128;
            expected_row = block % 128;
            expected_slot = block % 3;
            if (block >= TOTAL_ROWS ||
                row_commit_epoch != 16'hB200 ||
                row_commit_group != (expected_head >> 2) ||
                row_commit_global_q_head != expected_head ||
                row_commit_row != expected_row ||
                row_commit_slot_id != expected_slot ||
                row_commit_numeric_mode != TEST_MODE ||
`ifdef CATS_R4_STORED_VECTOR
                row_commit_sum_fp32 != row_metadata[block][63:32] ||
                row_commit_inv_sum_fp32 != row_metadata[block][31:0])
`else
                row_commit_sum_fp32 != row_metadata[expected_row][63:32] ||
                row_commit_inv_sum_fp32 != row_metadata[expected_row][31:0])
`endif
                $fatal(1,
                    "commit mismatch n=%0d head=%0d row=%0d slot=%0d sum=%h inv=%h expected=%h",
                    commit_count, row_commit_global_q_head, row_commit_row,
                    row_commit_slot_id, row_commit_sum_fp32,
                    row_commit_inv_sum_fp32,
`ifdef CATS_R4_STORED_VECTOR
                    row_metadata[block]);
`else
                    row_metadata[expected_row]);
`endif
            if (write_count != (commit_count + 1) * 128)
                $fatal(1, "row committed before 128 accepted writes");
            commit_count = commit_count + 1;
        end

        if (rst_n && row_error_valid && row_error_ready) begin
            error_count = error_count + 1;
            $fatal(1,
                "unexpected row error head=%0d row=%0d code=%0d bad_key=%0d",
                row_error_global_q_head, row_error_row,
                row_error_code, row_error_bad_key);
        end
    end

    task automatic source_gap;
        begin
            source_lfsr = {source_lfsr[30:0],
                source_lfsr[31] ^ source_lfsr[21] ^
                source_lfsr[1] ^ source_lfsr[0]};
            if (!(source_lfsr[0] | source_lfsr[4]))
                @(negedge clk);
        end
    endtask

    task automatic send_row(
        input integer head,
        input integer row,
        input integer slot
    );
        begin
            source_gap();
            @(negedge clk);
            row_valid = 1'b1;
            row_epoch = 16'hB200;
            row_group = head >> 2;
            row_global_q_head = head;
            row_index = row;
            row_slot_id = slot;
            row_numeric_mode = TEST_MODE;
`ifdef CATS_R4_STORED_VECTOR
            row_max_bf16 = row_metadata[head * ROWS_PER_HEAD + row][79:64];
`else
            row_max_bf16 = 16'h0000;
`endif
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 1'b0;
        end
    endtask

    task automatic send_score(
        input integer head,
        input integer row,
        input integer slot,
        input integer key
    );
        begin
            source_gap();
            @(negedge clk);
            score_valid = 1'b1;
            score_epoch = 16'hB200;
            score_group = head >> 2;
            score_global_q_head = head;
            score_row = row;
            score_slot_id = slot;
            score_numeric_mode = TEST_MODE;
            score_key = key;
`ifdef CATS_R4_STORED_VECTOR
            score_bf16 = score_vectors[input_score_cursor][47:32];
`else
            score_bf16 = 16'h0000;
`endif
            score_last = key == row;
            do @(posedge clk); while (!score_ready);
`ifdef CATS_R4_STORED_VECTOR
            input_score_cursor = input_score_cursor + 1;
`endif
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    task automatic send_release(
        input integer head,
        input integer row,
        input integer slot
    );
        begin
            @(negedge clk);
            slot_release_valid = 1'b1;
            slot_release_epoch = 16'hB200;
            slot_release_group = head >> 2;
            slot_release_global_q_head = head;
            slot_release_row = row;
            slot_release_slot_id = slot;
            slot_release_numeric_mode = TEST_MODE;
            do @(posedge clk); while (!slot_release_ready);
            @(negedge clk);
            slot_release_valid = 1'b0;
        end
    endtask

    initial begin
        integer head;
        integer row;
        integer key;
        integer block;
        integer slot;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (head = 0; head < HEADS; head = head + 1) begin
            for (row = 0; row < ROWS_PER_HEAD; row = row + 1) begin
                block = head * ROWS_PER_HEAD + row;
                slot = block % 3;
                send_row(head, row, slot);
                for (key = 0; key <= row; key = key + 1)
                    send_score(head, row, slot, key);
                while (commit_count < block + 1)
                    @(posedge clk);
                send_release(head, row, slot);
            end
        end

        repeat (8) @(posedge clk);
        if (write_count != TOTAL_WRITES || commit_count != TOTAL_ROWS ||
            error_count != 0)
            $fatal(1, "terminal output counts mismatch");
`ifdef CATS_R4_STORED_VECTOR
        if (input_score_cursor != TOTAL_SCORES ||
            output_score_cursor != TOTAL_SCORES)
            $fatal(1,
                "stored score vector cursors mismatch input=%0d output=%0d",
                input_score_cursor, output_score_cursor);
`endif
        if (rows_issue != TOTAL_ROWS || rows_result != TOTAL_ROWS ||
            exp_issue != TOTAL_SCORES || exp_result != TOTAL_SCORES ||
            exp_commit != TOTAL_SCORES || sum_issue != TOTAL_SCORES ||
            sum_result != TOTAL_SCORES || sum_commit != TOTAL_SCORES ||
            reciprocal_issue != TOTAL_ROWS ||
            reciprocal_result != TOTAL_ROWS ||
            reciprocal_commit != TOTAL_ROWS ||
            staged_weight_accept != TOTAL_SCORES ||
            weight_wr_accept != TOTAL_WRITES ||
            row_commit_count != TOTAL_ROWS ||
            slot_release_count != TOTAL_ROWS)
            $fatal(1,
                "counter mismatch rows=%0d/%0d exp=%0d/%0d/%0d sum=%0d/%0d/%0d reciprocal=%0d/%0d/%0d staged=%0d writes=%0d commits=%0d releases=%0d",
                rows_issue, rows_result, exp_issue, exp_result, exp_commit,
                sum_issue, sum_result, sum_commit, reciprocal_issue,
                reciprocal_result, reciprocal_commit, staged_weight_accept,
                weight_wr_accept, row_commit_count, slot_release_count);
        if (protocol_error_count != 0 || numeric_error_count != 0 ||
            owner_error_count != 0 || mask_error_count != 0 || error_sticky)
            $fatal(1,
                "unexpected errors protocol=%0d numeric=%0d owner=%0d mask=%0d sticky=%0d",
                protocol_error_count, numeric_error_count,
                owner_error_count, mask_error_count, error_sticky);

`ifdef CATS_R4_COMPATIBILITY_FULL
        $display(
            "CATS-R4 Compatibility shared V3 full-count PASS rows=%0d scores=%0d writes=%0d commits=%0d releases=%0d cycles=%0d input_score_stalls=%0d output_stalls=%0d",
            rows_issue, exp_issue, weight_wr_accept, row_commit_count,
            slot_release_count, cycle_count, input_score_stalls,
            output_stall_cycles);
`elsif CATS_R4_STORED_VECTOR
        $display(
            "CATS-R4 Accuracy V3 stored-full PASS rows=%0d scores=%0d writes=%0d commits=%0d releases=%0d cycles=%0d input_score_stalls=%0d output_stalls=%0d exp_stalls=%0d sum_stalls=%0d reciprocal_busy_stalls=%0d reciprocal_output_stalls=%0d",
`else
        $display(
            "CATS-R4 Accuracy V3 full-count PASS rows=%0d scores=%0d writes=%0d commits=%0d releases=%0d cycles=%0d input_score_stalls=%0d output_stalls=%0d exp_stalls=%0d sum_stalls=%0d reciprocal_busy_stalls=%0d reciprocal_output_stalls=%0d",
`endif
`ifndef CATS_R4_COMPATIBILITY_FULL
            rows_issue, exp_issue, weight_wr_accept, row_commit_count,
            slot_release_count, cycle_count, input_score_stalls,
            output_stall_cycles, exp_stall_cycles, sum_stall_cycles,
            reciprocal_busy_stall_cycles, reciprocal_output_stall_cycles);
`endif
        $finish;
    end
endmodule
