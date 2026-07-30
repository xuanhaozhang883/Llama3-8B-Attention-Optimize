`timescale 1ns/1ps

module tb_qk_systolic_tile_4x4;

    localparam int TILE      = 4;
    localparam int HEAD_DIM  = 128;
    localparam int FULL_SEQ  = 128;

    logic clk;
    logic rst_n;
    logic tile_start;
    logic tile_busy;
    logic tile_done;

    logic                 in_valid;
    logic                 in_ready;
    logic [TILE*16-1:0]   q_rows_bf16;
    logic [TILE*16-1:0]   k_cols_bf16;

    logic                 out_valid;
    logic                 out_ready;
    logic [15:0]          out_score_bf16;
    logic [$clog2(TILE)-1:0] out_local_row;
    logic [$clog2(TILE)-1:0] out_local_col;
    logic                 out_last;
    logic [31:0]          out_score_fp32_debug;

    logic [15:0] q_mem    [0:4*FULL_SEQ*HEAD_DIM-1];
    logic [15:0] k_mem    [0:FULL_SEQ*HEAD_DIM-1];
    logic [15:0] gold_mem [0:4*FULL_SEQ*FULL_SEQ-1];

    integer d;
    integer lane;
    integer pass_count;
    integer fail_count;
    integer gold_index;
    integer diff;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function integer abs_diff16;
        input [15:0] a;
        input [15:0] b;
        integer ia;
        integer ib;
        begin
            ia = a;
            ib = b;
            abs_diff16 = (ia > ib) ? (ia - ib) : (ib - ia);
        end
    endfunction

    qk_systolic_tile #(
        .TILE     (TILE),
        .HEAD_DIM (HEAD_DIM)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .tile_start           (tile_start),
        .tile_busy            (tile_busy),
        .tile_done            (tile_done),
        .in_valid             (in_valid),
        .in_ready             (in_ready),
        .q_rows_bf16          (q_rows_bf16),
        .k_cols_bf16          (k_cols_bf16),
        .out_valid            (out_valid),
        .out_ready            (out_ready),
        .out_score_bf16       (out_score_bf16),
        .out_local_row        (out_local_row),
        .out_local_col        (out_local_col),
        .out_last             (out_last),
        .out_score_fp32_debug (out_score_fp32_debug)
    );

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            gold_index = out_local_row * FULL_SEQ + out_local_col;
            diff = abs_diff16(out_score_bf16, gold_mem[gold_index]);

            if (diff <= 3) begin
                pass_count = pass_count + 1;
                $display("[PASS] local_row=%0d local_col=%0d gold=%h rtl=%h diff=%0d",
                         out_local_row, out_local_col,
                         gold_mem[gold_index], out_score_bf16, diff);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] local_row=%0d local_col=%0d gold=%h rtl=%h diff=%0d fp32=%h",
                         out_local_row, out_local_col,
                         gold_mem[gold_index], out_score_bf16, diff,
                         out_score_fp32_debug);
            end
        end
    end

    initial begin
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_after_rope.hex", q_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/k_after_rope.hex", k_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/scores_before_mask.hex", gold_mem);

        rst_n        = 1'b0;
        tile_start   = 1'b0;
        in_valid     = 1'b0;
        q_rows_bf16  = '0;
        k_cols_bf16  = '0;
        out_ready    = 1'b1;
        pass_count   = 0;
        fail_count   = 0;

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        @(posedge clk);
        #1 tile_start = 1'b1;
        @(posedge clk);
        #1 tile_start = 1'b0;

        for (d = 0; d < HEAD_DIM; d = d + 1) begin
            for (lane = 0; lane < TILE; lane = lane + 1) begin
                q_rows_bf16[lane*16 +: 16] =
                    q_mem[lane*HEAD_DIM + d];
                k_cols_bf16[lane*16 +: 16] =
                    k_mem[lane*HEAD_DIM + d];
            end

            in_valid = 1'b1;
            while (in_ready !== 1'b1) begin
                @(posedge clk);
                #1;
            end

            @(posedge clk);
            #1 in_valid = 1'b0;
        end

        wait (tile_done === 1'b1);
        @(posedge clk);

        $display("========================================");
        $display("4x4 systolic tile test complete");
        $display("PASS = %0d", pass_count);
        $display("FAIL = %0d", fail_count);
        if ((pass_count == 16) && (fail_count == 0))
            $display("[PASS] 4x4 systolic tile");
        else
            $display("[FAIL] 4x4 systolic tile");
        $display("========================================");

        #50;
        $finish;
    end

    initial begin
        #20000000;
        $display("[TIMEOUT] 4x4 systolic tile did not finish");
        $finish;
    end

endmodule
