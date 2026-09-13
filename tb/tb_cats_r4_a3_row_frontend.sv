`timescale 1ns/1ps

// Vendor-IP-only model for the frozen 1/sqrt(128) scale. The lookup values
// are IEEE-754 single-precision products rounded from the exact operation.
module fp32_mul_ip #(
    parameter integer IP_ID = 0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        a_valid,
    output logic        a_ready,
    input  logic [31:0] a_data,
    input  logic        b_valid,
    output logic        b_ready,
    input  logic [31:0] b_data,
    output logic        result_valid,
    input  logic        result_ready,
    output logic [31:0] result_data
);
    logic [31:0] scaled_lookup;
    always_comb begin
        case (a_data)
            32'h3f80_0000: scaled_lookup = 32'h3db5_04f3; // 1 * scale
            32'h4000_0000: scaled_lookup = 32'h3e35_04f3; // 2 * scale
            32'h4040_0000: scaled_lookup = 32'h3e87_c3b6; // 3 * scale
            32'h4100_0000: scaled_lookup = 32'h3f35_04f3; // 8 * scale
            default:       scaled_lookup = 32'hxxxx_xxxx;
        endcase
    end
    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result_data <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                if (b_data !== 32'h3db5_04f3)
                    $fatal(1, "A3 multiplier did not receive frozen scale");
                if ($isunknown(scaled_lookup))
                    $fatal(1, "A3 multiplier received unsupported raw input %08x",
                           a_data);
                result_data <= scaled_lookup;
                result_valid <= 1'b1;
            end
        end
    end
    logic unused_ip_id;
    assign unused_ip_id = IP_ID[0];
endmodule

module tb_cats_r4_a3_row_frontend;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, clear, counter_clear;
    logic txn_start_valid, txn_start_ready;
    logic [15:0] txn_epoch;
    logic [1:0] txn_numeric_mode;
    logic raw_score_valid, raw_score_ready;
    logic [15:0] raw_score_epoch;
    logic [2:0] raw_score_group;
    logic [4:0] raw_score_global_q_head;
    logic [6:0] raw_score_row;
    logic [1:0] raw_score_key_block;
    logic [3:0] raw_score_context_tag;
    logic [31:0] raw_score_lane_valid;
    logic [1023:0] raw_score_fp32;
    logic b_row_valid, b_row_ready;
    logic [15:0] b_row_epoch;
    logic [2:0] b_row_group;
    logic [4:0] b_row_global_q_head;
    logic [6:0] b_row_index;
    logic [1:0] b_row_slot_id, b_row_numeric_mode;
    logic [15:0] b_row_max_bf16;
    logic b_score_valid, b_score_ready;
    logic [15:0] b_score_epoch;
    logic [2:0] b_score_group;
    logic [4:0] b_score_global_q_head;
    logic [6:0] b_score_row, b_score_key;
    logic [1:0] b_score_slot_id, b_score_numeric_mode;
    logic [15:0] b_score_bf16;
    logic b_score_last;
    logic final_release_valid, final_release_ready;
    logic [15:0] final_release_epoch;
    logic [2:0] final_release_group;
    logic [4:0] final_release_global_q_head;
    logic [6:0] final_release_row;
    logic [1:0] final_release_slot_id, final_release_numeric_mode;
    logic row_abort_valid, row_abort_ready;
    logic [15:0] row_abort_epoch;
    logic [2:0] row_abort_group;
    logic [4:0] row_abort_global_q_head;
    logic [6:0] row_abort_row, row_abort_error_key;
    logic [1:0] row_abort_slot_id, row_abort_numeric_mode;
    logic [2:0] row_abort_error_code;
    logic [5:0] slot_owner;
    logic [63:0] rows_completed, scores_transferred, rows_transferred;
    logic [63:0] aborts, owner_errors;
    logic [63:0] scale_requests_accepted, scale_products_completed;
    logic [63:0] score_format_transfers, formatter_protocol_errors;
    logic [63:0] score_write_vectors, score_write_scores;
    logic [63:0] score_read_requests, score_read_responses;
    logic [63:0] score_read_stall_cycles, score_memory_errors;
    logic [63:0] context_slot_errors;
    logic a2_protocol_error_sticky, score_memory_error_sticky;
    logic context_slot_error_sticky, protocol_error_sticky;

    logic [15:0] expected_max [0:2];
    integer expected_row_sequence;
    integer scores_seen_for_row;
    integer completed_score_rows;
    integer lane;
    logic [50:0] held_row_payload;
    logic [58:0] held_score_payload;
    logic [34:0] held_release_payload;
    logic [31:0] invalid_before_formats;
    logic [63:0] invalid_before_writes;

    cats_r4_a3_row_frontend dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .counter_clear(counter_clear),
        .txn_start_valid(txn_start_valid),
        .txn_start_ready(txn_start_ready),
        .txn_epoch(txn_epoch),
        .txn_numeric_mode(txn_numeric_mode),
        .raw_score_valid(raw_score_valid),
        .raw_score_ready(raw_score_ready),
        .raw_score_epoch(raw_score_epoch),
        .raw_score_group(raw_score_group),
        .raw_score_global_q_head(raw_score_global_q_head),
        .raw_score_row(raw_score_row),
        .raw_score_key_block(raw_score_key_block),
        .raw_score_context_tag(raw_score_context_tag),
        .raw_score_lane_valid(raw_score_lane_valid),
        .raw_score_fp32(raw_score_fp32),
        .b_row_valid(b_row_valid),
        .b_row_ready(b_row_ready),
        .b_row_epoch(b_row_epoch),
        .b_row_group(b_row_group),
        .b_row_global_q_head(b_row_global_q_head),
        .b_row_index(b_row_index),
        .b_row_slot_id(b_row_slot_id),
        .b_row_numeric_mode(b_row_numeric_mode),
        .b_row_max_bf16(b_row_max_bf16),
        .b_score_valid(b_score_valid),
        .b_score_ready(b_score_ready),
        .b_score_epoch(b_score_epoch),
        .b_score_group(b_score_group),
        .b_score_global_q_head(b_score_global_q_head),
        .b_score_row(b_score_row),
        .b_score_key(b_score_key),
        .b_score_slot_id(b_score_slot_id),
        .b_score_numeric_mode(b_score_numeric_mode),
        .b_score_bf16(b_score_bf16),
        .b_score_last(b_score_last),
        .final_release_valid(final_release_valid),
        .final_release_ready(final_release_ready),
        .final_release_epoch(final_release_epoch),
        .final_release_group(final_release_group),
        .final_release_global_q_head(final_release_global_q_head),
        .final_release_row(final_release_row),
        .final_release_slot_id(final_release_slot_id),
        .final_release_numeric_mode(final_release_numeric_mode),
        .row_abort_valid(row_abort_valid),
        .row_abort_ready(row_abort_ready),
        .row_abort_epoch(row_abort_epoch),
        .row_abort_group(row_abort_group),
        .row_abort_global_q_head(row_abort_global_q_head),
        .row_abort_row(row_abort_row),
        .row_abort_error_key(row_abort_error_key),
        .row_abort_slot_id(row_abort_slot_id),
        .row_abort_numeric_mode(row_abort_numeric_mode),
        .row_abort_error_code(row_abort_error_code),
        .slot_owner(slot_owner),
        .rows_completed(rows_completed),
        .scores_transferred(scores_transferred),
        .rows_transferred(rows_transferred),
        .aborts(aborts),
        .owner_errors(owner_errors),
        .scale_requests_accepted(scale_requests_accepted),
        .scale_products_completed(scale_products_completed),
        .score_format_transfers(score_format_transfers),
        .formatter_protocol_errors(formatter_protocol_errors),
        .score_write_vectors(score_write_vectors),
        .score_write_scores(score_write_scores),
        .score_read_requests(score_read_requests),
        .score_read_responses(score_read_responses),
        .score_read_stall_cycles(score_read_stall_cycles),
        .score_memory_errors(score_memory_errors),
        .context_slot_errors(context_slot_errors),
        .a2_protocol_error_sticky(a2_protocol_error_sticky),
        .score_memory_error_sticky(score_memory_error_sticky),
        .context_slot_error_sticky(context_slot_error_sticky),
        .protocol_error_sticky(protocol_error_sticky)
    );

    function automatic logic [31:0] fp32_for_small_int(input integer value);
        case (value)
            0: fp32_for_small_int = 32'h0000_0000;
            1: fp32_for_small_int = 32'h3f80_0000;
            2: fp32_for_small_int = 32'h4000_0000;
            3: fp32_for_small_int = 32'h4040_0000;
            8: fp32_for_small_int = 32'h4100_0000;
            default: fp32_for_small_int = 32'h3f80_0000;
        endcase
    endfunction

    function automatic logic [15:0] expected_score(input logic [6:0] row,
                                                     input logic [6:0] key);
        if (row == 7'd127 && key == 7'd127)
            expected_score = 16'h3f35;
        else if (row < 3) begin
            case (key)
                0: expected_score = 16'h3db5;
                1: expected_score = 16'h3e35;
                // 3*scale is 3e87_c3b6, so BF16 RNE increments 3e87.
                default: expected_score = 16'h3e88;
            endcase
        end
        else
            expected_score = 16'h3db5;
    endfunction

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic send_raw_block(input logic [6:0] row,
                                  input logic [3:0] slot,
                                  input logic [1:0] key_block);
        integer base;
        begin
            base = key_block * 32;
            @(negedge clk);
            raw_score_row = row;
            raw_score_context_tag = slot;
            raw_score_key_block = key_block;
            raw_score_lane_valid = '0;
            raw_score_fp32 = '0;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                if (base + lane <= row) begin
                    raw_score_lane_valid[lane] = 1'b1;
                    raw_score_fp32[lane*32 +: 32] =
                        fp32_for_small_int((row == 127 && base + lane == 127) ? 8 :
                                           (row < 3 ? base + lane + 1 : 1));
                end
            end
            @(negedge clk);
            raw_score_valid = 1'b1;
            while (raw_score_ready !== 1'b1) tick();
            tick();
            @(negedge clk);
            raw_score_valid = 1'b0;
        end
    endtask

    task automatic release_row(input logic [6:0] row, input logic [1:0] slot);
        begin
            @(negedge clk);
            final_release_row = row;
            final_release_slot_id = slot;
            final_release_valid = 1'b1;
            #1;
            if (final_release_ready !== 1'b1)
                $fatal(1, "matching final release rejected row=%0d slot=%0d", row, slot);
            tick();
            @(negedge clk);
            final_release_valid = 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst_n && !clear) begin
            if (row_abort_valid)
                $fatal(1, "unexpected A2 row abort code=%0d key=%0d",
                       row_abort_error_code, row_abort_error_key);
            if (b_row_valid && b_row_ready) begin
                if (b_row_index !== expected_row_sequence[6:0] &&
                    !(expected_row_sequence == 3 && b_row_index === 7'd127))
                    $fatal(1, "A3 frontend row order mismatch");
                if (b_row_slot_id !== (expected_row_sequence < 3 ?
                                       expected_row_sequence[1:0] : 2'd0))
                    $fatal(1, "A3 frontend row slot mismatch");
                if (b_row_max_bf16 !== expected_max[b_row_slot_id])
                    $fatal(1, "A3 frontend row max mismatch");
                scores_seen_for_row <= 0;
                expected_row_sequence <= expected_row_sequence + 1;
            end
            if (b_score_valid && b_score_ready) begin
                if (b_score_key !== scores_seen_for_row[6:0])
                    $fatal(1, "A3 frontend score order mismatch");
                if (b_score_last !== (b_score_key == b_score_row))
                    $fatal(1, "A3 frontend last mismatch");
                if (b_score_bf16 !== expected_score(b_score_row, b_score_key))
                    $fatal(1, "A3 frontend score data mismatch row=%0d key=%0d",
                           b_score_row, b_score_key);
                scores_seen_for_row <= scores_seen_for_row + 1;
                if (b_score_last)
                    completed_score_rows <= completed_score_rows + 1;
            end
        end
    end

    initial begin
        repeat (2000) tick();
        $fatal(1, "A3 frontend timeout rows=%0d scores=%0d owners=%h",
               rows_transferred, scores_transferred, slot_owner);
    end

    initial begin
        rst_n = 0; clear = 0; counter_clear = 0;
        txn_start_valid = 0; txn_epoch = 16'ha300; txn_numeric_mode = 1;
        raw_score_valid = 0; raw_score_epoch = 16'ha300; raw_score_group = 0;
        raw_score_global_q_head = 0; raw_score_row = 0;
        raw_score_key_block = 0; raw_score_context_tag = 0;
        raw_score_lane_valid = 0; raw_score_fp32 = 0;
        b_row_ready = 0; b_score_ready = 0;
        final_release_valid = 0; final_release_epoch = 16'ha300;
        final_release_group = 0; final_release_global_q_head = 0;
        final_release_row = 0; final_release_slot_id = 0;
        final_release_numeric_mode = 1; row_abort_ready = 1;
        expected_max[0] = 16'h3db5;
        expected_max[1] = 16'h3e35;
        expected_max[2] = 16'h3e88;
        expected_row_sequence = 0; scores_seen_for_row = 0;
        completed_score_rows = 0;

        repeat (3) tick();
        rst_n = 1;
        repeat (2) tick();
        @(negedge clk); txn_start_valid = 1;
        if (txn_start_ready !== 1'b1) $fatal(1, "transaction start rejected");
        tick();
        @(negedge clk); txn_start_valid = 0;

        // An invalid scheduler tag is one rejected episode, even if held.
        invalid_before_formats = scale_requests_accepted;
        invalid_before_writes = score_write_vectors;
        @(negedge clk); raw_score_context_tag = 4'd3; raw_score_valid = 1;
        repeat (3) begin
            #1;
            if (raw_score_ready !== 1'b0) $fatal(1, "tag3 advertised ready");
            tick();
            if (score_write_vectors !== invalid_before_writes)
                $fatal(1, "tag3 caused score-memory write");
        end
        @(negedge clk); raw_score_valid = 0;
        tick();
        if (context_slot_errors !== 1 || !context_slot_error_sticky ||
            scale_requests_accepted !== invalid_before_formats)
            $fatal(1, "invalid context episode accounting mismatch");

        // The frozen causal-row assembler ends rows 0, 1, and 2 in block 0;
        // only row 127 legally spans all four key blocks.
        send_raw_block(0, 0, 0);
        send_raw_block(1, 1, 0);
        send_raw_block(2, 2, 0);

        // Freeze the first row header independently.
        while (b_row_valid !== 1'b1) tick();
        held_row_payload = {b_row_epoch, b_row_group, b_row_global_q_head,
                            b_row_index, b_row_slot_id, b_row_numeric_mode,
                            b_row_max_bf16};
        repeat (3) begin
            tick();
            if (b_row_valid !== 1'b1 ||
                {b_row_epoch, b_row_group, b_row_global_q_head, b_row_index,
                 b_row_slot_id, b_row_numeric_mode, b_row_max_bf16} !== held_row_payload)
                $fatal(1, "A3 frontend row payload changed while stalled");
        end
        @(negedge clk); b_row_ready = 1;

        // Freeze the first score independently.
        while (b_score_valid !== 1'b1) tick();
        held_score_payload = {b_score_epoch, b_score_group, b_score_global_q_head,
                              b_score_row, b_score_key, b_score_slot_id,
                              b_score_numeric_mode, b_score_bf16, b_score_last};
        repeat (3) begin
            tick();
            if (b_score_valid !== 1'b1 ||
                {b_score_epoch, b_score_group, b_score_global_q_head,
                 b_score_row, b_score_key, b_score_slot_id,
                 b_score_numeric_mode, b_score_bf16, b_score_last} !== held_score_payload)
                $fatal(1, "A3 frontend score payload changed while stalled");
        end
        @(negedge clk); b_score_ready = 1;
        while (completed_score_rows < 3) tick();

        // A held nonmatching B4 release is rejected and its payload is stable.
        @(negedge clk);
        final_release_row = 7'd126;
        final_release_slot_id = 0;
        final_release_valid = 1;
        held_release_payload = {
            final_release_epoch,
            final_release_group,
            final_release_global_q_head,
            final_release_row,
            final_release_slot_id,
            final_release_numeric_mode
        };
        repeat (3) begin
            #1;
            if (final_release_ready !== 1'b0 ||
                {final_release_epoch,
                 final_release_group,
                 final_release_global_q_head,
                 final_release_row,
                 final_release_slot_id,
                 final_release_numeric_mode} !== held_release_payload)
                $fatal(1, "final release stall/payload mismatch");
            tick();
        end
        @(negedge clk); final_release_valid = 0;
        tick();

        // Slot 0 cannot open a replacement row until the matching release.
        send_raw_block(127, 0, 0);
        invalid_before_writes = score_write_vectors;
        repeat (4) begin
            tick();
            if (score_write_vectors !== invalid_before_writes)
                $fatal(1, "slot0 was reused before final release");
        end
        release_row(0, 0);
        while (score_write_vectors == invalid_before_writes) tick();
        release_row(1, 1);
        release_row(2, 2);
        expected_max[0] = 16'h3f35;
        send_raw_block(127, 0, 1);
        send_raw_block(127, 0, 2);
        send_raw_block(127, 0, 3);
        while (completed_score_rows < 4) tick();
        release_row(127, 0);

        if (rows_completed !== 4 || rows_transferred !== 4 ||
            scores_transferred !== 134 || score_write_vectors !== 7 ||
            score_write_scores !== 134 || score_read_requests !== 134 ||
            score_read_responses !== 134 || scale_requests_accepted !== 7 ||
            scale_products_completed !== 134 || score_format_transfers !== 7 ||
            formatter_protocol_errors !== 0 || score_memory_errors !== 0 ||
            aborts !== 0 || owner_errors !== 1 || slot_owner !== 0)
            $fatal(1, "A3 frontend final counter/owner mismatch");

        @(negedge clk); counter_clear = 1;
        tick();
        @(negedge clk); counter_clear = 0;
        tick();
        if (rows_completed !== 0 || scores_transferred !== 0 ||
            rows_transferred !== 0 || aborts !== 0 || owner_errors !== 0 ||
            scale_requests_accepted !== 0 || scale_products_completed !== 0 ||
            score_format_transfers !== 0 || formatter_protocol_errors !== 0 ||
            score_write_vectors !== 0 || score_write_scores !== 0 ||
            score_read_requests !== 0 || score_read_responses !== 0 ||
            score_read_stall_cycles !== 0 || score_memory_errors !== 0 ||
            context_slot_errors !== 0 || protocol_error_sticky !== 0)
            $fatal(1, "counter_clear did not clear frontend counters/stickies");

        @(negedge clk); clear = 1;
        tick();
        @(negedge clk); clear = 0;
        tick();
        if (slot_owner !== 0 || b_row_valid !== 0 || b_score_valid !== 0 ||
            row_abort_valid !== 0)
            $fatal(1, "clear did not reset frontend datapath");

        $display("PASS: CATS-R4 A3 row frontend physical slots, release gating, stalls, and counters");
        $finish;
    end
endmodule
