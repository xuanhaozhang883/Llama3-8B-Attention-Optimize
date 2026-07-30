`timescale 1ns/1ps

module tb_qk_systolic_gqa_small;

    localparam int TILE      = 2;
    localparam int TEST_SEQ  = 4;
    localparam int HEAD_DIM  = 128;
    localparam int Q_HEADS   = 1;
    localparam int FULL_SEQ  = 128;
    localparam int HEAD_W    = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int SEQ_W     = (TEST_SEQ <= 1) ? 1 : $clog2(TEST_SEQ);

    logic clk;
    logic rst_n;
    logic start;
    logic busy;
    logic done;

    logic vec_ready;
    logic vec_valid;
    logic [TILE*16-1:0] q_vec_bf16;
    logic [TILE*16-1:0] k_vec_bf16;

    logic [HEAD_W-1:0] req_head;
    logic [SEQ_W-1:0] req_row_base;
    logic [SEQ_W-1:0] req_col_base;
    logic [$clog2(HEAD_DIM)-1:0] req_dim;

    logic score_valid;
    logic score_ready;
    logic [15:0] score_bf16;
    logic [31:0] score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [SEQ_W-1:0] score_row;
    logic [SEQ_W-1:0] score_col;
    logic score_last;

    logic [15:0] q_mem    [0:4*FULL_SEQ*HEAD_DIM-1];
    logic [15:0] k_mem    [0:FULL_SEQ*HEAD_DIM-1];
    logic [15:0] gold_mem [0:4*FULL_SEQ*FULL_SEQ-1];

    integer i;
    integer pass_count;
    integer fail_count;
    integer seen_count;
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

    qk_systolic_gqa_top #(
        .TILE     (TILE),
        .SEQ_LEN  (TEST_SEQ),
        .HEAD_DIM (HEAD_DIM),
        .Q_HEADS  (Q_HEADS)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .vec_ready          (vec_ready),
        .vec_valid          (vec_valid),
        .q_vec_bf16         (q_vec_bf16),
        .k_vec_bf16         (k_vec_bf16),
        .req_head           (req_head),
        .req_row_base       (req_row_base),
        .req_col_base       (req_col_base),
        .req_dim            (req_dim),
        .score_valid        (score_valid),
        .score_ready        (score_ready),
        .score_bf16         (score_bf16),
        .score_fp32_debug   (score_fp32_debug),
        .score_head         (score_head),
        .score_row          (score_row),
        .score_col          (score_col),
        .score_last         (score_last)
    );

    // Combinational vector loader driven by DUT request metadata.
    always_comb begin
        vec_valid   = rst_n && busy;
        q_vec_bf16  = '0;
        k_vec_bf16  = '0;

        for (i = 0; i < TILE; i = i + 1) begin
            q_vec_bf16[i*16 +: 16] =
                q_mem[req_head*FULL_SEQ*HEAD_DIM +
                      (req_row_base+i)*HEAD_DIM + req_dim];

            k_vec_bf16[i*16 +: 16] =
                k_mem[(req_col_base+i)*HEAD_DIM + req_dim];
        end
    end

    always @(posedge clk) begin
        if (rst_n && score_valid && score_ready) begin
            gold_index = score_head*FULL_SEQ*FULL_SEQ +
                         score_row*FULL_SEQ + score_col;
            diff = abs_diff16(score_bf16, gold_mem[gold_index]);
            seen_count = seen_count + 1;

            if (diff <= 3) begin
                pass_count = pass_count + 1;
                $display("[PASS] h=%0d row=%0d col=%0d gold=%h rtl=%h diff=%0d",
                         score_head, score_row, score_col,
                         gold_mem[gold_index], score_bf16, diff);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] h=%0d row=%0d col=%0d gold=%h rtl=%h diff=%0d fp32=%h",
                         score_head, score_row, score_col,
                         gold_mem[gold_index], score_bf16, diff,
                         score_fp32_debug);
            end
        end
    end

    initial begin
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_after_rope.hex", q_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/k_after_rope.hex", k_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/scores_before_mask.hex", gold_mem);

        rst_n      = 1'b0;
        start      = 1'b0;
        score_ready = 1'b1;
        pass_count = 0;
        fail_count = 0;
        seen_count = 0;

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        @(posedge clk);
        #1 start = 1'b1;
        @(posedge clk);
        #1 start = 1'b0;

        wait (done === 1'b1);
        @(posedge clk);

        $display("========================================");
        $display("Small GQA systolic matrix test complete");
        $display("Expected = %0d", Q_HEADS*TEST_SEQ*TEST_SEQ);
        $display("Seen     = %0d", seen_count);
        $display("PASS     = %0d", pass_count);
        $display("FAIL     = %0d", fail_count);

        if ((seen_count == Q_HEADS*TEST_SEQ*TEST_SEQ) &&
            (fail_count == 0))
            $display("[PASS] small systolic QK matrix");
        else
            $display("[FAIL] small systolic QK matrix");
        $display("========================================");

        #50;
        $finish;
    end

    initial begin
        #20000000;
        $display("[TIMEOUT] small GQA systolic matrix did not finish");
        $display("seen=%0d pass=%0d fail=%0d", seen_count, pass_count, fail_count);
        $finish;
    end

endmodule
