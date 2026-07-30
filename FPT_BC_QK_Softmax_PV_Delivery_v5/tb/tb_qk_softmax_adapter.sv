`timescale 1ns/1ps

module tb_qk_softmax_adapter;
    localparam int SEQ_LEN = 8;
    localparam int TILE    = 4;
    localparam int Q_HEADS = 2;
    localparam int HEAD_W  = 1;
    localparam int POS_W   = 3;
    localparam int TOTAL   = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int HOLD_W  = 16+1+HEAD_W+2*POS_W+3;

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

    int recv_count;
    int row_last_count;
    int global_last_count;
    int ready_cycle;
    logic stalled_prev;
    logic [HOLD_W-1:0] held_bundle;

    function automatic logic [15:0] encode_score(
        input int head, input int row, input int col
    );
        encode_score = 16'h2000 + head*16'h0800 + row*SEQ_LEN + col;
    endfunction

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

    task automatic send_qk_item(
        input int head, input int row, input int col, input bit is_global_last
    );
        begin
            @(negedge clk);
            qk_valid       = 1'b1;
            qk_score       = encode_score(head,row,col);
            qk_head        = head[HEAD_W-1:0];
            qk_row         = row[POS_W-1:0];
            qk_col         = col[POS_W-1:0];
            qk_global_last = is_global_last;
            do @(posedge clk); while (!qk_ready);
            @(negedge clk);
            qk_valid = 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            row_ready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            row_ready <= ((ready_cycle % 7) != 3) && ((ready_cycle % 7) != 4);
        end
    end

    always_ff @(posedge clk) begin
        int exp_head;
        int rem;
        int exp_row;
        int exp_col;
        logic [15:0] exp_data;
        logic [HOLD_W-1:0] now_bundle;
        if (!rst_n) begin
            recv_count <= 0;
            row_last_count <= 0;
            global_last_count <= 0;
            stalled_prev <= 1'b0;
        end else begin
            now_bundle = {row_data,row_mask,row_head,row_index,row_col,row_first,row_last,row_global_last};
            if (stalled_prev && (!row_valid || now_bundle !== held_bundle))
                $fatal(1, "Adapter output changed while stalled");
            stalled_prev <= row_valid && !row_ready;
            if (row_valid && !row_ready)
                held_bundle <= now_bundle;

            if (row_valid && row_ready) begin
                exp_head = recv_count / (SEQ_LEN*SEQ_LEN);
                rem      = recv_count % (SEQ_LEN*SEQ_LEN);
                exp_row  = rem / SEQ_LEN;
                exp_col  = rem % SEQ_LEN;
                exp_data = (exp_col > exp_row) ? 16'hFF80
                                               : encode_score(exp_head,exp_row,exp_col);

                if (row_head !== exp_head[HEAD_W-1:0] ||
                    row_index !== exp_row[POS_W-1:0] ||
                    row_col !== exp_col[POS_W-1:0])
                    $fatal(1, "Adapter metadata/order mismatch at %0d", recv_count);
                if (row_data !== exp_data)
                    $fatal(1, "Adapter data mismatch at %0d", recv_count);
                if (row_mask !== (exp_col > exp_row))
                    $fatal(1, "Adapter mask mismatch at %0d", recv_count);
                if (row_first !== (exp_col == 0) || row_last !== (exp_col == SEQ_LEN-1))
                    $fatal(1, "Adapter row boundary mismatch at %0d", recv_count);

                if (row_last) row_last_count <= row_last_count + 1;
                if (row_global_last) global_last_count <= global_last_count + 1;
                recv_count <= recv_count + 1;
            end
        end
    end

    initial begin
        bit is_last;
        rst_n = 1'b0;
        qk_valid = 1'b0;
        qk_score = '0;
        qk_head = '0;
        qk_row = '0;
        qk_col = '0;
        qk_global_last = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        for (int head = 0; head < Q_HEADS; head++) begin
            for (int row_base = 0; row_base < SEQ_LEN; row_base += TILE) begin
                for (int col_base = 0; col_base < SEQ_LEN; col_base += TILE) begin
                    for (int local_row = 0; local_row < TILE; local_row++) begin
                        for (int local_col = 0; local_col < TILE; local_col++) begin
                            is_last = (head == Q_HEADS-1) &&
                                      (row_base == SEQ_LEN-TILE) &&
                                      (col_base == SEQ_LEN-TILE) &&
                                      (local_row == TILE-1) &&
                                      (local_col == TILE-1);
                            send_qk_item(head, row_base+local_row,
                                        col_base+local_col, is_last);
                        end
                    end
                end
            end
        end

        wait (recv_count == TOTAL);
        repeat (5) @(posedge clk);
        if (row_last_count != Q_HEADS*SEQ_LEN)
            $fatal(1, "row_last count mismatch: got %0d", row_last_count);
        if (protocol_error)
            $fatal(1, "Unexpected protocol_error");
        if (global_last_error)
            $fatal(1, "Unexpected global_last_error");
        if (global_last_count != 1)
            $fatal(1, "Expected one row_global_last, got %0d", global_last_count);
        $display("PASS: tb_qk_softmax_adapter, outputs=%0d row_last=%0d",
                 recv_count, row_last_count);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "Timeout");
    end
endmodule
