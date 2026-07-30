`timescale 1ns/1ps

module tb_qk_dot_product_one;

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

reg [15:0] q_mem    [0:127];
reg [15:0] k_mem    [0:127];
reg [15:0] gold_mem [0:0];

reg [15:0] actual_bf16;
reg [31:0] actual_fp32;

integer i;
integer diff;

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

// 超时保护：2 ms 内没有完成就打印内部状态并退出。
initial begin
    #2000000;

    $display("========================================");
    $display("[TIMEOUT] dot product did not finish");
    $display("state              = %0d", dut.state);
    $display("cnt                = %0d", dut.cnt);
    $display("acc_fp32           = %h", dut.acc_fp32);
    $display("scaled_fp32        = %h", dut.scaled_fp32);
    $display("score_fp32_debug   = %h", score_fp32_debug);
    $display("score_bf16         = %h", score_bf16);
    $display("out_valid          = %b", out_valid);
    $display("out_ready          = %b", out_ready);
    $display("========================================");

    $finish;
end

initial begin
    // 这里保持你当前已经能正常读取的路径。
    $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_vec.hex", q_mem);
    $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/k_vec.hex", k_mem);
    $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/gold_one.hex", gold_mem);

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
        $display("[FILE ERROR] HEX file was not loaded correctly.");
        $finish;
    end

    rst_n       = 1'b0;
    start       = 1'b0;
    in_valid    = 1'b0;
    q_data      = 16'h0000;
    k_data      = 16'h0000;

    // 关键修改：
    // 在 testbench 真正看到 out_valid 之前，out_ready 必须保持为 0。
    // 这样 DUT 会把 out_valid 和输出数据保持住，不会产生一拍脉冲后被错过。
    out_ready   = 1'b0;

    actual_bf16 = 16'h0000;
    actual_fp32 = 32'h00000000;

    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1;

    repeat (5) @(posedge clk);

    // 启动一次 128 维点积
    @(posedge clk);
    #1 start = 1'b1;

    @(posedge clk);
    #1 start = 1'b0;

    // 依次发送 128 对 BF16 Q/K 数据
    for (i = 0; i < 128; i = i + 1) begin
        @(posedge clk);
        #1;
        q_data   = q_mem[i];
        k_data   = k_mem[i];
        in_valid = 1'b1;

        while (in_ready !== 1'b1) begin
            @(posedge clk);
            #1;
        end

        // 保持到发生一次 valid && ready 传输
        @(posedge clk);
        #1;
        in_valid = 1'b0;
    end

    // 因为 out_ready=0，DUT 会稳定停在 S_OUT，并保持 out_valid=1。
    wait (out_valid === 1'b1);
    #1;

    actual_bf16 = score_bf16;
    actual_fp32 = score_fp32_debug;
    diff        = abs_diff16(actual_bf16, gold_mem[0]);

    $display("========================================");
    $display("Single dot product test: h=0,row=0,col=0");
    $display("gold_bf16   = %h", gold_mem[0]);
    $display("rtl_bf16    = %h", actual_bf16);
    $display("rtl_fp32dbg = %h", actual_fp32);
    $display("diff_ulp    = %0d", diff);

    if (diff <= 2)
        $display("[PASS]");
    else
        $display("[FAIL]");

    $display("========================================");

    // 比较完成后再允许 DUT 消费输出。
    @(posedge clk);
    #1 out_ready = 1'b1;

    @(posedge clk);
    #1 out_ready = 1'b0;

    #50;
    $finish;
end

endmodule