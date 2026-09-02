`timescale 1ns/1ps

module tb_v31_flash_attention_consumer_multigroup;
    localparam int TILE = 4;
    localparam int V_LANES = 8;
    localparam int SEQ_LEN = 4;
    localparam int HEAD_DIM = 8;
    localparam int GQA_GROUPS = 8;
    localparam int CONTEXTS_PER_GROUP = TILE*HEAD_DIM;
    localparam int TEST_GROUPS = 2;
    localparam int V_ADDR_W = $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic score_valid = 1'b0;
    logic score_ready;
    logic [15:0] score_bf16 = '0;
    logic score_mask = 1'b0;
    logic [2:0] score_group = '0;
    logic score_head = 1'b0;
    logic [1:0] score_row = '0;
    logic [1:0] score_col = '0;
    logic score_last = 1'b0;
    logic v_load_valid = 1'b0;
    logic v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr = '0;
    logic [V_LANES*16-1:0] v_load_data = '0;
    logic context_valid;
    logic context_ready = 1'b0;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [2:0] context_group;
    logic context_head;
    logic [4:0] context_global_head;
    logic [1:0] context_row;
    logic [2:0] context_col;
    logic context_last;
    logic busy;
    logic protocol_error;
    logic [31:0] score_tiles_enqueued;
    logic [31:0] score_tiles_dequeued;
    logic [31:0] softmax_tiles_processed;
    logic [31:0] context_tiles_processed;
    logic [31:0] v_vectors_read;

    integer output_count = 0;
    integer cycles = 0;
    logic stalled = 1'b0;
    logic [15:0] stalled_context;
    logic [2:0] stalled_group;
    logic [1:0] stalled_row;
    logic [2:0] stalled_col;
    logic stalled_last;

    always #5 clk = ~clk;

    flash_attention_consumer_top #(
        .TILE(TILE), .V_LANES(V_LANES), .FIFO_DEPTH_TILES(3),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM), .Q_HEADS(1),
        .GQA_GROUPS(GQA_GROUPS), .HEAD_W(1), .GROUP_W(3),
        .GLOBAL_HEAD_W(5), .POS_W(2), .DIM_W(3),
        .V_ADDR_W(V_ADDR_W), .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);

    task automatic load_v_vector(
        input integer group_number,
        input integer token_number,
        input logic [15:0] value
    );
        integer lane;
        begin
            @(negedge clk);
            v_load_addr = group_number*SEQ_LEN*HEAD_DIM +
                          token_number*HEAD_DIM;
            for (lane = 0; lane < V_LANES; lane = lane + 1)
                v_load_data[lane*16 +: 16] = value;
            v_load_valid = 1'b1;
            do @(posedge clk); while (!v_load_ready);
            @(negedge clk);
            v_load_valid = 1'b0;
        end
    endtask

    task automatic send_score(
        input integer group_number,
        input integer row_number,
        input integer col_number
    );
        begin
            @(negedge clk);
            score_group = group_number[2:0];
            score_row = row_number[1:0];
            score_col = col_number[1:0];
            score_bf16 = 16'h0000;
            score_mask = 1'b0;
            score_last = (row_number == SEQ_LEN-1) &&
                         (col_number == SEQ_LEN-1);
            score_valid = 1'b1;
            do @(posedge clk); while (!score_ready);
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin : p_monitor
        integer expected_group;
        integer group_context;
        logic [15:0] expected_value;
        if (!rst_n) begin
            cycles <= 0;
            output_count <= 0;
            context_ready <= 1'b0;
            stalled <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            context_ready <= ((cycles % 7) != 0) && ((cycles % 11) != 0);
            if (cycles > 10000)
                $fatal(1, "multi-group consumer timeout: outputs=%0d",
                       output_count);

            if (stalled && (!context_valid ||
                context_bf16 !== stalled_context ||
                context_group !== stalled_group ||
                context_row !== stalled_row ||
                context_col !== stalled_col ||
                context_last !== stalled_last))
                $fatal(1, "Context payload changed under backpressure");
            stalled <= context_valid && !context_ready;
            if (context_valid && !context_ready) begin
                stalled_context <= context_bf16;
                stalled_group <= context_group;
                stalled_row <= context_row;
                stalled_col <= context_col;
                stalled_last <= context_last;
            end

            if (context_valid && context_ready) begin
                expected_group = output_count / CONTEXTS_PER_GROUP;
                group_context = output_count % CONTEXTS_PER_GROUP;
                expected_value = (expected_group == 0) ? 16'h3F80 : 16'h4000;
                if (context_bf16 !== expected_value)
                    $fatal(1, "Context value mismatch at %0d: got=%h expected=%h",
                           output_count, context_bf16, expected_value);
                if (($unsigned(context_group) != expected_group) ||
                    ($unsigned(context_global_head) != expected_group) ||
                    ($unsigned(context_row) != group_context/HEAD_DIM) ||
                    ($unsigned(context_col) != group_context%HEAD_DIM))
                    $fatal(1, "Context metadata mismatch at %0d", output_count);
                if (context_last !==
                    (group_context == CONTEXTS_PER_GROUP-1))
                    $fatal(1, "Context last mismatch at %0d", output_count);
                output_count <= output_count + 1;
            end
        end
    end

    initial begin : p_driver
        integer group_number;
        integer token_number;
        integer row_number;
        integer col_number;
        logic [15:0] group_value;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (group_number = 0; group_number < TEST_GROUPS;
             group_number = group_number + 1) begin
            group_value = (group_number == 0) ? 16'h3F80 : 16'h4000;
            for (token_number = 0; token_number < SEQ_LEN;
                 token_number = token_number + 1)
                load_v_vector(group_number, token_number, group_value);
        end

        for (group_number = 0; group_number < TEST_GROUPS;
             group_number = group_number + 1)
            for (row_number = 0; row_number < SEQ_LEN;
                 row_number = row_number + 1)
                for (col_number = 0; col_number < SEQ_LEN;
                     col_number = col_number + 1)
                    send_score(group_number, row_number, col_number);

        wait (output_count == TEST_GROUPS*CONTEXTS_PER_GROUP);
        repeat (5) @(posedge clk);
        if (protocol_error)
            $fatal(1, "legal multi-group stream raised protocol_error");
        if (score_tiles_enqueued != TEST_GROUPS ||
            score_tiles_dequeued != TEST_GROUPS ||
            softmax_tiles_processed != TEST_GROUPS ||
            context_tiles_processed != TEST_GROUPS ||
            v_vectors_read != TEST_GROUPS*TILE)
            $fatal(1, "counter mismatch fifo=%0d/%0d sm=%0d ctx=%0d v=%0d",
                   score_tiles_enqueued, score_tiles_dequeued,
                   softmax_tiles_processed, context_tiles_processed,
                   v_vectors_read);
        $display("FLASH_ATTENTION_CONSUMER_MULTIGROUP_TEST: PASS groups=%0d contexts=%0d",
                 TEST_GROUPS, output_count);
        $finish;
    end
endmodule
