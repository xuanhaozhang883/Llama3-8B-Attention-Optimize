`timescale 1ns/1ps

module tb_qk_softmax_adapter_file;
    localparam int SEQ_LEN = 128;
    localparam int TILE    = 4;
    localparam int Q_HEADS = 4;
    localparam int HEAD_W  = 2;
    localparam int POS_W   = 7;
    localparam int TOTAL   = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int INPUT_W = 33;
    localparam int EXPECT_W = 35;

    parameter INPUT_FILE = "qk_tile_order.mem";
    parameter EXPECT_FILE = "adapter_expected_row_order.mem";

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic qk_valid, qk_ready;
    logic [15:0] qk_score;
    logic [HEAD_W-1:0] qk_head;
    logic [POS_W-1:0] qk_row, qk_col;
    logic qk_global_last;

    logic row_valid, row_ready;
    logic [15:0] row_data;
    logic row_mask;
    logic [HEAD_W-1:0] row_head;
    logic [POS_W-1:0] row_index, row_col;
    logic row_first, row_last, row_global_last;
    logic busy, protocol_error, global_last_error;

    logic [INPUT_W-1:0] input_mem [0:TOTAL-1];
    logic [EXPECT_W-1:0] expected_mem [0:TOTAL-1];

    int send_count;
    int recv_count;
    int row_last_count;
    int mask_count;
    int global_last_count;
    int ready_cycle;

    qk_softmax_adapter #(
        .SEQ_LEN(SEQ_LEN), .TILE(TILE), .Q_HEADS(Q_HEADS),
        .HEAD_W(HEAD_W), .POS_W(POS_W)
    ) dut (
        .clk, .rst_n, .causal_en(1'b1),
        .qk_valid, .qk_ready, .qk_score, .qk_head, .qk_row, .qk_col,
        .qk_global_last,
        .row_valid, .row_ready, .row_data, .row_mask, .row_head,
        .row_index, .row_col, .row_first, .row_last, .row_global_last,
        .busy, .protocol_error, .global_last_error
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            row_ready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            // Repeatable backpressure, including two-cycle stalls.
            row_ready <= ((ready_cycle % 11) != 4) &&
                         ((ready_cycle % 11) != 5) &&
                         ((ready_cycle % 17) != 9);
        end
    end

    always_ff @(posedge clk) begin
        logic [EXPECT_W-1:0] actual;
        if (!rst_n) begin
            recv_count <= 0;
            row_last_count <= 0;
            mask_count <= 0;
            global_last_count <= 0;
        end else if (row_valid && row_ready) begin
            actual = {row_last,row_first,row_col,row_index,row_head,row_mask,row_data};
            if (actual !== expected_mem[recv_count]) begin
                $display("expected[%0d]=%09h", recv_count, expected_mem[recv_count]);
                $display("actual  [%0d]=%09h", recv_count, actual);
                $fatal(1, "Full adapter vector mismatch");
            end
            if (row_last) row_last_count <= row_last_count + 1;
            if (row_mask) mask_count <= mask_count + 1;
            if (row_global_last) global_last_count <= global_last_count + 1;
            recv_count <= recv_count + 1;
        end
    end

    initial begin
        $readmemh(INPUT_FILE, input_mem);
        $readmemh(EXPECT_FILE, expected_mem);

        rst_n = 1'b0;
        qk_valid = 1'b0;
        qk_score = '0;
        qk_head = '0;
        qk_row = '0;
        qk_col = '0;
        qk_global_last = 1'b0;
        send_count = 0;

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        while (send_count < TOTAL) begin
            @(negedge clk);
            qk_valid       = 1'b1;
            qk_score       = input_mem[send_count][15:0];
            qk_col         = input_mem[send_count][22:16];
            qk_row         = input_mem[send_count][29:23];
            qk_head        = input_mem[send_count][31:30];
            qk_global_last = input_mem[send_count][32];

            do @(posedge clk); while (!qk_ready);
            send_count = send_count + 1;
        end

        @(negedge clk);
        qk_valid = 1'b0;

        wait (recv_count == TOTAL);
        repeat (5) @(posedge clk);

        if (row_last_count != Q_HEADS*SEQ_LEN)
            $fatal(1, "Expected 512 row_last transfers, got %0d", row_last_count);
        if (mask_count != Q_HEADS*SEQ_LEN*(SEQ_LEN-1)/2)
            $fatal(1, "Expected 32512 masked transfers, got %0d", mask_count);
        if (protocol_error)
            $fatal(1, "Unexpected protocol_error");
        if (global_last_error)
            $fatal(1, "Unexpected global_last_error");
        if (global_last_count != 1)
            $fatal(1, "Expected one row_global_last, got %0d", global_last_count);

        $display("PASS: full 4-head SEQ=128 adapter test");
        $display("outputs=%0d row_last=%0d masked=%0d", recv_count,
                 row_last_count, mask_count);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Timeout");
    end
endmodule
