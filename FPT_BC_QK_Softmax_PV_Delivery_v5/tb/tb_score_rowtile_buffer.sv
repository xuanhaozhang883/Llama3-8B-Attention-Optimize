`timescale 1ns/1ps

module tb_score_rowtile_buffer;
    localparam int SEQ_LEN = 8;
    localparam int TILE    = 4;
    localparam int HEAD_W  = 2;
    localparam int POS_W   = 3;
    localparam int DEPTH   = SEQ_LEN*TILE;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic s_valid, s_ready;
    logic [15:0] s_score;
    logic s_mask;
    logic [HEAD_W-1:0] s_head;
    logic [POS_W-1:0] s_row, s_col;

    logic m_valid, m_ready;
    logic [15:0] m_data;
    logic m_mask;
    logic [HEAD_W-1:0] m_head;
    logic [POS_W-1:0] m_row, m_col;
    logic m_first, m_last;
    logic busy, protocol_error;

    localparam int HOLD_W = 16+1+HEAD_W+2*POS_W+2;
    int recv_count;
    int last_count;
    int ready_cycle;
    logic stalled_prev;
    logic [HOLD_W-1:0] held_bundle;

    function automatic logic [15:0] encode_score(
        input int head, input int row, input int col
    );
        encode_score = 16'h1000 + head*16'h0400 + row*SEQ_LEN + col;
    endfunction

    score_rowtile_buffer #(
        .SEQ_LEN(SEQ_LEN), .TILE(TILE), .HEAD_W(HEAD_W), .POS_W(POS_W)
    ) dut (
        .clk, .rst_n,
        .s_valid, .s_ready, .s_score, .s_mask, .s_head, .s_row, .s_col,
        .m_valid, .m_ready, .m_data, .m_mask, .m_head, .m_row, .m_col,
        .m_first, .m_last, .busy, .protocol_error
    );

    task automatic send_item(input int head, input int row, input int col);
        begin
            @(negedge clk);
            s_valid = 1'b1;
            s_head  = head[HEAD_W-1:0];
            s_row   = row[POS_W-1:0];
            s_col   = col[POS_W-1:0];
            s_score = encode_score(head,row,col);
            s_mask  = (col > row);
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_valid = 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            m_ready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            m_ready <= ((ready_cycle % 5) != 2);
        end
    end

    always_ff @(posedge clk) begin
        int exp_row;
        int exp_col;
        logic [HOLD_W-1:0] now_bundle;
        if (!rst_n) begin
            recv_count <= 0;
            last_count <= 0;
            stalled_prev <= 1'b0;
        end else begin
            now_bundle = {m_data,m_mask,m_head,m_row,m_col,m_first,m_last};
            if (stalled_prev && (!m_valid || now_bundle !== held_bundle))
                $fatal(1, "Row buffer output changed while stalled");
            stalled_prev <= m_valid && !m_ready;
            if (m_valid && !m_ready)
                held_bundle <= now_bundle;

            if (m_valid && m_ready) begin
                exp_row = recv_count / SEQ_LEN;
                exp_col = recv_count % SEQ_LEN;
                if (m_head !== 2'd1 || m_row !== exp_row[POS_W-1:0] ||
                    m_col !== exp_col[POS_W-1:0])
                    $fatal(1, "Output order mismatch at %0d", recv_count);
                if (m_data !== encode_score(1,exp_row,exp_col))
                    $fatal(1, "Score mismatch at %0d", recv_count);
                if (m_mask !== (exp_col > exp_row))
                    $fatal(1, "Mask mismatch at %0d", recv_count);
                if (m_first !== (exp_col == 0) || m_last !== (exp_col == SEQ_LEN-1))
                    $fatal(1, "Row boundary mismatch at %0d", recv_count);
                if (m_last) last_count <= last_count + 1;
                recv_count <= recv_count + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        s_valid = 1'b0;
        s_score = '0;
        s_mask = 1'b0;
        s_head = '0;
        s_row = '0;
        s_col = '0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        // Exact qk_systolic_tile output order: col-tile outer, then local row,
        // then local column (tile result is local row-major).
        for (int col_base = 0; col_base < SEQ_LEN; col_base += TILE)
            for (int local_row = 0; local_row < TILE; local_row++)
                for (int local_col = 0; local_col < TILE; local_col++)
                    send_item(1, local_row, col_base + local_col);

        wait (recv_count == DEPTH);
        repeat (3) @(posedge clk);
        if (last_count != TILE) $fatal(1, "Expected %0d row_last pulses", TILE);
        if (protocol_error) $fatal(1, "Unexpected protocol_error");
        $display("PASS: tb_score_rowtile_buffer");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Timeout");
    end
endmodule
