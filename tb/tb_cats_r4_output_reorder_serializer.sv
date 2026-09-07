`timescale 1ns/1ps

module tb_cats_r4_output_reorder_serializer;
    localparam int DEPTH = 4;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, counter_clear = 0;
    logic in_valid, in_ready;
    logic [1:0] in_cluster_id;
    logic [15:0] in_epoch;
    logic [4:0] in_global_q_head;
    logic [6:0] in_row;
    logic [1:0] in_feature_block;
    logic [511:0] in_data_bf16;
    logic in_row_last, in_tensor_last;
    logic out_valid, out_ready;
    logic [1:0] out_cluster_id;
    logic [15:0] out_epoch;
    logic [11:0] out_seq;
    logic [4:0] out_global_q_head;
    logic [6:0] out_row;
    logic [1:0] out_feature_block;
    logic [2:0] out_beat_in_chunk;
    logic [63:0] out_data;
    logic out_row_last, out_tensor_last;
    logic [$clog2(DEPTH+1)-1:0] occupancy;
    logic [63:0] chunks_accepted, chunks_committed, beats_committed;
    logic [63:0] duplicate_count, out_of_order_count, late_count;
    logic [63:0] gap_count, epoch_mismatch_count, last_mismatch_count;
    logic [63:0] cluster_mismatch_count;
    logic protocol_error_sticky;

    cats_r4_output_reorder_serializer #(.DEPTH(DEPTH)) dut (.*);

    task automatic fail(input string msg);
        begin $display("FAIL: %s", msg); $fatal(1); end
    endtask

    function automatic [511:0] payload(input logic [13:0] chunk);
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                payload[b*64 +: 64] = {46'd0, chunk, b[3:0]};
        end
    endfunction

    task automatic drive_chunk(
        input logic [13:0] chunk,
        input logic [15:0] epoch,
        input logic bad_last,
        output logic accepted
    );
        begin
            @(negedge clk);
            in_cluster_id = 0;
            in_epoch = epoch;
            in_global_q_head = chunk[13:9];
            in_row = chunk[8:2];
            in_feature_block = chunk[1:0];
            in_data_bf16 = payload(chunk);
            in_row_last = (chunk[1:0] == 3);
            in_tensor_last = (chunk == 14'h3fff);
            if (bad_last) in_row_last = !in_row_last;
            in_valid = 1;
            #1 accepted = in_ready;
            @(posedge clk); #1;
            @(negedge clk); in_valid = 0;
        end
    endtask

    task automatic consume_chunk(input logic [13:0] chunk);
        integer b;
        logic [63:0] held_data;
        logic [15:0] held_epoch;
        logic [511:0] expected_payload;
        begin
            expected_payload = payload(chunk);
            for (b = 0; b < 8; b = b + 1) begin
                while (!out_valid) begin @(posedge clk); #1; end
                if ({out_global_q_head,out_row,out_feature_block} != chunk)
                    fail("non-canonical chunk order");
                if (out_beat_in_chunk != b ||
                    out_data != expected_payload[b*64 +: 64])
                    fail("serialized beat mismatch");
                if (b == 2) begin
                    held_data = out_data; held_epoch = out_epoch;
                    out_ready = 0;
                    repeat (3) begin
                        @(posedge clk); #1;
                        if (!out_valid || out_data != held_data ||
                            out_epoch != held_epoch || out_beat_in_chunk != b)
                            fail("output changed under backpressure");
                    end
                    out_ready = 1;
                end
                @(posedge clk); #1;
            end
        end
    endtask

    logic accepted;
    initial begin
        in_valid = 0; in_cluster_id = 0; in_epoch = 0;
        in_global_q_head = 0; in_row = 0; in_feature_block = 0;
        in_data_bf16 = 0; in_row_last = 0; in_tensor_last = 0;
        out_ready = 0;
        repeat (3) begin @(posedge clk); #1; end
        rst_n = 1;
        @(posedge clk); #1;

        // Chunk 1 arrives first: it is retained and opens one gap episode.
        drive_chunk(14'd1, 16'h55aa, 0, accepted);
        if (!accepted) fail("future chunk not accepted");
        repeat (2) begin @(posedge clk); #1; end
        if (out_valid) fail("future chunk escaped before missing chunk");
        if (gap_count != 1 || out_of_order_count != 1)
            fail("gap/reorder counters mismatch");

        drive_chunk(14'd0, 16'h55aa, 0, accepted);
        if (!accepted) fail("expected chunk not accepted");
        out_ready = 1;
        consume_chunk(14'd0);

        // Duplicate chunk 1 is consumed as an error while original remains.
        out_ready = 0;
        drive_chunk(14'd1, 16'h55aa, 0, accepted);
        out_ready = 1;
        if (!accepted || duplicate_count != 1)
            fail("duplicate handling mismatch");
        consume_chunk(14'd1);

        drive_chunk(14'd2, 16'h55ab, 0, accepted);
        if (!accepted || epoch_mismatch_count != 1)
            fail("epoch mismatch handling failed");
        drive_chunk(14'd0, 16'h55aa, 0, accepted);
        if (!accepted || late_count != 1)
            fail("late chunk handling failed");

        drive_chunk(14'd2, 16'h55aa, 1, accepted);
        if (!accepted || last_mismatch_count != 1)
            fail("last mismatch handling failed");
        consume_chunk(14'd2);

        // Reserve-one policy: three future chunks occupy a DEPTH=4 queue;
        // another future chunk stalls, but missing expected chunk still fits.
        drive_chunk(14'd4, 16'h55aa, 0, accepted);
        if (!accepted) fail("chunk 4 not accepted");
        drive_chunk(14'd5, 16'h55aa, 0, accepted);
        if (!accepted) fail("chunk 5 not accepted");
        drive_chunk(14'd6, 16'h55aa, 0, accepted);
        if (!accepted) fail("chunk 6 not accepted");
        drive_chunk(14'd7, 16'h55aa, 0, accepted);
        if (accepted) fail("future input was not stalled at reserved-full");
        drive_chunk(14'd3, 16'h55aa, 0, accepted);
        if (!accepted || occupancy != DEPTH)
            fail("reserved expected slot unavailable");

        consume_chunk(14'd3);
        consume_chunk(14'd4);
        consume_chunk(14'd5);
        consume_chunk(14'd6);
        drive_chunk(14'd7, 16'h55aa, 0, accepted);
        if (!accepted) fail("stalled chunk not accepted after space");
        consume_chunk(14'd7);

        if (chunks_committed != 8 || beats_committed != 64 || occupancy != 0)
            fail("loss/commit accounting mismatch");
        if (!protocol_error_sticky)
            fail("protocol sticky flag missing");
        $display("PASS: output reorder/serializer canonical order, stalls, counters");
        $finish;
    end
endmodule
