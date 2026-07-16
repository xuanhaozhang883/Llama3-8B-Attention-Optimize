`timescale 1ns/1ps

module tb_qk_systolic_gqa_4heads_seq8;

    localparam int TILE       = 4;
    localparam int TEST_SEQ   = 8;
    localparam int FULL_SEQ   = 128;
    localparam int HEAD_DIM   = 128;
    localparam int Q_HEADS    = 4;
    localparam int TOTAL      = Q_HEADS * TEST_SEQ * TEST_SEQ;
    localparam int HEAD_W     = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int SEQ_W      = (TEST_SEQ <= 1) ? 1 : $clog2(TEST_SEQ);
    localparam int DIM_W      = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int TOL_ULP    = 0;

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
    logic [SEQ_W-1:0]  req_row_base;
    logic [SEQ_W-1:0]  req_col_base;
    logic [DIM_W-1:0]  req_dim;

    logic score_valid;
    logic score_ready;
    logic [15:0] score_bf16;
    logic [31:0] score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [SEQ_W-1:0]  score_row;
    logic [SEQ_W-1:0]  score_col;
    logic score_last;

    logic [15:0] q_mem    [0:4*FULL_SEQ*HEAD_DIM-1];
    logic [15:0] k_mem    [0:FULL_SEQ*HEAD_DIM-1];
    logic [15:0] gold_mem [0:4*FULL_SEQ*FULL_SEQ-1];

    reg seen_map [0:TOTAL-1];

    integer lane;
    integer init_idx;
    integer scan_idx;
    integer pass_count;
    integer fail_count;
    integer duplicate_count;
    integer seen_count;
    integer last_count;
    integer gold_index;
    integer local_index;
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

    // 组合式仿真数据加载器。仅用于testbench，不会综合到FPGA。
    always @* begin
        vec_valid  = rst_n && busy;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;

        for (lane = 0; lane < TILE; lane = lane + 1) begin
            q_vec_bf16[lane*16 +: 16] =
                q_mem[req_head*FULL_SEQ*HEAD_DIM +
                      (req_row_base+lane)*HEAD_DIM + req_dim];

            // 当前文件是4Q共享1K，因此K没有head偏移。
            k_vec_bf16[lane*16 +: 16] =
                k_mem[(req_col_base+lane)*HEAD_DIM + req_dim];
        end
    end

    always @(posedge clk) begin
        if (rst_n && score_valid && score_ready) begin
            gold_index =
                score_head*FULL_SEQ*FULL_SEQ +
                score_row*FULL_SEQ + score_col;

            local_index =
                score_head*TEST_SEQ*TEST_SEQ +
                score_row*TEST_SEQ + score_col;

            if (seen_map[local_index]) begin
                duplicate_count = duplicate_count + 1;
                $display("[DUPLICATE] h=%0d row=%0d col=%0d",
                         score_head, score_row, score_col);
            end else begin
                seen_map[local_index] = 1'b1;
            end

            diff = abs_diff16(score_bf16, gold_mem[gold_index]);
            seen_count = seen_count + 1;

            if (diff <= TOL_ULP) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                if (fail_count <= 20) begin
                    $display(
                        "[FAIL] h=%0d row=%0d col=%0d gold=%h rtl=%h diff=%0d fp32=%h",
                        score_head, score_row, score_col,
                        gold_mem[gold_index], score_bf16,
                        diff, score_fp32_debug
                    );
                end
            end

            if (score_last)
                last_count = last_count + 1;

            if ((seen_count % 64) == 0)
                $display("[PROGRESS] %0d / %0d outputs checked",
                         seen_count, TOTAL);
        end
    end

    initial begin
        // 改成你本机已经能正常读取的路径。
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_after_rope.hex", q_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/k_after_rope.hex", k_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/scores_before_mask.hex", gold_mem);

        rst_n          = 1'b0;
        start          = 1'b0;
        score_ready    = 1'b1;
        pass_count     = 0;
        fail_count     = 0;
        duplicate_count = 0;
        seen_count     = 0;
        last_count     = 0;

        for (init_idx = 0; init_idx < TOTAL; init_idx = init_idx + 1)
            seen_map[init_idx] = 1'b0;

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
        $display("4-head, seq8, TILE=4 QK test complete");
        $display("Expected   = %0d", TOTAL);
        $display("Seen       = %0d", seen_count);
        $display("PASS       = %0d", pass_count);
        $display("FAIL       = %0d", fail_count);
        $display("Duplicates = %0d", duplicate_count);
        $display("score_last = %0d", last_count);

        if ((seen_count == TOTAL) &&
            (pass_count == TOTAL) &&
            (fail_count == 0) &&
            (duplicate_count == 0) &&
            (last_count == 1))
            $display("[PASS] 4-head seq8 TILE=4 QK matrix");
        else
            $display("[FAIL] 4-head seq8 TILE=4 QK matrix");
        $display("========================================");

        #50;
        $finish;
    end

    initial begin
        #20000000;
        $display("========================================");
        $display("[TIMEOUT] seq8 test did not finish");
        $display("seen=%0d pass=%0d fail=%0d duplicates=%0d",
                 seen_count, pass_count, fail_count, duplicate_count);
        $display("busy=%b done=%b req_head=%0d row_base=%0d col_base=%0d dim=%0d",
                 busy, done, req_head, req_row_base, req_col_base, req_dim);
        $display("========================================");
        $finish;
    end

endmodule
