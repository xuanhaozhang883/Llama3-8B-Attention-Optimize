`timescale 1ns/1ps

module tb_cats_r4_qk_score_slot_mem;
    localparam integer LANES = 32;

    logic clk;
    logic rst_n;
    logic clear;
    logic counter_clear;

    logic store_wr_valid;
    logic store_wr_ready;
    logic [1:0] store_wr_slot_id;
    logic [6:0] store_wr_key_base;
    logic [LANES-1:0] store_wr_lane_valid;
    logic [LANES*16-1:0] store_wr_score_bf16;

    logic score_rd_req_valid;
    logic score_rd_req_ready;
    logic [15:0] score_rd_req_epoch;
    logic [2:0] score_rd_req_group;
    logic [4:0] score_rd_req_global_q_head;
    logic [6:0] score_rd_req_row;
    logic [6:0] score_rd_req_key;
    logic [1:0] score_rd_req_slot_id;
    logic [1:0] score_rd_req_numeric_mode;

    logic score_rd_rsp_valid;
    logic score_rd_rsp_ready;
    logic [15:0] score_rd_rsp_epoch;
    logic [2:0] score_rd_rsp_group;
    logic [4:0] score_rd_rsp_global_q_head;
    logic [6:0] score_rd_rsp_row;
    logic [6:0] score_rd_rsp_key;
    logic [1:0] score_rd_rsp_slot_id;
    logic [1:0] score_rd_rsp_numeric_mode;
    logic [15:0] score_rd_rsp_bf16;

    logic [63:0] write_vectors;
    logic [63:0] write_scores;
    logic [63:0] read_requests;
    logic [63:0] read_responses;
    logic [63:0] read_stall_cycles;
    logic [63:0] protocol_errors;
    logic protocol_error_sticky;

    integer lane;
    integer slot;
    integer key;
    integer key_base;
    integer expected_vectors;
    integer expected_scores;
    logic [57:0] stalled_payload;
    logic [63:0] before_write_vectors;
    logic [63:0] before_write_scores;
    logic [63:0] before_read_requests;
    logic [63:0] before_read_responses;
    logic [63:0] before_read_stalls;
    logic [63:0] before_protocol_errors;

    function automatic logic [15:0] expected_score(
        input logic [1:0] slot,
        input logic [6:0] key
    );
        expected_score = 16'h3c00 + {7'd0, slot, key};
    endfunction

    function automatic integer row_for_slot(input integer slot_index);
        case (slot_index)
            0: row_for_slot = 37;
            1: row_for_slot = 70;
            default: row_for_slot = 127;
        endcase
    endfunction

    cats_r4_qk_score_slot_mem #(
        .ASSERT_ON_PROTOCOL_ERROR(1'b0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .counter_clear(counter_clear),
        .store_wr_valid(store_wr_valid),
        .store_wr_ready(store_wr_ready),
        .store_wr_slot_id(store_wr_slot_id),
        .store_wr_key_base(store_wr_key_base),
        .store_wr_lane_valid(store_wr_lane_valid),
        .store_wr_score_bf16(store_wr_score_bf16),
        .score_rd_req_valid(score_rd_req_valid),
        .score_rd_req_ready(score_rd_req_ready),
        .score_rd_req_epoch(score_rd_req_epoch),
        .score_rd_req_group(score_rd_req_group),
        .score_rd_req_global_q_head(score_rd_req_global_q_head),
        .score_rd_req_row(score_rd_req_row),
        .score_rd_req_key(score_rd_req_key),
        .score_rd_req_slot_id(score_rd_req_slot_id),
        .score_rd_req_numeric_mode(score_rd_req_numeric_mode),
        .score_rd_rsp_valid(score_rd_rsp_valid),
        .score_rd_rsp_ready(score_rd_rsp_ready),
        .score_rd_rsp_epoch(score_rd_rsp_epoch),
        .score_rd_rsp_group(score_rd_rsp_group),
        .score_rd_rsp_global_q_head(score_rd_rsp_global_q_head),
        .score_rd_rsp_row(score_rd_rsp_row),
        .score_rd_rsp_key(score_rd_rsp_key),
        .score_rd_rsp_slot_id(score_rd_rsp_slot_id),
        .score_rd_rsp_numeric_mode(score_rd_rsp_numeric_mode),
        .score_rd_rsp_bf16(score_rd_rsp_bf16),
        .write_vectors(write_vectors),
        .write_scores(write_scores),
        .read_requests(read_requests),
        .read_responses(read_responses),
        .read_stall_cycles(read_stall_cycles),
        .protocol_errors(protocol_errors),
        .protocol_error_sticky(protocol_error_sticky)
    );

    always #5 clk = ~clk;

    task automatic pulse_counter_clear;
        begin
            @(negedge clk);
            counter_clear = 1'b1;
            @(posedge clk);
            @(negedge clk);
            counter_clear = 1'b0;
        end
    endtask

    task automatic write_block(
        input logic [1:0] wr_slot,
        input integer wr_base,
        input integer wr_row
    );
        integer wr_lane;
        begin
            @(negedge clk);
            store_wr_slot_id = wr_slot;
            store_wr_key_base = wr_base[6:0];
            for (wr_lane = 0; wr_lane < LANES; wr_lane = wr_lane + 1) begin
                store_wr_lane_valid[wr_lane] = wr_base + wr_lane <= wr_row;
                store_wr_score_bf16[wr_lane*16 +: 16] =
                    expected_score(wr_slot, (wr_base + wr_lane));
            end
            store_wr_valid = 1'b1;
            @(posedge clk);
            if (store_wr_ready !== 1'b1)
                $fatal(1, "aligned score write did not handshake");
            @(negedge clk);
            store_wr_valid = 1'b0;
        end
    endtask

    task automatic issue_read(
        input logic [1:0] rd_slot,
        input logic [6:0] rd_row,
        input logic [6:0] rd_key,
        input logic rd_ready
    );
        logic [15:0] exp_epoch;
        logic [2:0] exp_group;
        logic [4:0] exp_head;
        logic [1:0] exp_mode;
        begin
            exp_epoch = 16'h9000 | {7'd0, rd_slot, rd_key};
            exp_group = rd_slot + 1'b1;
            exp_head = {rd_slot, rd_key[2:0]};
            exp_mode = rd_key[1:0];
            @(negedge clk);
            score_rd_req_epoch = exp_epoch;
            score_rd_req_group = exp_group;
            score_rd_req_global_q_head = exp_head;
            score_rd_req_row = rd_row;
            score_rd_req_key = rd_key;
            score_rd_req_slot_id = rd_slot;
            score_rd_req_numeric_mode = exp_mode;
            score_rd_rsp_ready = rd_ready;
            score_rd_req_valid = 1'b1;
            @(posedge clk);
            if (score_rd_req_ready !== 1'b1)
                $fatal(1, "legal score read did not handshake");
            @(negedge clk);
            score_rd_req_valid = 1'b0;
            #1;
            if (score_rd_rsp_valid !== 1'b1 ||
                score_rd_rsp_epoch !== exp_epoch ||
                score_rd_rsp_group !== exp_group ||
                score_rd_rsp_global_q_head !== exp_head ||
                score_rd_rsp_row !== rd_row ||
                score_rd_rsp_key !== rd_key ||
                score_rd_rsp_slot_id !== rd_slot ||
                score_rd_rsp_numeric_mode !== exp_mode ||
                score_rd_rsp_bf16 !== expected_score(rd_slot, rd_key))
                $fatal(1, "score response payload mismatch slot=%0d key=%0d",
                       rd_slot, rd_key);
        end
    endtask

    task automatic consume_response;
        begin
            @(negedge clk);
            score_rd_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            score_rd_rsp_ready = 1'b0;
            #1;
            if (score_rd_rsp_valid !== 1'b0)
                $fatal(1, "score response did not retire");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        clear = 1'b0;
        counter_clear = 1'b0;
        store_wr_valid = 1'b0;
        store_wr_slot_id = 2'd0;
        store_wr_key_base = 7'd0;
        store_wr_lane_valid = '0;
        store_wr_score_bf16 = '0;
        score_rd_req_valid = 1'b0;
        score_rd_req_epoch = '0;
        score_rd_req_group = '0;
        score_rd_req_global_q_head = '0;
        score_rd_req_row = '0;
        score_rd_req_key = '0;
        score_rd_req_slot_id = '0;
        score_rd_req_numeric_mode = '0;
        score_rd_rsp_ready = 1'b0;

        // Frozen ready equations remain combinational during reset; sequential
        // reset priority prevents these presented operations from taking effect.
        store_wr_valid = 1'b1;
        score_rd_req_valid = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        store_wr_valid = 1'b0;
        score_rd_req_valid = 1'b0;
        rst_n = 1'b1;

        if (write_vectors !== 0 || write_scores !== 0 ||
            read_requests !== 0 || read_responses !== 0 ||
            read_stall_cycles !== 0 || protocol_errors !== 0 ||
            protocol_error_sticky !== 1'b0)
            $fatal(1, "reset-cycle attempts altered counters");

        // Assertions are disabled only for this negative-counter DUT instance.
        // The RTL parameter defaults to enabled for normal simulations.
        store_wr_slot_id = 2'd3;
        store_wr_key_base = 7'd0;
        store_wr_lane_valid = 32'd1;
        store_wr_score_bf16 = '0;
        store_wr_valid = 1'b1;
        #1;
        if (store_wr_ready !== 1'b0)
            $fatal(1, "invalid write slot advertised ready");
        @(posedge clk);
        @(negedge clk);
        store_wr_valid = 1'b0;
        #1;
        if (protocol_errors !== 1 || protocol_error_sticky !== 1'b1)
            $fatal(1, "invalid write slot error count mismatch");

        score_rd_req_slot_id = 2'd3;
        score_rd_req_valid = 1'b1;
        #1;
        if (score_rd_req_ready !== 1'b0)
            $fatal(1, "invalid read slot advertised ready");
        @(posedge clk);
        @(negedge clk);
        score_rd_req_valid = 1'b0;
        #1;
        if (protocol_errors !== 2 || protocol_error_sticky !== 1'b1)
            $fatal(1, "invalid read slot error count mismatch");

        // A misaligned, otherwise legal write is also rejected and counted.
        @(negedge clk);
        store_wr_slot_id = 2'd0;
        store_wr_key_base = 7'd1;
        store_wr_valid = 1'b1;
        #1;
        if (store_wr_ready)
            $fatal(1, "misaligned write advertised ready");
        @(posedge clk);
        @(negedge clk);
        store_wr_valid = 1'b0;
        #1;
        if (protocol_errors !== 3 || protocol_error_sticky !== 1'b1)
            $fatal(1, "misaligned write protocol error was not counted");

        // Prove clear drops a held response, holds counters, and does not alter
        // RAM payload despite the frozen ready equations remaining asserted.
        write_block(2'd2, 0, 0);
        issue_read(2'd2, 7'd0, 7'd0, 1'b0);
        stalled_payload = {score_rd_rsp_epoch, score_rd_rsp_group,
                           score_rd_rsp_global_q_head, score_rd_rsp_row,
                           score_rd_rsp_key, score_rd_rsp_slot_id,
                           score_rd_rsp_numeric_mode, score_rd_rsp_bf16};
        repeat (4) begin
            @(posedge clk);
            #1;
            if (score_rd_rsp_valid !== 1'b1 ||
                {score_rd_rsp_epoch, score_rd_rsp_group,
                 score_rd_rsp_global_q_head, score_rd_rsp_row,
                 score_rd_rsp_key, score_rd_rsp_slot_id,
                 score_rd_rsp_numeric_mode, score_rd_rsp_bf16} !== stalled_payload)
                $fatal(1, "held response changed during four-cycle stall");
        end
        if (read_stall_cycles !== 4)
            $fatal(1, "read stall counter=%0d expected=4", read_stall_cycles);
        before_write_vectors = write_vectors;
        before_write_scores = write_scores;
        before_read_requests = read_requests;
        before_read_responses = read_responses;
        before_read_stalls = read_stall_cycles;
        before_protocol_errors = protocol_errors;
        @(negedge clk);
        clear = 1'b1;
        store_wr_slot_id = 2'd2;
        store_wr_key_base = 7'd0;
        store_wr_lane_valid = 32'd1;
        store_wr_score_bf16 = '0;
        store_wr_score_bf16[15:0] = 16'hdead;
        store_wr_valid = 1'b1;
        score_rd_req_slot_id = 2'd2;
        score_rd_req_key = 7'd0;
        score_rd_req_valid = 1'b1;
        score_rd_rsp_ready = 1'b1;
        #1;
        if (store_wr_ready !== 1'b1 || score_rd_req_ready !== 1'b1)
            $fatal(1, "clear changed the frozen ready equations");
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        store_wr_valid = 1'b0;
        score_rd_req_valid = 1'b0;
        score_rd_rsp_ready = 1'b0;
        #1;
        if (score_rd_rsp_valid !== 1'b0)
            $fatal(1, "clear did not remove pending response");
        if (write_vectors !== before_write_vectors ||
            write_scores !== before_write_scores ||
            read_requests !== before_read_requests ||
            read_responses !== before_read_responses ||
            read_stall_cycles !== before_read_stalls ||
            protocol_errors !== before_protocol_errors)
            $fatal(1, "clear-cycle attempt altered counters");
        issue_read(2'd2, 7'd0, 7'd0, 1'b0);
        consume_response();

        // counter_clear has counter priority but does not suppress legal datapath
        // handshakes. Collide a write and read with it, then prove both payloads.
        @(negedge clk);
        counter_clear = 1'b1;
        store_wr_slot_id = 2'd1;
        store_wr_key_base = 7'd0;
        store_wr_lane_valid = 32'd1;
        store_wr_score_bf16 = '0;
        store_wr_score_bf16[15:0] = expected_score(2'd1, 7'd0);
        store_wr_valid = 1'b1;
        score_rd_req_epoch = 16'hc100;
        score_rd_req_group = 3'd2;
        score_rd_req_global_q_head = 5'h0a;
        score_rd_req_row = 7'd0;
        score_rd_req_key = 7'd0;
        score_rd_req_slot_id = 2'd2;
        score_rd_req_numeric_mode = 2'd1;
        score_rd_req_valid = 1'b1;
        #1;
        if (store_wr_ready !== 1'b1 || score_rd_req_ready !== 1'b1)
            $fatal(1, "counter_clear incorrectly suppressed datapath handshake");
        @(posedge clk);
        #1;
        if (score_rd_rsp_valid !== 1'b1 ||
            score_rd_rsp_epoch !== 16'hc100 ||
            score_rd_rsp_group !== 3'd2 ||
            score_rd_rsp_global_q_head !== 5'h0a ||
            score_rd_rsp_row !== 7'd0 || score_rd_rsp_key !== 7'd0 ||
            score_rd_rsp_slot_id !== 2'd2 ||
            score_rd_rsp_numeric_mode !== 2'd1 ||
            score_rd_rsp_bf16 !== expected_score(2'd2, 7'd0))
            $fatal(1, "counter_clear collision response mismatch");
        @(negedge clk);
        counter_clear = 1'b0;
        store_wr_valid = 1'b0;
        score_rd_req_valid = 1'b0;
        #1;
        if (write_vectors !== 0 || write_scores !== 0 ||
            read_requests !== 0 || read_responses !== 0 ||
            read_stall_cycles !== 0 || protocol_errors !== 0 ||
            protocol_error_sticky !== 1'b0)
            $fatal(1, "counter_clear collision did not clear counters");
        consume_response();
        issue_read(2'd1, 7'd0, 7'd0, 1'b0);
        consume_response();

        // Isolate the measured full-memory and concurrency phase.
        pulse_counter_clear();
        if (write_vectors !== 0 || write_scores !== 0 ||
            read_requests !== 0 || read_responses !== 0 ||
            read_stall_cycles !== 0 || protocol_errors !== 0 ||
            protocol_error_sticky !== 1'b0)
            $fatal(1, "counter_clear did not clear score-memory counters");

        expected_vectors = 0;
        expected_scores = 0;
        for (slot = 0; slot < 3; slot = slot + 1) begin
            for (key_base = 0; key_base <= row_for_slot(slot);
                 key_base = key_base + LANES) begin
                write_block(slot[1:0], key_base, row_for_slot(slot));
                expected_vectors = expected_vectors + 1;
                for (lane = 0; lane < LANES; lane = lane + 1)
                    if (key_base + lane <= row_for_slot(slot))
                        expected_scores = expected_scores + 1;
            end
        end

        // Consume the old response while accepting its replacement and a legal
        // vector write. Verify all three handshakes and exact counter deltas.
        issue_read(2'd0, 7'd37, 7'd0, 1'b0);
        score_rd_req_epoch = 16'ha101;
        score_rd_req_group = 3'd2;
        score_rd_req_global_q_head = 5'h11;
        score_rd_req_row = 7'd37;
        score_rd_req_key = 7'd1;
        score_rd_req_slot_id = 2'd0;
        score_rd_req_numeric_mode = 2'd1;
        score_rd_req_valid = 1'b1;
        score_rd_rsp_ready = 1'b1;
        store_wr_slot_id = 2'd0;
        store_wr_key_base = 7'd0;
        store_wr_lane_valid = '0;
        store_wr_lane_valid[31] = 1'b1;
        store_wr_score_bf16 = '0;
        store_wr_score_bf16[31*16 +: 16] = expected_score(2'd0, 7'd31);
        store_wr_valid = 1'b1;
        #1;
        if (score_rd_req_ready !== 1'b1 || store_wr_ready !== 1'b1)
            $fatal(1, "consume-and-replace collision was not ready");
        before_write_vectors = write_vectors;
        before_write_scores = write_scores;
        before_read_requests = read_requests;
        before_read_responses = read_responses;
        before_read_stalls = read_stall_cycles;
        @(posedge clk);
        #1;
        if (score_rd_rsp_valid !== 1'b1 ||
            score_rd_rsp_epoch !== 16'ha101 ||
            score_rd_rsp_group !== 3'd2 ||
            score_rd_rsp_global_q_head !== 5'h11 ||
            score_rd_rsp_row !== 7'd37 || score_rd_rsp_key !== 7'd1 ||
            score_rd_rsp_slot_id !== 2'd0 ||
            score_rd_rsp_numeric_mode !== 2'd1 ||
            score_rd_rsp_bf16 !== expected_score(2'd0, 7'd1))
            $fatal(1, "consume-and-replace response mismatch");
        if (write_vectors !== before_write_vectors + 1 ||
            write_scores !== before_write_scores + 1 ||
            read_requests !== before_read_requests + 1 ||
            read_responses !== before_read_responses + 1 ||
            read_stall_cycles !== before_read_stalls)
            $fatal(1, "simultaneous handshake counter delta mismatch");
        @(negedge clk);
        score_rd_req_valid = 1'b0;
        store_wr_valid = 1'b0;
        expected_vectors = expected_vectors + 1;
        expected_scores = expected_scores + 1;
        @(posedge clk);
        @(negedge clk);
        score_rd_rsp_ready = 1'b0;
        #1;
        if (score_rd_rsp_valid !== 1'b0)
            $fatal(1, "replacement response did not retire");

        // Reset counters after added directed coverage, then run the canonical
        // specified write/read scenario so its final totals remain frozen.
        pulse_counter_clear();
        expected_vectors = 0;
        expected_scores = 0;
        for (slot = 0; slot < 3; slot = slot + 1) begin
            for (key_base = 0; key_base <= row_for_slot(slot);
                 key_base = key_base + LANES) begin
                write_block(slot[1:0], key_base, row_for_slot(slot));
                expected_vectors = expected_vectors + 1;
                for (lane = 0; lane < LANES; lane = lane + 1)
                    if (key_base + lane <= row_for_slot(slot))
                        expected_scores = expected_scores + 1;
            end
        end

        for (slot = 0; slot < 3; slot = slot + 1)
            for (key = 0; key <= row_for_slot(slot); key = key + 1) begin
                issue_read(slot[1:0], row_for_slot(slot), key[6:0], 1'b0);
                consume_response();
            end

        if (write_vectors !== expected_vectors)
            $fatal(1, "write_vectors=%0d expected=%0d",
                   write_vectors, expected_vectors);
        if (write_scores !== expected_scores)
            $fatal(1, "write_scores=%0d expected=%0d",
                   write_scores, expected_scores);
        if (read_requests !== read_responses)
            $fatal(1, "read request/response counts differ: %0d/%0d",
                   read_requests, read_responses);
        if (read_requests !== (38 + 71 + 128))
            $fatal(1, "unexpected full-memory read count %0d", read_requests);
        if (protocol_errors !== 0 || protocol_error_sticky !== 1'b0)
            $fatal(1, "legal phase raised protocol error");

        $display("PASS: CATS-R4 three-slot score memory vectors=%0d scores=%0d reads=%0d stalls=%0d",
                 write_vectors, write_scores, read_responses, read_stall_cycles);
        $finish;
    end
endmodule
