`timescale 1ns/1ps

module tb_pv_systolic_4heads_full;

    localparam integer TILE         = 4;
    localparam integer TEST_ROWS    = 128;
    localparam integer TEST_COLS    = 128;
    localparam integer REDUCE_LEN   = 128;
    localparam integer Q_HEADS      = 4;

    localparam integer FULL_ROWS    = 128;
    localparam integer FULL_COLS    = 128;
    localparam integer FULL_TOTAL   = Q_HEADS*FULL_ROWS*FULL_COLS;
    localparam integer TEST_TOTAL   = Q_HEADS*TEST_ROWS*TEST_COLS;

    localparam integer HEAD_W       = 2;
    localparam integer ROW_W        =
        (TEST_ROWS <= 1) ? 1 : $clog2(TEST_ROWS);
    localparam integer COL_W        =
        (TEST_COLS <= 1) ? 1 : $clog2(TEST_COLS);
    localparam integer RED_W        = 7;

    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;

    wire vec_ready;
    reg  vec_valid;
    reg [TILE*16-1:0] p_vec_bf16;
    reg [TILE*16-1:0] v_vec_bf16;

    wire [HEAD_W-1:0] req_head;
    wire [ROW_W-1:0]  req_row_base;
    wire [COL_W-1:0]  req_col_base;
    wire [RED_W-1:0]  req_reduce;

    wire context_valid;
    reg  context_ready;
    wire [15:0] context_bf16;
    wire [31:0] context_fp32_debug;
    wire [HEAD_W-1:0] context_head;
    wire [ROW_W-1:0]  context_row;
    wire [COL_W-1:0]  context_col;
    wire context_last;

    reg [15:0] p_mem    [0:Q_HEADS*FULL_ROWS*REDUCE_LEN-1];
    reg [15:0] v_mem    [0:REDUCE_LEN*FULL_COLS-1];
    reg [15:0] gold_mem [0:FULL_TOTAL-1];

    reg seen_map [0:TEST_TOTAL-1];

    reg [15:0] rtl_mem [0:FULL_TOTAL-1];
    integer output_file;
    integer missing_count;
    integer scan_idx;

    integer lane;
    integer init_idx;
    integer pass_count;
    integer fail_count;
    integer duplicate_count;
    integer seen_count;
    integer last_count;
    integer global_index;
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

    pv_systolic_gqa_top #(
        .TILE       (TILE),
        .QUERY_LEN  (TEST_ROWS),
        .REDUCE_LEN (REDUCE_LEN),
        .HEAD_DIM   (TEST_COLS),
        .Q_HEADS    (Q_HEADS)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .vec_ready          (vec_ready),
        .vec_valid          (vec_valid),
        .p_vec_bf16         (p_vec_bf16),
        .v_vec_bf16         (v_vec_bf16),
        .req_head           (req_head),
        .req_row_base       (req_row_base),
        .req_col_base       (req_col_base),
        .req_reduce         (req_reduce),
        .context_valid      (context_valid),
        .context_ready      (context_ready),
        .context_bf16       (context_bf16),
        .context_fp32_debug (context_fp32_debug),
        .context_head       (context_head),
        .context_row        (context_row),
        .context_col        (context_col),
        .context_last       (context_last)
    );

    // Simulation-only loader.
    always @* begin
        vec_valid  = 1'b0;
        p_vec_bf16 = {TILE*16{1'b0}};
        v_vec_bf16 = {TILE*16{1'b0}};

        if (rst_n && busy) begin
            vec_valid = 1'b1;

            for (lane = 0; lane < TILE; lane = lane + 1) begin
                p_vec_bf16[lane*16 +: 16] =
                    p_mem[
                        req_head*FULL_ROWS*REDUCE_LEN +
                        (req_row_base+lane)*REDUCE_LEN +
                        req_reduce
                    ];

                v_vec_bf16[lane*16 +: 16] =
                    v_mem[
                        req_reduce*FULL_COLS +
                        req_col_base + lane
                    ];
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && context_valid && context_ready) begin
            global_index =
                context_head*FULL_ROWS*FULL_COLS +
                context_row*FULL_COLS +
                context_col;

            local_index =
                context_head*TEST_ROWS*TEST_COLS +
                context_row*TEST_COLS +
                context_col;

            if (seen_map[local_index]) begin
                duplicate_count = duplicate_count + 1;
                if (duplicate_count <= 20)
                    $display(
                        "[DUPLICATE] h=%0d row=%0d col=%0d",
                        context_head, context_row, context_col
                    );
            end else begin
                seen_map[local_index] = 1'b1;
            end

            rtl_mem[global_index] = context_bf16;

            diff = abs_diff16(
                context_bf16, gold_mem[global_index]
            );

            seen_count = seen_count + 1;

            if (diff == 0) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                if (fail_count <= 20) begin
                    $display(
                        "[FAIL] h=%0d row=%0d col=%0d "
                        "gold=%h rtl=%h diff=%0d fp32=%h",
                        context_head, context_row, context_col,
                        gold_mem[global_index], context_bf16,
                        diff, context_fp32_debug
                    );
                end
            end

            if (context_last)
                last_count = last_count + 1;

            if ((seen_count % 4096) == 0)
                $display(
                    "[PROGRESS] %0d / %0d outputs checked",
                    seen_count, TEST_TOTAL
                );
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
        $display("PV HEX FILE CHECK");
        $display("p_mem[0]    = %h", p_mem[0]);
        $display("v_mem[0]    = %h", v_mem[0]);
        $display("gold_mem[0] = %h", gold_mem[0]);
        $display("Expected approximately: 3f80, bc39, bc39");
        $display("========================================");

        if ((^p_mem[0] === 1'bx) ||
            (^v_mem[0] === 1'bx) ||
            (^gold_mem[0] === 1'bx)) begin
            $display("[FILE ERROR] PV HEX files were not loaded.");
            $finish;
        end

        rst_n           = 1'b0;
        start           = 1'b0;
        context_ready   = 1'b1;
        pass_count      = 0;
        fail_count      = 0;
        duplicate_count = 0;
        seen_count      = 0;
        last_count      = 0;

        missing_count = 0;
        for (init_idx = 0; init_idx < FULL_TOTAL; init_idx = init_idx + 1) begin
            seen_map[init_idx] = 1'b0;
            rtl_mem[init_idx]  = 16'hxxxx;
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

        for (scan_idx = 0; scan_idx < FULL_TOTAL; scan_idx = scan_idx + 1) begin
            if (!seen_map[scan_idx])
                missing_count = missing_count + 1;
        end

        output_file = $fopen(
            "D:/pv_sim_data/rtl_pv_context_bf16.hex", "w"
        );
        if (output_file == 0) begin
            $display("[FILE ERROR] Cannot create RTL PV output file.");
            $finish;
        end

        for (scan_idx = 0; scan_idx < FULL_TOTAL; scan_idx = scan_idx + 1)
            $fwrite(output_file, "%04x\n", rtl_mem[scan_idx]);

        $fclose(output_file);

        $display("========================================");
        $display(
            "PV test complete: heads=4 rows=%0d cols=%0d reduce=128",
            TEST_ROWS, TEST_COLS
        );
        $display("Expected   = %0d", TEST_TOTAL);
        $display("Seen       = %0d", seen_count);
        $display("PASS       = %0d", pass_count);
        $display("FAIL       = %0d", fail_count);
        $display("Duplicates = %0d", duplicate_count);
        $display("context_last = %0d", last_count);

        $display("Missing    = %0d", missing_count);
        $display("RTL dump   = D:/pv_sim_data/rtl_pv_context_bf16.hex");

        if ((seen_count == FULL_TOTAL) && (pass_count == FULL_TOTAL) && (fail_count == 0) && (duplicate_count == 0) && (missing_count == 0) && (last_count == 1))
            $display("[PASS] PV systolic matrix");
        else
            $display("[FAIL] PV systolic matrix");

        $display("========================================");

        #50;
        $finish;
    end

    initial begin
        #2000000000;
        $display("========================================");
        $display("[TIMEOUT] PV test did not finish");
        $display(
            "seen=%0d pass=%0d fail=%0d duplicates=%0d",
            seen_count, pass_count, fail_count, duplicate_count
        );
        $display(
            "busy=%b done=%b head=%0d row_base=%0d "
            "col_base=%0d reduce=%0d",
            busy, done, req_head, req_row_base,
            req_col_base, req_reduce
        );
        $display("========================================");
        $finish;
    end

endmodule
