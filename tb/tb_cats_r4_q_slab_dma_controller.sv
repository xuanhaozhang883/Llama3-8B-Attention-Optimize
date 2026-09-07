`timescale 1ns/1ps

module tb_cats_r4_q_slab_dma_controller;
    localparam int TAG_W = 12;
    localparam logic [63:0] Q_BASE = 64'h0000_0000_5000_0000;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic counter_clear = 1'b0;
    logic start_valid = 1'b0;
    logic start_ready;
    logic [15:0] start_epoch = '0;
    logic [63:0] start_q_base = '0;

    logic q_fill_valid = 1'b0;
    logic q_fill_ready;
    logic q_fill_buffer = 1'b0;
    logic [15:0] q_fill_epoch = '0;
    logic [2:0] q_fill_group = '0;
    logic [4:0] q_fill_global_q_head = '0;
    logic [2:0] q_fill_row_window = '0;

    logic q_publish_valid;
    logic q_publish_ready = 1'b0;
    logic q_publish_buffer;
    logic [15:0] q_publish_epoch;
    logic [2:0] q_publish_group;
    logic [4:0] q_publish_global_q_head;
    logic [2:0] q_publish_row_window;

    logic dma_desc_valid;
    logic dma_desc_ready;
    logic [63:0] dma_desc_addr;
    logic [31:0] dma_desc_byte_count;
    logic [TAG_W-1:0] dma_desc_tag;
    logic [15:0] dma_desc_epoch;

    logic dma_cpl_valid = 1'b0;
    logic dma_cpl_ready;
    logic [TAG_W-1:0] dma_cpl_tag = '0;
    logic [15:0] dma_cpl_epoch = '0;
    logic dma_cpl_error = 1'b0;

    logic running;
    logic transaction_done;
    logic halted;
    logic error_sticky;
    logic [63:0] q_slab_desc_count;
    logic [63:0] q_slab_completion_count;
    logic [63:0] q_slab_publish_count;
    logic [63:0] q_slab_byte_count;
    logic [63:0] q_slab_beat_count;
    logic [63:0] q_slab_burst_count;
    logic [63:0] q_slab_desc_wait_cycles;
    logic [63:0] q_slab_publish_wait_cycles;
    logic [63:0] q_slab_tag_errors;
    logic [63:0] q_slab_epoch_errors;
    logic [63:0] protocol_errors;
    logic [63:0] dma_errors;

    cats_r4_q_slab_dma_controller #(
        .DMA_TAG_W(TAG_W)
    ) dut (.*);

    logic desc_gate = 1'b0;
    logic split_in_valid;
    logic split_in_ready;
    logic burst_valid;
    logic burst_ready = 1'b0;
    logic [63:0] burst_addr;
    logic [7:0] burst_axi_len;
    logic [8:0] burst_beats;
    logic [11:0] burst_byte_count;
    logic [TAG_W-1:0] burst_tag;
    logic burst_last;
    logic split_busy;
    logic split_error;
    logic [31:0] split_inputs;
    logic [31:0] split_bursts;
    logic [31:0] split_errors;
    logic [63:0] split_beats;

    assign split_in_valid = dma_desc_valid && desc_gate;
    assign dma_desc_ready = split_in_ready && desc_gate;

    cats_r4_axi_burst_splitter #(
        .TAG_W(TAG_W)
    ) splitter (
        .clk,
        .rst_n,
        .clear(1'b0),
        .in_valid(split_in_valid),
        .in_ready(split_in_ready),
        .in_addr(dma_desc_addr),
        .in_byte_count(dma_desc_byte_count),
        .in_tag(dma_desc_tag),
        .out_valid(burst_valid),
        .out_ready(burst_ready),
        .out_addr(burst_addr),
        .out_axi_len(burst_axi_len),
        .out_beats(burst_beats),
        .out_byte_count(burst_byte_count),
        .out_tag(burst_tag),
        .out_last(burst_last),
        .busy(split_busy),
        .protocol_error(split_error),
        .input_desc_count(split_inputs),
        .burst_desc_count(split_bursts),
        .error_count(split_errors),
        .emitted_beat_count(split_beats)
    );

    logic desc_stalled = 1'b0;
    logic [63:0] stalled_desc_addr;
    logic [31:0] stalled_desc_bytes;
    logic [TAG_W-1:0] stalled_desc_tag;
    logic [15:0] stalled_desc_epoch;
    logic publish_stalled = 1'b0;
    logic stalled_publish_buffer;
    logic [15:0] stalled_publish_epoch;
    logic [2:0] stalled_publish_group;
    logic [4:0] stalled_publish_head;
    logic [2:0] stalled_publish_window;
    integer desc_seen = 0;
    integer publish_seen = 0;
    integer bursts_seen = 0;
    integer cycle_count = 0;
    logic [15:0] model_epoch = '0;

    task automatic fail(input string message);
        begin
            $display("FAIL: %s", message);
            $fatal(1);
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic start_run(input logic [15:0] epoch_value);
        begin
            @(negedge clk);
            start_epoch = epoch_value;
            start_q_base = Q_BASE;
            model_epoch = epoch_value;
            start_valid = 1'b1;
            #1;
            if (!start_ready)
                fail("start unexpectedly blocked");
            tick();
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    task automatic drive_fill(input integer ordinal,
                              input logic [15:0] epoch_value);
        integer head_value;
        integer window_value;
        integer target_bursts;
        logic buffer_value;
        logic [TAG_W-1:0] expected_tag;
        begin
            head_value = ordinal / 8;
            window_value = ordinal % 8;
            buffer_value = ordinal[0];
            expected_tag = {3'b001, buffer_value,
                            head_value[4:0], window_value[2:0]};

            @(negedge clk);
            q_fill_buffer = buffer_value;
            q_fill_epoch = epoch_value;
            q_fill_group = head_value[4:2];
            q_fill_global_q_head = head_value[4:0];
            q_fill_row_window = window_value[2:0];
            q_fill_valid = 1'b1;
            #1;
            while (!q_fill_ready) begin
                tick();
                @(negedge clk);
                #1;
            end
            tick();
            @(negedge clk);
            q_fill_valid = 1'b0;

            target_bursts = (ordinal + 1) * 2;
            while (bursts_seen < target_bursts)
                tick();
            repeat ($urandom_range(1, 7))
                tick();

            @(negedge clk);
            dma_cpl_tag = expected_tag;
            dma_cpl_epoch = epoch_value;
            dma_cpl_error = 1'b0;
            dma_cpl_valid = 1'b1;
            #1;
            if (!dma_cpl_ready)
                fail("matching completion not accepted");
            tick();
            @(negedge clk);
            dma_cpl_valid = 1'b0;

            while (q_slab_publish_count != ordinal + 1)
                tick();
        end
    endtask

    always @(negedge clk) begin
        if (rst_n) begin
            desc_gate = ($urandom_range(0, 3) != 0);
            burst_ready = ($urandom_range(0, 3) != 0);
            q_publish_ready = ($urandom_range(0, 2) != 0);
        end else begin
            desc_gate = 1'b0;
            burst_ready = 1'b0;
            q_publish_ready = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count = cycle_count + 1;

            if (dma_desc_valid && !dma_desc_ready) begin
                if (desc_stalled &&
                    ((dma_desc_addr != stalled_desc_addr) ||
                     (dma_desc_byte_count != stalled_desc_bytes) ||
                     (dma_desc_tag != stalled_desc_tag) ||
                     (dma_desc_epoch != stalled_desc_epoch)))
                    fail("descriptor changed under backpressure");
                desc_stalled = 1'b1;
                stalled_desc_addr = dma_desc_addr;
                stalled_desc_bytes = dma_desc_byte_count;
                stalled_desc_tag = dma_desc_tag;
                stalled_desc_epoch = dma_desc_epoch;
            end else begin
                desc_stalled = 1'b0;
            end

            if (q_publish_valid && !q_publish_ready) begin
                if (publish_stalled &&
                    ((q_publish_buffer != stalled_publish_buffer) ||
                     (q_publish_epoch != stalled_publish_epoch) ||
                     (q_publish_group != stalled_publish_group) ||
                     (q_publish_global_q_head != stalled_publish_head) ||
                     (q_publish_row_window != stalled_publish_window)))
                    fail("publish token changed under backpressure");
                publish_stalled = 1'b1;
                stalled_publish_buffer = q_publish_buffer;
                stalled_publish_epoch = q_publish_epoch;
                stalled_publish_group = q_publish_group;
                stalled_publish_head = q_publish_global_q_head;
                stalled_publish_window = q_publish_row_window;
            end else begin
                publish_stalled = 1'b0;
            end

            if (dma_desc_valid && dma_desc_ready) begin
                if (dma_desc_epoch != model_epoch ||
                    dma_desc_byte_count != 32'd4096)
                    fail("descriptor epoch/length mismatch");
                if (dma_desc_addr != Q_BASE +
                    ({59'd0, dma_desc_tag[7:3]} << 15) +
                    ({61'd0, dma_desc_tag[2:0]} << 12))
                    fail("Q slab address mismatch");
                if (dma_desc_tag[11:9] != 3'b001)
                    fail("Q descriptor tag prefix mismatch");
                desc_seen = desc_seen + 1;
            end

            if (burst_valid && burst_ready) begin
                if ((burst_beats != 9'd256) ||
                    (burst_axi_len != 8'd255) ||
                    (burst_byte_count != 12'd2048))
                    fail("Q slab burst is not 256 beats");
                if (({1'b0, burst_addr[11:0]} +
                     {1'b0, burst_byte_count}) > 13'd4096)
                    fail("Q slab burst crossed 4 KiB boundary");
                bursts_seen = bursts_seen + 1;
                if (burst_last != !bursts_seen[0])
                    fail("Q slab burst-last cadence mismatch");
            end

            if (q_publish_valid && q_publish_ready) begin
                if ({q_publish_global_q_head, q_publish_row_window} !=
                    publish_seen[7:0])
                    fail("publish order mismatch");
                if (q_publish_group !=
                    q_publish_global_q_head[4:2])
                    fail("publish group/head mismatch");
                publish_seen = publish_seen + 1;
            end
        end
    end

    integer n;
    initial begin
        repeat (4) tick();
        rst_n = 1'b1;
        tick();
        start_run(16'h55aa);

        for (n = 0; n < 256; n = n + 1)
            drive_fill(n, 16'h55aa);

        tick();
        if (!transaction_done)
            fail("full-workload done pulse missing");
        if (running || halted || error_sticky)
            fail("happy path did not close cleanly");
        if ((desc_seen != 256) || (publish_seen != 256) ||
            (bursts_seen != 512))
            fail("full-workload observed counts mismatch");
        if ((q_slab_desc_count != 256) ||
            (q_slab_completion_count != 256) ||
            (q_slab_publish_count != 256) ||
            (q_slab_byte_count != 64'd1048576) ||
            (q_slab_beat_count != 64'd131072) ||
            (q_slab_burst_count != 64'd512))
            fail("full-workload controller counters mismatch");
        if ((split_inputs != 256) || (split_bursts != 512) ||
            (split_beats != 64'd131072) || split_error || split_errors)
            fail("full-workload splitter counters mismatch");
        if (protocol_errors || dma_errors || q_slab_tag_errors ||
            q_slab_epoch_errors)
            fail("happy path error counters are nonzero");

        // Reset, then prove a held stale token counts once and that a
        // mismatched/error completion halts before publish.
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) tick();
        @(negedge clk);
        rst_n = 1'b1;
        desc_seen = 0;
        publish_seen = 0;
        bursts_seen = 0;
        desc_stalled = 1'b0;
        publish_stalled = 1'b0;
        tick();
        start_run(16'h6600);

        @(negedge clk);
        q_fill_buffer = 1'b0;
        q_fill_epoch = 16'h65ff;
        q_fill_group = 3'd0;
        q_fill_global_q_head = 5'd0;
        q_fill_row_window = 3'd0;
        q_fill_valid = 1'b1;
        repeat (3) begin
            #1;
            if (q_fill_ready)
                fail("stale q_fill accepted");
            tick();
            @(negedge clk);
        end
        q_fill_valid = 1'b0;
        tick();
        if ((protocol_errors != 1) || (q_slab_epoch_errors != 1))
            fail("held stale token accounting mismatch");

        @(negedge clk);
        q_fill_epoch = 16'h6600;
        q_fill_valid = 1'b1;
        #1;
        while (!q_fill_ready) begin
            tick();
            @(negedge clk);
            #1;
        end
        tick();
        @(negedge clk);
        q_fill_valid = 1'b0;
        while (split_bursts != 2)
            tick();
        repeat (2) tick();
        @(negedge clk);
        dma_cpl_tag = {3'b001, 1'b0, 5'd0, 3'd1};
        dma_cpl_epoch = 16'h6601;
        dma_cpl_error = 1'b1;
        dma_cpl_valid = 1'b1;
        #1;
        if (!dma_cpl_ready)
            fail("error completion not consumed");
        tick();
        @(negedge clk);
        dma_cpl_valid = 1'b0;
        dma_cpl_error = 1'b0;
        tick();
        if (!halted || running || !error_sticky || q_publish_valid)
            fail("mismatched DMA completion did not halt");
        if ((protocol_errors != 2) || (dma_errors != 1) ||
            (q_slab_tag_errors != 1) ||
            (q_slab_epoch_errors != 2))
            fail("completion error accounting mismatch");

        $display("PASS CATS_R4_IF_V2 Q DMA 256 descriptors/131072 beats/512 bursts");
        $finish;
    end
endmodule
