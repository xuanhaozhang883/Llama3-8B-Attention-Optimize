`timescale 1ns/1ps

module tb_qk_dot_product_many;

parameter HEADS       = 4;
parameter SEQ         = 128;
parameter DIM         = 128;
parameter MAX_TESTS   = 16;  // 第一轮先测16个连续score
parameter TOL_ULP     = 3;
parameter TIMEOUT_NS  = 5000000; // 5 ms，足够16/64点测试

reg clk;
reg rst_n;
reg start;
wire busy;

reg         in_valid;
wire        in_ready;
reg [15:0]  q_data;
reg [15:0]  k_data;

wire        out_valid;
reg         out_ready;
wire [15:0] score_bf16;
wire [31:0] score_fp32_debug;

reg [15:0] q_mem    [0:HEADS*SEQ*DIM-1];
reg [15:0] k_mem    [0:SEQ*DIM-1];
reg [15:0] gold_mem [0:HEADS*SEQ*SEQ-1];

reg [15:0] actual_bf16;
reg [31:0] actual_fp32;

integer t;
integer d;
integer h;
integer row;
integer col;
integer q_idx;
integer k_idx;
integer gold_idx;
integer diff;
integer pass_cnt;
integer fail_cnt;

initial clk = 1'b0;
always #5 clk = ~clk;

qk_dot_product_bf16_serial dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (start),
    .busy             (busy),
    .in_valid         (in_valid),
    .in_ready         (in_ready),
    .q_data           (q_data),
    .k_data           (k_data),
    .out_valid        (out_valid),
    .out_ready        (out_ready),
    .score_bf16       (score_bf16),
    .score_fp32_debug (score_fp32_debug)
);

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

task run_one_score;
    input integer ih;
    input integer irow;
    input integer icol;
    begin
        // 开始前确认上一次运算已经完全返回IDLE
        while (busy !== 1'b0) begin
            @(posedge clk);
            #1;
        end

        // start拉高一个完整时钟周期
        @(posedge clk);
        #1 start = 1'b1;

        @(posedge clk);
        #1 start = 1'b0;

        // 喂入一个128维Q向量和一个128维K向量
        for (d = 0; d < DIM; d = d + 1) begin
            q_idx = ih * SEQ * DIM + irow * DIM + d;
            k_idx = icol * DIM + d;

            @(posedge clk);
            #1;
            q_data   = q_mem[q_idx];
            k_data   = k_mem[k_idx];
            in_valid = 1'b1;

            // 数据保持不变，直到发生一次valid/ready握手
            while (in_ready !== 1'b1) begin
                @(posedge clk);
                #1;
            end

            @(posedge clk);
            #1 in_valid = 1'b0;
        end

        // out_ready保持为0，因此DUT必须保持out_valid和输出数据
        wait (out_valid === 1'b1);
        #1;

        actual_bf16 = score_bf16;
        actual_fp32 = score_fp32_debug;

        gold_idx = ih * SEQ * SEQ + irow * SEQ + icol;
        diff = abs_diff16(actual_bf16, gold_mem[gold_idx]);

        if (diff <= TOL_ULP) begin
            pass_cnt = pass_cnt + 1;
            $display(
                "[PASS] h=%0d row=%0d col=%0d gold=%h rtl=%h diff=%0d",
                ih, irow, icol, gold_mem[gold_idx], actual_bf16, diff
            );
        end else begin
            fail_cnt = fail_cnt + 1;
            $display(
                "[FAIL] h=%0d row=%0d col=%0d gold=%h rtl=%h diff=%0d fp32=%h",
                ih, irow, icol, gold_mem[gold_idx],
                actual_bf16, diff, actual_fp32
            );
        end

        // 比较完以后再消费输出，防止漏掉out_valid
        @(posedge clk);
        #1 out_ready = 1'b1;

        @(posedge clk);
        #1 out_ready = 1'b0;
    end
endtask

// 全局超时保护
initial begin
    #(TIMEOUT_NS);
    $display("========================================");
    $display("[TIMEOUT] many-score test did not finish");
    $display("tested=%0d pass=%0d fail=%0d", t, pass_cnt, fail_cnt);
    $display("state=%0d cnt=%0d busy=%b out_valid=%b",
             dut.state, dut.cnt, busy, out_valid);
    $display("========================================");
    $finish;
end

initial begin
    // 使用你当前已经验证能正常读取的路径
    $readmemh(
        "D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_after_rope.hex",
        q_mem
    );
    $readmemh(
        "D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/k_after_rope.hex",
        k_mem
    );
    $readmemh(
        "D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/scores_before_mask.hex",
        gold_mem
    );

    #1;
    $display("========================================");
    $display("HEX FILE CHECK");
    $display("q_mem[0]    = %h", q_mem[0]);
    $display("k_mem[0]    = %h", k_mem[0]);
    $display("gold_mem[0] = %h", gold_mem[0]);
    $display("========================================");

    if ((^q_mem[0] === 1'bx) ||
        (^k_mem[0] === 1'bx) ||
        (^gold_mem[0] === 1'bx)) begin
        $display("[FILE ERROR] HEX files were not loaded correctly.");
        $finish;
    end

    rst_n       = 1'b0;
    start       = 1'b0;
    in_valid    = 1'b0;
    q_data      = 16'h0000;
    k_data      = 16'h0000;

    // 关键：先不接收输出，让DUT保持out_valid
    out_ready   = 1'b0;

    actual_bf16 = 16'h0000;
    actual_fp32 = 32'h00000000;
    pass_cnt    = 0;
    fail_cnt    = 0;

    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1;

    repeat (5) @(posedge clk);

    // 第一轮：连续测试score[0][0][0:MAX_TESTS-1]
    for (t = 0; t < MAX_TESTS; t = t + 1) begin
        h   = t / (SEQ * SEQ);
        row = (t / SEQ) % SEQ;
        col = t % SEQ;
        run_one_score(h, row, col);
    end

    $display("========================================");
    $display("Total tested = %0d", MAX_TESTS);
    $display("PASS         = %0d", pass_cnt);
    $display("FAIL         = %0d", fail_cnt);

    if (fail_cnt == 0)
        $display("[PASS] many-score test passed");
    else
        $display("[FAIL] many-score test failed");

    $display("========================================");

    #50;
    $finish;
end

endmodule
