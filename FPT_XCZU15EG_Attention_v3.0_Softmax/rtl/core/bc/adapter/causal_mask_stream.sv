`timescale 1ns/1ps

// ============================================================================
// causal_mask_stream
// ----------------------------------------------------------------------------
// One-stage ready/valid pipeline between QK and the row-tile buffer.
// A score is causally masked when key position > query position.
// The original position metadata and the QK global-last flag are preserved.
// Reset convention: synchronous, active-low rst_n.
// ============================================================================
module causal_mask_stream #(
    parameter int SCORE_W = 16,
    parameter int HEAD_W  = 2,
    parameter int POS_W   = 7
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 causal_en,
    input  logic [SCORE_W-1:0]   mask_value,

    input  logic                 s_valid,
    output logic                 s_ready,
    input  logic [SCORE_W-1:0]   s_score,
    input  logic [HEAD_W-1:0]    s_head,
    input  logic [POS_W-1:0]     s_row,
    input  logic [POS_W-1:0]     s_col,
    input  logic                 s_global_last,

    output logic                 m_valid,
    input  logic                 m_ready,
    output logic [SCORE_W-1:0]   m_score,
    output logic                 m_mask,
    output logic [HEAD_W-1:0]    m_head,
    output logic [POS_W-1:0]     m_row,
    output logic [POS_W-1:0]     m_col,
    output logic                 m_global_last
);

    logic                 valid_reg;
    logic [SCORE_W-1:0]   score_reg;
    logic                 mask_reg;
    logic [HEAD_W-1:0]    head_reg;
    logic [POS_W-1:0]     row_reg;
    logic [POS_W-1:0]     col_reg;
    logic                 global_last_reg;

    logic                 causal_hit;

    assign causal_hit = causal_en && (s_col > s_row);

    // Elastic one-entry output register: it may accept a new item when empty,
    // or in the same cycle that the current item is consumed.
    assign s_ready = !valid_reg || m_ready;

    assign m_valid       = valid_reg;
    assign m_score       = score_reg;
    assign m_mask        = mask_reg;
    assign m_head        = head_reg;
    assign m_row         = row_reg;
    assign m_col         = col_reg;
    assign m_global_last = global_last_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_reg       <= 1'b0;
            score_reg       <= '0;
            mask_reg        <= 1'b0;
            head_reg        <= '0;
            row_reg         <= '0;
            col_reg         <= '0;
            global_last_reg <= 1'b0;
        end else if (s_ready) begin
            valid_reg <= s_valid;

            if (s_valid) begin
                score_reg       <= causal_hit ? mask_value : s_score;
                mask_reg        <= causal_hit;
                head_reg        <= s_head;
                row_reg         <= s_row;
                col_reg         <= s_col;
                global_last_reg <= s_global_last;
            end
        end
    end

endmodule
