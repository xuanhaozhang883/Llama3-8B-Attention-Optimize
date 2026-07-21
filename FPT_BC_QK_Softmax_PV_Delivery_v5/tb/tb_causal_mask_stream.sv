`timescale 1ns/1ps

module tb_causal_mask_stream;
    localparam int SCORE_W = 16;
    localparam int HEAD_W  = 2;
    localparam int POS_W   = 3;
    localparam int N       = 8;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic s_valid, s_ready;
    logic [SCORE_W-1:0] s_score;
    logic [HEAD_W-1:0] s_head;
    logic [POS_W-1:0] s_row, s_col;
    logic s_global_last;

    logic m_valid, m_ready;
    logic [SCORE_W-1:0] m_score;
    logic m_mask;
    logic [HEAD_W-1:0] m_head;
    logic [POS_W-1:0] m_row, m_col;
    logic m_global_last;

    int recv_count;
    logic stalled_prev;
    logic [SCORE_W-1:0] held_score;
    logic held_mask;
    logic [HEAD_W-1:0] held_head;
    logic [POS_W-1:0] held_row, held_col;
    logic held_last;

    causal_mask_stream #(
        .SCORE_W(SCORE_W), .HEAD_W(HEAD_W), .POS_W(POS_W)
    ) dut (
        .clk, .rst_n,
        .causal_en(1'b1), .mask_value(16'hFF80),
        .s_valid, .s_ready, .s_score, .s_head, .s_row, .s_col,
        .s_global_last,
        .m_valid, .m_ready, .m_score, .m_mask, .m_head, .m_row, .m_col,
        .m_global_last
    );

    task automatic send_item(
        input logic [HEAD_W-1:0] head,
        input logic [POS_W-1:0] row,
        input logic [POS_W-1:0] col,
        input logic [15:0] score,
        input logic global_last
    );
        begin
            @(negedge clk);
            s_valid       = 1'b1;
            s_head        = head;
            s_row         = row;
            s_col         = col;
            s_score       = score;
            s_global_last = global_last;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_valid = 1'b0;
        end
    endtask

    // Deterministic backpressure pattern.
    int ready_cycle;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            m_ready     <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            m_ready     <= ((ready_cycle % 4) != 1);
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            recv_count   <= 0;
            stalled_prev <= 1'b0;
        end else begin
            if (stalled_prev) begin
                if (!m_valid || m_score != held_score || m_mask != held_mask ||
                    m_head != held_head || m_row != held_row || m_col != held_col ||
                    m_global_last != held_last)
                    $fatal(1, "Mask output changed while stalled");
            end

            stalled_prev <= m_valid && !m_ready;
            if (m_valid && !m_ready) begin
                held_score <= m_score;
                held_mask  <= m_mask;
                held_head  <= m_head;
                held_row   <= m_row;
                held_col   <= m_col;
                held_last  <= m_global_last;
            end

            if (m_valid && m_ready) begin
                if (m_head !== 2'd1 || m_row !== recv_count[POS_W-1:0] ||
                    m_col !== (N-1-recv_count))
                    $fatal(1, "Metadata mismatch at output %0d", recv_count);

                if ((N-1-recv_count) > recv_count) begin
                    if (!m_mask || m_score !== 16'hFF80)
                        $fatal(1, "Expected masked item at output %0d", recv_count);
                end else begin
                    if (m_mask || m_score !== (16'h3F00 + recv_count))
                        $fatal(1, "Expected pass-through item at output %0d", recv_count);
                end

                if (m_global_last !== (recv_count == N-1))
                    $fatal(1, "global_last mismatch");

                recv_count <= recv_count + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        s_valid = 1'b0;
        s_score = '0;
        s_head = '0;
        s_row = '0;
        s_col = '0;
        s_global_last = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (int i = 0; i < N; i++)
            send_item(2'd1, i[POS_W-1:0], (N-1-i), 16'h3F00+i, i == N-1);

        wait (recv_count == N);
        repeat (3) @(posedge clk);
        $display("PASS: tb_causal_mask_stream");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "Timeout");
    end
endmodule
