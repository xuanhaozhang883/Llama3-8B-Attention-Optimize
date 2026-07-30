`timescale 1ns/1ps

module tb_causal_mask_stream;

    localparam SCORE_WIDTH = 16;
    localparam POS_WIDTH   = 7;
    localparam HEAD_WIDTH  = 5;

    reg clk;
    reg rst_n;

    reg                        causal_en;
    reg  [SCORE_WIDTH-1:0]     mask_value;

    reg                        s_valid;
    wire                       s_ready;
    reg  [SCORE_WIDTH-1:0]     s_score;
    reg  [HEAD_WIDTH-1:0]      s_head_idx;
    reg  [POS_WIDTH-1:0]       s_q_pos;
    reg  [POS_WIDTH-1:0]       s_k_pos;
    reg                        s_row_last;

    wire                       m_valid;
    reg                        m_ready;
    wire [SCORE_WIDTH-1:0]     m_score;
    wire [HEAD_WIDTH-1:0]      m_head_idx;
    wire [POS_WIDTH-1:0]       m_q_pos;
    wire [POS_WIDTH-1:0]       m_k_pos;
    wire                       m_row_last;

    integer errors;

    causal_mask_stream #(
        .SCORE_WIDTH(SCORE_WIDTH),
        .POS_WIDTH(POS_WIDTH),
        .HEAD_WIDTH(HEAD_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .causal_en(causal_en),
        .mask_value(mask_value),

        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_score(s_score),
        .s_head_idx(s_head_idx),
        .s_q_pos(s_q_pos),
        .s_k_pos(s_k_pos),
        .s_row_last(s_row_last),

        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_score(m_score),
        .m_head_idx(m_head_idx),
        .m_q_pos(m_q_pos),
        .m_k_pos(m_k_pos),
        .m_row_last(m_row_last)
    );

    always #5 clk = ~clk;

    task send_and_check;
        input [SCORE_WIDTH-1:0] in_score;
        input [HEAD_WIDTH-1:0]  head_idx;
        input [POS_WIDTH-1:0]   q_pos;
        input [POS_WIDTH-1:0]   k_pos;
        input                   row_last;
        input [SCORE_WIDTH-1:0] expected_score;
        begin
            // Drive input before the active edge.
            @(negedge clk);
            s_valid    = 1'b1;
            s_score    = in_score;
            s_head_idx = head_idx;
            s_q_pos    = q_pos;
            s_k_pos    = k_pos;
            s_row_last = row_last;

            while (!s_ready)
                @(negedge clk);

            @(posedge clk);
            #1;

            // Remove input after it has been accepted.
            @(negedge clk);
            s_valid = 1'b0;

            // Output should now be valid because m_ready is held high.
            if (!m_valid) begin
                $display("ERROR: m_valid=0 for q=%0d k=%0d", q_pos, k_pos);
                errors = errors + 1;
            end
            else begin
                if (m_score !== expected_score) begin
                    $display("ERROR: q=%0d k=%0d score=%h expected=%h",
                             q_pos, k_pos, m_score, expected_score);
                    errors = errors + 1;
                end

                if ((m_head_idx !== head_idx) ||
                    (m_q_pos    !== q_pos)    ||
                    (m_k_pos    !== k_pos)    ||
                    (m_row_last !== row_last)) begin
                    $display("ERROR: metadata mismatch");
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        clk        = 1'b0;
        rst_n      = 1'b0;
        causal_en  = 1'b1;
        mask_value = 16'hFF80;

        s_valid    = 1'b0;
        s_score    = 16'h0000;
        s_head_idx = 0;
        s_q_pos    = 0;
        s_k_pos    = 0;
        s_row_last = 1'b0;

        m_ready    = 1'b1;
        errors     = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // q=0, k=0: keep
        send_and_check(16'h3F80, 0, 0, 0, 0, 16'h3F80);

        // q=0, k=1: future token, mask
        send_and_check(16'h4000, 0, 0, 1, 0, 16'hFF80);

        // q=2, k=1: keep
        send_and_check(16'h4040, 0, 2, 1, 0, 16'h4040);

        // q=2, k=3: future token, mask
        send_and_check(16'h4080, 0, 2, 3, 1, 16'hFF80);

        // Disable causal mask: q=0, k=3 must pass through.
        causal_en = 1'b0;
        send_and_check(16'h40A0, 1, 0, 3, 1, 16'h40A0);

        repeat (2) @(posedge clk);

        if (errors == 0)
            $display("PASS: causal_mask_stream");
        else
            $display("FAIL: %0d error(s)", errors);

        $finish;
    end

endmodule
