`timescale 1ns/1ps

module tb_pv_systolic_tile_4x4;

    localparam integer TILE       = 4;
    localparam integer REDUCE_LEN = 128;

    reg clk;
    reg rst_n;
    reg tile_start;
    wire tile_busy;
    wire tile_done;

    reg in_valid;
    wire in_ready;
    reg [63:0] p_rows_bf16;
    reg [63:0] v_cols_bf16;

    wire out_valid;
    reg out_ready;
    wire [15:0] out_context_bf16;
    wire [1:0] out_local_row;
    wire [1:0] out_local_col;
    wire out_last;
    wire [31:0] out_context_fp32_debug;

    reg [15:0] p_mem    [0:4*128*128-1];
    reg [15:0] v_mem    [0:128*128-1];
    reg [15:0] gold_mem [0:4*128*128-1];

    integer reduce_index;
    integer lane;
    integer seen_count;
    integer pass_count;
    integer fail_count;
    integer gold_index;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    pv_systolic_tile #(
        .TILE       (TILE),
        .REDUCE_LEN (REDUCE_LEN)
    ) dut (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .tile_start                (tile_start),
        .tile_busy                 (tile_busy),
        .tile_done                 (tile_done),
        .in_valid                  (in_valid),
        .in_ready                  (in_ready),
        .p_rows_bf16               (p_rows_bf16),
        .v_cols_bf16               (v_cols_bf16),
        .out_valid                 (out_valid),
        .out_ready                 (out_ready),
        .out_context_bf16          (out_context_bf16),
        .out_local_row             (out_local_row),
        .out_local_col             (out_local_col),
        .out_last                  (out_last),
        .out_context_fp32_debug    (out_context_fp32_debug)
    );

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            gold_index = out_local_row*128 + out_local_col;
            seen_count = seen_count + 1;

            if (out_context_bf16 === gold_mem[gold_index]) begin
                pass_count = pass_count + 1;
                $display(
                    "[PASS] row=%0d col=%0d gold=%h rtl=%h",
                    out_local_row, out_local_col,
                    gold_mem[gold_index], out_context_bf16
                );
            end else begin
                fail_count = fail_count + 1;
                $display(
                    "[FAIL] row=%0d col=%0d gold=%h rtl=%h fp32=%h",
                    out_local_row, out_local_col,
                    gold_mem[gold_index], out_context_bf16,
                    out_context_fp32_debug
                );
            end
        end
    end

    initial begin
        $readmemh(
            "D:/pv_sim_data/softmax_weights_bf16.hex", p_mem
        );
        $readmemh(
            "D:/pv_sim_data/v_bf16.hex", v_mem
        );
        $readmemh(
            "D:/pv_sim_data/attn_out_per_head_bf16.hex",
            gold_mem
        );

        #1;
        $display("========================================");
        $display("PV TILE HEX CHECK");
        $display("P[0,0,0]    = %h", p_mem[0]);
        $display("V[0,0,0]    = %h", v_mem[0]);
        $display("Gold[0,0,0] = %h", gold_mem[0]);
        $display("========================================");

        rst_n       = 1'b0;
        tile_start  = 1'b0;
        in_valid    = 1'b0;
        p_rows_bf16 = 64'h0;
        v_cols_bf16 = 64'h0;
        out_ready   = 1'b1;
        seen_count  = 0;
        pass_count  = 0;
        fail_count  = 0;

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;

        repeat (5) @(posedge clk);

        @(posedge clk);
        #1 tile_start = 1'b1;
        @(posedge clk);
        #1 tile_start = 1'b0;

        for (reduce_index = 0;
             reduce_index < REDUCE_LEN;
             reduce_index = reduce_index + 1) begin

            // Drive data on the falling edge, then hold valid/data until the
            // next rising edge that sees in_ready=1. Deassert on a falling
            // edge so the same reduction item cannot be accepted twice.
            while (in_ready !== 1'b1)
                @(negedge clk);

            @(negedge clk);
            for (lane = 0; lane < TILE; lane = lane + 1) begin
                p_rows_bf16[lane*16 +: 16] =
                    p_mem[lane*128 + reduce_index];

                v_cols_bf16[lane*16 +: 16] =
                    v_mem[reduce_index*128 + lane];
            end
            in_valid = 1'b1;

            do begin
                @(posedge clk);
            end while (in_ready !== 1'b1);

            @(negedge clk);
            in_valid = 1'b0;
        end

        wait (tile_done === 1'b1);
        @(posedge clk);

        $display("========================================");
        $display("PV 4x4 tile test complete");
        $display("Expected = 16");
        $display("Seen     = %0d", seen_count);
        $display("PASS     = %0d", pass_count);
        $display("FAIL     = %0d", fail_count);

        if ((seen_count == 16) &&
            (pass_count == 16) &&
            (fail_count == 0))
            $display("[PASS] PV 4x4 tile");
        else
            $display("[FAIL] PV 4x4 tile");

        $display("========================================");
        #50;
        $finish;
    end

    initial begin
        #20000000;
        $display("[TIMEOUT] PV 4x4 tile did not finish.");
        $finish;
    end

endmodule
