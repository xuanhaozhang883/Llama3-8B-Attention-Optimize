`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// QK -> Causal Mask streaming interface
//
// Function:
//   For every QK score:
//     if causal_en && (k_pos > q_pos), output mask_value;
//     otherwise, pass the original score.
//
// Interface:
//   - ready/valid streaming handshake
//   - one pipeline stage
//   - accepts up to one score per clock
//   - one-cycle latency when the downstream is ready
//   - score format is not interpreted; it is copied/replaced bit-for-bit
//
// Recommended defaults:
//   SCORE_WIDTH = 16 for BF16 raw bits
//   POS_WIDTH   = 7  for seq_len <= 128
//   HEAD_WIDTH  = 5  for q_heads <= 32
//   mask_value  = 16'hFF80 for BF16 -Inf
// -----------------------------------------------------------------------------

module causal_mask_stream #(
    parameter integer SCORE_WIDTH = 16,
    parameter integer POS_WIDTH   = 7,
    parameter integer HEAD_WIDTH  = 5
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Runtime configuration
    input  wire                         causal_en,
    input  wire [SCORE_WIDTH-1:0]       mask_value,

    // Input stream from QK module
    input  wire                         s_valid,
    output wire                         s_ready,
    input  wire [SCORE_WIDTH-1:0]       s_score,
    input  wire [HEAD_WIDTH-1:0]        s_head_idx,
    input  wire [POS_WIDTH-1:0]         s_q_pos,
    input  wire [POS_WIDTH-1:0]         s_k_pos,
    input  wire                         s_row_last,

    // Output stream to Softmax / next module
    output wire                         m_valid,
    input  wire                         m_ready,
    output wire [SCORE_WIDTH-1:0]       m_score,
    output wire [HEAD_WIDTH-1:0]        m_head_idx,
    output wire [POS_WIDTH-1:0]         m_q_pos,
    output wire [POS_WIDTH-1:0]         m_k_pos,
    output wire                         m_row_last
);

    reg                          valid_reg;
    reg [SCORE_WIDTH-1:0]        score_reg;
    reg [HEAD_WIDTH-1:0]         head_idx_reg;
    reg [POS_WIDTH-1:0]          q_pos_reg;
    reg [POS_WIDTH-1:0]          k_pos_reg;
    reg                          row_last_reg;

    // The pipeline register can accept new data when it is empty,
    // or when the current output is consumed in this cycle.
    assign s_ready = (~valid_reg) | m_ready;

    assign m_valid    = valid_reg;
    assign m_score    = score_reg;
    assign m_head_idx = head_idx_reg;
    assign m_q_pos    = q_pos_reg;
    assign m_k_pos    = k_pos_reg;
    assign m_row_last = row_last_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_reg    <= 1'b0;
            score_reg    <= {SCORE_WIDTH{1'b0}};
            head_idx_reg <= {HEAD_WIDTH{1'b0}};
            q_pos_reg    <= {POS_WIDTH{1'b0}};
            k_pos_reg    <= {POS_WIDTH{1'b0}};
            row_last_reg <= 1'b0;
        end
        else if (s_ready) begin
            // When s_valid=0, this clears the output valid bit.
            valid_reg <= s_valid;

            if (s_valid) begin
                score_reg <= (causal_en && (s_k_pos > s_q_pos))
                           ? mask_value
                           : s_score;

                // Pass metadata through unchanged.
                head_idx_reg <= s_head_idx;
                q_pos_reg    <= s_q_pos;
                k_pos_reg    <= s_k_pos;
                row_last_reg <= s_row_last;
            end
        end
    end

endmodule
