`timescale 1ns/1ps

module tb_cats_r4_axi_burst_splitter;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [63:0] in_addr = '0;
    logic [31:0] in_byte_count = '0;
    logic [7:0] in_tag = '0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [63:0] out_addr;
    logic [7:0] out_axi_len;
    logic [8:0] out_beats;
    logic [11:0] out_byte_count;
    logic [7:0] out_tag;
    logic out_last;
    logic busy, protocol_error;
    logic [31:0] input_desc_count, burst_desc_count, error_count;
    logic [63:0] emitted_beat_count;

    cats_r4_axi_burst_splitter dut (.*);

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic submit(
        input logic [63:0] addr,
        input logic [31:0] bytes,
        input logic [7:0] tag
    );
        begin
            while (!in_ready) tick();
            in_addr = addr;
            in_byte_count = bytes;
            in_tag = tag;
            in_valid = 1'b1;
            tick();
            in_valid = 1'b0;
        end
    endtask

    task automatic expect_burst(
        input logic [63:0] addr,
        input integer beats,
        input logic [7:0] tag,
        input logic last
    );
        logic [63:0] held_addr;
        logic [7:0] held_len;
        logic [8:0] held_beats;
        logic [11:0] held_bytes;
        logic [7:0] held_tag;
        logic held_last;
        begin
            while (!out_valid) tick();
            if ((out_addr !== addr) || (out_beats !== beats) ||
                (out_axi_len !== beats-1) ||
                (out_byte_count !== beats*8) ||
                (out_tag !== tag) || (out_last !== last))
                $fatal(1, "burst mismatch addr=%h beats=%0d len=%0d bytes=%0d tag=%0d last=%0d",
                       out_addr, out_beats, out_axi_len, out_byte_count,
                       out_tag, out_last);
            if (({1'b0, out_addr[11:0]} +
                 {1'b0, out_byte_count}) > 13'd4096)
                $fatal(1, "burst crossed 4KiB boundary");
            held_addr=out_addr; held_len=out_axi_len; held_beats=out_beats;
            held_bytes=out_byte_count; held_tag=out_tag; held_last=out_last;
            repeat (3) begin
                out_ready = 1'b0;
                tick();
                if (!out_valid || out_addr!==held_addr || out_axi_len!==held_len ||
                    out_beats!==held_beats || out_byte_count!==held_bytes ||
                    out_tag!==held_tag || out_last!==held_last)
                    $fatal(1, "descriptor changed under backpressure");
            end
            out_ready = 1'b1;
            tick();
            out_ready = 1'b0;
        end
    endtask

    initial begin
        tick(); tick();
        rst_n = 1'b1;

        // 625 beats beginning one beat before a 4KiB boundary: 1,256,256,112.
        fork
            submit(64'h0000_0000_0000_0ff8, 32'd5000, 8'h31);
            begin
                expect_burst(64'h0ff8, 1,   8'h31, 1'b0);
                expect_burst(64'h1000, 256, 8'h31, 1'b0);
                expect_burst(64'h1800, 256, 8'h31, 1'b0);
                expect_burst(64'h2000, 112, 8'h31, 1'b1);
            end
        join

        // Exactly 4KiB still splits at the 2KiB/256-beat maximum.
        fork
            submit(64'h0000_0000_0000_4000, 32'd4096, 8'h52);
            begin
                expect_burst(64'h4000, 256, 8'h52, 1'b0);
                expect_burst(64'h4800, 256, 8'h52, 1'b1);
            end
        join

        // Invalid requests are consumed, counted, and never emit bursts.
        submit(64'h5004, 32'd8, 8'h61);
        submit(64'h5000, 32'd7, 8'h62);
        submit(64'h5000, 32'd0, 8'h63);
        repeat (4) tick();
        if (out_valid) $fatal(1, "invalid input emitted a burst");
        if (!protocol_error || error_count != 3)
            $fatal(1, "protocol error accounting mismatch: sticky=%0d count=%0d",
                   protocol_error, error_count);
        if (input_desc_count != 5 || burst_desc_count != 6 ||
            emitted_beat_count != 1137)
            $fatal(1, "counter mismatch inputs=%0d bursts=%0d beats=%0d",
                   input_desc_count, burst_desc_count, emitted_beat_count);

        $display("PASS cats_r4_axi_burst_splitter boundary/length/backpressure/error counters");
        $finish;
    end
endmodule
