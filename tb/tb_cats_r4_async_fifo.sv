`timescale 1ns/1ps

module tb_cats_r4_async_fifo;
    logic wr_clk = 1'b0, rd_clk = 1'b0;
    always #3 wr_clk = ~wr_clk;
    always #5 rd_clk = ~rd_clk;
    logic wr_rst_n = 1'b0, rd_rst_n = 1'b0;
    logic wr_en, rd_en;
    logic [15:0] wr_data, rd_data;
    logic wr_full, rd_empty;
    logic [3:0] wr_level, rd_level;
    integer i;

    cats_r4_async_fifo #(.DATA_WIDTH(16), .ADDR_WIDTH(3)) dut (
        .wr_clk, .wr_rst_n, .wr_en, .wr_data, .wr_full, .wr_level,
        .rd_clk, .rd_rst_n, .rd_en, .rd_data, .rd_empty, .rd_level
    );

    initial begin
        wr_en = 1'b0;
        rd_en = 1'b0;
        wr_data = '0;
        repeat (3) @(posedge wr_clk);
        wr_rst_n = 1'b1;
        rd_rst_n = 1'b1;
        // Drive one write per rising write-clock edge with blocking assignments
        // so the acceptance edge is unambiguous in a four-state simulator.
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge wr_clk);
            wr_en = 1'b1;
            wr_data = 16'h1000 + i;
        end
        @(negedge wr_clk);
        wr_en = 1'b0;
        // Allow the synchronized write pointer to reach the read domain.
        repeat (5) @(posedge rd_clk);
        for (i = 0; i < 8; i = i + 1) begin
            if (rd_empty) repeat (3) @(posedge rd_clk);
            if (rd_empty) $fatal(1, "FIFO unexpectedly empty at item %0d", i);
            rd_en = 1'b1;
            @(posedge rd_clk); #1;
            if (rd_data !== (16'h1000 + i))
                $fatal(1, "FIFO order mismatch item %0d got %h", i, rd_data);
            rd_en = 1'b0;
        end
        repeat (4) @(posedge rd_clk);
        if (!rd_empty) $fatal(1, "FIFO did not drain");
        $display("CATS-R4 async FIFO test: PASS");
        $finish;
    end
endmodule
