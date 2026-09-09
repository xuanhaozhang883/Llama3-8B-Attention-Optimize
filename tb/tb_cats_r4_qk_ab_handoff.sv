`timescale 1ns/1ps

module tb_cats_r4_qk_ab_handoff;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic in_row_valid, in_row_ready;
    logic [15:0] in_row_epoch;
    logic [2:0] in_row_group;
    logic [4:0] in_row_global_q_head;
    logic [6:0] in_row_index;
    logic [1:0] in_row_slot_id, in_row_numeric_mode;
    logic [15:0] in_row_max_bf16;

    logic score_rd_req_valid, score_rd_req_ready;
    logic [15:0] score_rd_req_epoch;
    logic [2:0] score_rd_req_group;
    logic [4:0] score_rd_req_global_q_head;
    logic [6:0] score_rd_req_row, score_rd_req_key;
    logic [1:0] score_rd_req_slot_id, score_rd_req_numeric_mode;
    logic score_rd_rsp_valid, score_rd_rsp_ready;
    logic [15:0] score_rd_rsp_epoch;
    logic [2:0] score_rd_rsp_group;
    logic [4:0] score_rd_rsp_global_q_head;
    logic [6:0] score_rd_rsp_row, score_rd_rsp_key;
    logic [1:0] score_rd_rsp_slot_id, score_rd_rsp_numeric_mode;
    logic [15:0] score_rd_rsp_bf16;

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
    logic [6:0] score_row, score_key;
    logic [1:0] score_slot_id, score_numeric_mode;
    logic [15:0] score_bf16;
    logic score_last;

    logic abort_valid, abort_ready;
    logic [15:0] abort_epoch;
    logic [2:0] abort_group;
    logic [4:0] abort_global_q_head;
    logic [6:0] abort_row;
    logic [1:0] abort_slot_id, abort_numeric_mode;
    logic [2:0] abort_error_code;
    logic [6:0] abort_error_key;
    logic [63:0] row_headers_transferred, score_reads_requested;
    logic [63:0] score_reads_returned, scores_transferred;
    logic [63:0] rows_transferred, protocol_errors, numeric_errors;
    logic protocol_error_sticky;

    cats_r4_qk_ab_handoff dut (.*);

    task automatic tick; @(posedge clk); #1; endtask

    logic rsp_pending;
    logic [6:0] pending_key;
    logic [15:0] pending_epoch;
    logic [2:0] pending_group;
    logic [4:0] pending_head;
    logic [6:0] pending_row;
    logic [1:0] pending_slot, pending_mode;
    logic inject_bad_key;
    logic inject_nonfinite;
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            rsp_pending <= 0;
            score_rd_rsp_valid <= 0;
        end else begin
            if (score_rd_rsp_valid && score_rd_rsp_ready)
                score_rd_rsp_valid <= 0;
            if (rsp_pending && (!score_rd_rsp_valid || score_rd_rsp_ready)) begin
                score_rd_rsp_valid <= 1;
                score_rd_rsp_epoch <= pending_epoch;
                score_rd_rsp_group <= pending_group;
                score_rd_rsp_global_q_head <= pending_head;
                score_rd_rsp_row <= pending_row;
                score_rd_rsp_slot_id <= pending_slot;
                score_rd_rsp_numeric_mode <= pending_mode;
                score_rd_rsp_key <= inject_bad_key ? pending_key + 1'b1 : pending_key;
                score_rd_rsp_bf16 <= inject_nonfinite ? 16'h7fc1 :
                                       16'h3f00 + pending_key;
                rsp_pending <= 0;
            end
            if (score_rd_req_valid && score_rd_req_ready) begin
                if (rsp_pending)
                    $fatal(1, "more than one storage request outstanding");
                rsp_pending <= 1;
                pending_key <= score_rd_req_key;
                pending_epoch <= score_rd_req_epoch;
                pending_group <= score_rd_req_group;
                pending_head <= score_rd_req_global_q_head;
                pending_row <= score_rd_req_row;
                pending_slot <= score_rd_req_slot_id;
                pending_mode <= score_rd_req_numeric_mode;
            end
        end
    end

    integer expected_key;
    integer full_head, full_row;
    integer expected_total_rows;
    integer row_wait_cycles;
    logic full_mode;
    logic [15:0] held_score;
    initial begin
        in_row_valid = 0;
        in_row_epoch = 16'h2202;
        in_row_group = 3'd1;
        in_row_global_q_head = 5'd6;
        in_row_index = 7'd7;
        in_row_slot_id = 2'd2;
        in_row_numeric_mode = 2'd1;
        in_row_max_bf16 = 16'h4000;
        score_rd_req_ready = 1;
        score_rd_rsp_valid = 0;
        row_ready = 0;
        score_ready = 0;
        abort_ready = 1;
        rsp_pending = 0;
        full_mode = 0;
        inject_bad_key = 0;
        inject_nonfinite = 0;

        repeat (3) tick();
        rst_n = 1;
        @(negedge clk); in_row_valid = 1;
        #1;
        if (!in_row_ready) $fatal(1, "handoff did not accept row descriptor");
        tick();
        @(negedge clk); in_row_valid = 0;

        if (!row_valid || score_rd_req_valid || score_valid)
            $fatal(1, "row header must be presented before score activity");
        repeat (3) begin
            tick();
            if (!row_valid || row_epoch !== 16'h2202 || row_index !== 7 ||
                row_slot_id !== 2 || row_max_bf16 !== 16'h4000 ||
                score_rd_req_valid || score_valid)
                $fatal(1, "row header changed or score started while header stalled");
        end

        row_ready = 1;
        tick();
        row_ready = 0;
        if (score_valid)
            $fatal(1, "first score appeared in same cycle as row header handshake");

        expected_key = 0;
        while (expected_key < 8) begin
            while (!score_valid) tick();
            if (score_key !== expected_key || score_row !== 7 ||
                score_epoch !== 16'h2202 || score_group !== 1 ||
                score_global_q_head !== 6 || score_slot_id !== 2 ||
                score_numeric_mode !== 1 ||
                score_bf16 !== (16'h3f00 + expected_key) ||
                score_last !== (expected_key == 7))
                $fatal(1, "score/token/order mismatch key=%0d got=%0d", expected_key, score_key);

            held_score = score_bf16;
            repeat (expected_key % 3) begin
                tick();
                if (!score_valid || score_key !== expected_key ||
                    score_bf16 !== held_score || score_last !== (expected_key == 7))
                    $fatal(1, "score changed under backpressure key=%0d", expected_key);
            end
            score_ready = 1;
            tick();
            score_ready = 0;
            expected_key = expected_key + 1;
        end

        if (row_headers_transferred !== 1 || score_reads_requested !== 8 ||
            score_reads_returned !== 8 || scores_transferred !== 8 ||
            rows_transferred !== 1 || protocol_errors !== 0 ||
            numeric_errors !== 0 || protocol_error_sticky || abort_valid)
            $fatal(1, "handoff counter/error mismatch");

        // A mismatched response must never reach B.  It is converted to a
        // backpressured row_abort carrying the offending key.
        inject_bad_key = 1;
        abort_ready = 0;
        @(negedge clk); in_row_valid = 1;
        #1;
        if (!in_row_ready) $fatal(1, "second descriptor not accepted");
        tick();
        @(negedge clk); in_row_valid = 0;
        row_ready = 1;
        tick();
        row_ready = 0;
        while (!abort_valid) begin
            if (score_valid)
                $fatal(1, "bad storage response leaked to B");
            tick();
        end
        if (abort_error_code !== 3'd1 || abort_error_key !== 1 ||
            abort_epoch !== 16'h2202 || abort_row !== 7 || abort_slot_id !== 2)
            $fatal(1, "protocol abort payload mismatch");
        repeat (2) begin
            tick();
            if (!abort_valid || abort_error_code !== 1 || abort_error_key !== 1)
                $fatal(1, "abort payload changed under backpressure");
        end
        abort_ready = 1;
        tick();
        if (protocol_errors !== 1 || !protocol_error_sticky ||
            scores_transferred !== 8 || rows_transferred !== 1)
            $fatal(1, "protocol abort counters mismatch");

        inject_bad_key = 0;
        inject_nonfinite = 1;
        abort_ready = 0;
        @(negedge clk); in_row_valid = 1;
        #1;
        if (!in_row_ready) $fatal(1, "numeric-error descriptor not accepted");
        tick();
        @(negedge clk); in_row_valid = 0;
        row_ready = 1;
        tick();
        row_ready = 0;
        while (!abort_valid) begin
            if (score_valid)
                $fatal(1, "non-finite score leaked to B");
            tick();
        end
        if (abort_error_code !== 3'd2 || abort_error_key !== 0)
            $fatal(1, "numeric abort payload mismatch");
        abort_ready = 1;
        tick();
        if (numeric_errors !== 1 || protocol_errors !== 1 ||
            scores_transferred !== 8 || rows_transferred !== 1)
            $fatal(1, "numeric abort counters mismatch");

        // Full A2 logical workload: 32 query heads x 128 causal rows.
        inject_nonfinite = 0;
        row_ready = 1;
        score_ready = 1;
        counter_clear = 1;
        tick();
        counter_clear = 0;
        full_mode = 1;
        expected_total_rows = 0;
        $display("PROGRESS: full workload started");
        for (full_head = 0; full_head < 32; full_head = full_head + 1) begin
            for (full_row = 0; full_row < 128; full_row = full_row + 1) begin
                @(negedge clk);
                in_row_epoch = 16'h6606;
                in_row_group = full_head >> 2;
                in_row_global_q_head = full_head;
                in_row_index = full_row;
                in_row_slot_id = full_row % 3;
                in_row_numeric_mode = 1;
                in_row_max_bf16 = 16'h3f00 + full_row;
                in_row_valid = 1;
                #1;
                if (!in_row_ready) $fatal(1, "full row descriptor stalled unexpectedly");
                tick();
                @(negedge clk); in_row_valid = 0;
                expected_total_rows = expected_total_rows + 1;
                row_wait_cycles = 0;
                while (rows_transferred != expected_total_rows) begin
                    tick();
                    row_wait_cycles = row_wait_cycles + 1;
                    if (row_wait_cycles > 1024)
                        $fatal(1,"full workload stuck head=%0d row=%0d state=%0d key=%0d rows=%0d",
                               full_head,full_row,dut.state,dut.next_key,rows_transferred);
                end
                if ((expected_total_rows % 512) == 0)
                    $display("PROGRESS: full rows=%0d scores=%0d", expected_total_rows,
                             scores_transferred);
            end
        end
        full_mode = 0;
        if (row_headers_transferred !== 4096 || rows_transferred !== 4096 ||
            scores_transferred !== 264192 || score_reads_requested !== 264192 ||
            score_reads_returned !== 264192 || protocol_errors !== 0 ||
            numeric_errors !== 0 || protocol_error_sticky || abort_valid)
            $fatal(1, "full workload closure mismatch rows=%0d scores=%0d req=%0d rsp=%0d",
                   rows_transferred, scores_transferred,
                   score_reads_requested, score_reads_returned);

        $display("PASS: CATS-R4 A-to-B full workload rows=4096 causal_scores=264192");
        $finish;
    end
endmodule
