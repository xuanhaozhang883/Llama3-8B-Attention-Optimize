`timescale 1ns/1ps

module tb_qk_systolic_gqa_4heads_seq128_dump;

    localparam int TILE       = 4;
    localparam int SEQ_LEN    = 128;
    localparam int HEAD_DIM   = 128;
    localparam int Q_HEADS    = 4;
    localparam int TOTAL      = Q_HEADS * SEQ_LEN * SEQ_LEN;
    localparam int HEAD_W     = $clog2(Q_HEADS);
    localparam int SEQ_W      = $clog2(SEQ_LEN);
    localparam int DIM_W      = $clog2(HEAD_DIM);

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

    logic [15:0] q_mem    [0:Q_HEADS*SEQ_LEN*HEAD_DIM-1];
    logic [15:0] k_mem    [0:SEQ_LEN*HEAD_DIM-1];
    logic [15:0] gold_mem [0:TOTAL-1];
    logic [15:0] rtl_mem  [0:TOTAL-1];

    reg seen_map [0:TOTAL-1];

    integer lane;
    integer init_idx;
    integer scan_idx;
    integer pass_count;
    integer fail_count;
    integer duplicate_count;
    integer missing_count;
    integer seen_count;
    integer last_count;
    integer global_index;
    integer output_file;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    qk_systolic_gqa_top #(
        .TILE     (TILE),
        .SEQ_LEN  (SEQ_LEN),
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

    // 仿真数据加载器：按照DUT的请求，提供一个TILE宽度的Q/K向量。
    always @* begin
        vec_valid  = rst_n && busy;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;

        for (lane = 0; lane < TILE; lane = lane + 1) begin
            q_vec_bf16[lane*16 +: 16] =
                q_mem[req_head*SEQ_LEN*HEAD_DIM +
                      (req_row_base+lane)*HEAD_DIM + req_dim];

            k_vec_bf16[lane*16 +: 16] =
                k_mem[(req_col_base+lane)*HEAD_DIM + req_dim];
        end
    end

    always @(posedge clk) begin
        if (rst_n && score_valid && score_ready) begin
            global_index =
                score_head*SEQ_LEN*SEQ_LEN +
                score_row*SEQ_LEN + score_col;

            if (seen_map[global_index]) begin
                duplicate_count = duplicate_count + 1;
                if (duplicate_count <= 20)
                    $display("[DUPLICATE] h=%0d row=%0d col=%0d",
                             score_head, score_row, score_col);
            end else begin
                seen_map[global_index] = 1'b1;
            end

            rtl_mem[global_index] = score_bf16;
            seen_count = seen_count + 1;

            if (score_bf16 === gold_mem[global_index]) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                if (fail_count <= 20) begin
                    $display(
                        "[FAIL] h=%0d row=%0d col=%0d gold=%h rtl=%h fp32=%h",
                        score_head, score_row, score_col,
                        gold_mem[global_index], score_bf16,
                        score_fp32_debug
                    );
                end
            end

            if (score_last)
                last_count = last_count + 1;

            if ((seen_count % 4096) == 0)
                $display("[PROGRESS] %0d / %0d outputs checked",
                         seen_count, TOTAL);
        end
    end

    initial begin
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_after_rope.hex", q_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/k_after_rope.hex", k_mem);
        $readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/scores_before_mask.hex", gold_mem);

        rst_n           = 1'b0;
        start           = 1'b0;
        score_ready     = 1'b1;
        pass_count      = 0;
        fail_count      = 0;
        duplicate_count = 0;
        missing_count   = 0;
        seen_count      = 0;
        last_count      = 0;

        for (init_idx = 0; init_idx < TOTAL; init_idx = init_idx + 1) begin
            seen_map[init_idx] = 1'b0;
            rtl_mem[init_idx]  = 16'hxxxx;
        end

        #1;
        $display("========================================");
        $display("FULL TEST HEX CHECK");
        $display("q_mem[0]    = %h", q_mem[0]);
        $display("k_mem[0]    = %h", k_mem[0]);
        $display("gold_mem[0] = %h", gold_mem[0]);
        $display("========================================");

        if ((^q_mem[0] === 1'bx) ||
            (^k_mem[0] === 1'bx) ||
            (^gold_mem[0] === 1'bx)) begin
            $display("[FILE ERROR] Input HEX files were not loaded.");
            $finish;
        end

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        @(posedge clk);
        #1 start = 1'b1;
        @(posedge clk);
        #1 start = 1'b0;

        wait (done === 1'b1);
        @(posedge clk);

        for (scan_idx = 0; scan_idx < TOTAL; scan_idx = scan_idx + 1) begin
            if (!seen_map[scan_idx])
                missing_count = missing_count + 1;
        end

        // 先在内存中按global_index重排，再按标准C-order写文件。
        output_file = $fopen("D:/qk_sim_data/rtl_scores_seq128.hex", "w");
        if (output_file == 0) begin
            $display("[FILE ERROR] Cannot create rtl_scores_seq128.hex");
            $finish;
        end

        for (scan_idx = 0; scan_idx < TOTAL; scan_idx = scan_idx + 1)
            $fwrite(output_file, "%04x\n", rtl_mem[scan_idx]);

        $fclose(output_file);

        $display("========================================");
        $display("FULL 4-head, seq128, TILE=4 QK test complete");
        $display("Expected   = %0d", TOTAL);
        $display("Seen       = %0d", seen_count);
        $display("PASS       = %0d", pass_count);
        $display("FAIL       = %0d", fail_count);
        $display("Duplicates = %0d", duplicate_count);
        $display("Missing    = %0d", missing_count);
        $display("score_last = %0d", last_count);
        $display("Output file: D:/qk_sim_data/rtl_scores_seq128.hex");

        if ((seen_count == TOTAL) &&
            (pass_count == TOTAL) &&
            (fail_count == 0) &&
            (duplicate_count == 0) &&
            (missing_count == 0) &&
            (last_count == 1))
            $display("[PASS] FULL 4-head seq128 TILE=4 QK matrix");
        else
            $display("[FAIL] FULL 4-head seq128 TILE=4 QK matrix");
        $display("========================================");

        #50;
        $finish;
    end

    // 2秒逻辑仿真时间超时保护。正常应显著早于此结束。
    initial begin
        #2000000000;
        $display("========================================");
        $display("[TIMEOUT] full seq128 test did not finish");
        $display("seen=%0d pass=%0d fail=%0d duplicates=%0d",
                 seen_count, pass_count, fail_count, duplicate_count);
        $display("busy=%b done=%b req_head=%0d row_base=%0d col_base=%0d dim=%0d",
                 busy, done, req_head, req_row_base, req_col_base, req_dim);
        $display("========================================");
        $finish;
    end

endmodule
