`timescale 1ns/1ps

// Four-row FlashAttention online-softmax tile update.
//
// A complete TILE x TILE score tile is accepted atomically. One independent
// Stage 2A row engine processes each row, so the tile latency is bounded by the
// slowest row while all four exponent pipelines run in parallel. The output is
// held stable under backpressure.
module flash_online_tile_update #(
    parameter integer TILE       = 4,
    parameter integer MAX_LEN    = 128,
    parameter integer SCORE_W    = 24,
    parameter integer SCORE_FRAC = 14,
    parameter integer EXP_W      = 24,
    parameter integer EXP_FRAC   = 23,
    parameter integer L_SUM_W    = EXP_W + $clog2(MAX_LEN + 1),
    parameter EXP_LUT_FILE       = "mem/exp_lut_q23.mem"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         in_valid,
    output logic                         in_ready,
    input  logic [TILE*TILE*16-1:0]      in_scores_bf16,
    input  logic [TILE*TILE-1:0]         in_mask,
    input  logic [TILE-1:0]              in_state_valid,
    input  logic [TILE*SCORE_W-1:0]      in_m_fixed,
    input  logic [TILE*L_SUM_W-1:0]      in_l_q23,

    output logic                         out_valid,
    input  logic                         out_ready,
    output logic [TILE-1:0]              out_state_valid,
    output logic [TILE*SCORE_W-1:0]      out_m_fixed,
    output logic [TILE*L_SUM_W-1:0]      out_l_q23,
    output logic [TILE*EXP_W-1:0]        out_alpha_q23,
    output logic [TILE*16-1:0]           out_alpha_q15,
    output logic [TILE*16-1:0]           out_alpha_bf16,
    output logic [TILE*TILE*EXP_W-1:0]   out_weights_q23,
    output logic [TILE*TILE*16-1:0]      out_weights_q15,
    output logic [TILE*TILE*16-1:0]      out_weights_bf16,
    output logic [TILE*L_SUM_W-1:0]      out_row_sum_q23,
    output logic [TILE-1:0]              out_all_masked_rows,
    output logic [TILE-1:0]              out_numeric_error,
    output logic                         busy
);

    logic [TILE-1:0] row_in_ready;
    logic [TILE-1:0] row_out_valid;
    logic [TILE-1:0] row_out_ready;
    logic [TILE-1:0] row_out_state_valid;
    logic [TILE*SCORE_W-1:0] row_out_m_fixed;
    logic [TILE*L_SUM_W-1:0] row_out_l_q23;
    logic [TILE*EXP_W-1:0] row_out_alpha_q23;
    logic [TILE*16-1:0] row_out_alpha_q15;
    logic [TILE*16-1:0] row_out_alpha_bf16;
    logic [TILE*TILE*EXP_W-1:0] row_out_weights_q23;
    logic [TILE*TILE*16-1:0] row_out_weights_q15;
    logic [TILE*TILE*16-1:0] row_out_weights_bf16;
    logic [TILE*L_SUM_W-1:0] row_out_sum_q23;
    logic [TILE-1:0] row_out_all_masked;
    logic [TILE-1:0] row_out_numeric_error;
    logic [TILE-1:0] row_busy;

    logic [TILE-1:0] row_done;
    logic [TILE-1:0] row_accept;
    logic             collect_active;
    logic             tile_input_fire;

    assign in_ready = rst_n && !collect_active && !out_valid &&
                      (&row_in_ready);
    assign tile_input_fire = in_valid && in_ready;
    assign row_accept = row_out_valid & row_out_ready;
    assign busy = collect_active || out_valid || (|row_busy);

    generate
        genvar row_index;
        for (row_index = 0; row_index < TILE;
             row_index = row_index + 1) begin : g_row_update
            assign row_out_ready[row_index] =
                collect_active && !row_done[row_index];

            flash_online_row_update #(
                .TILE_COLS(TILE),
                .MAX_LEN(MAX_LEN),
                .SCORE_W(SCORE_W),
                .SCORE_FRAC(SCORE_FRAC),
                .EXP_W(EXP_W),
                .EXP_FRAC(EXP_FRAC),
                .L_SUM_W(L_SUM_W),
                .EXP_LUT_FILE(EXP_LUT_FILE)
            ) u_row_update (
                .clk,
                .rst_n,
                .in_valid(tile_input_fire),
                .in_ready(row_in_ready[row_index]),
                .in_scores_bf16(
                    in_scores_bf16[
                        row_index*TILE*16 +: TILE*16]),
                .in_mask(
                    in_mask[row_index*TILE +: TILE]),
                .in_state_valid(in_state_valid[row_index]),
                .in_m_fixed(
                    in_m_fixed[row_index*SCORE_W +: SCORE_W]),
                .in_l_q23(
                    in_l_q23[row_index*L_SUM_W +: L_SUM_W]),
                .out_valid(row_out_valid[row_index]),
                .out_ready(row_out_ready[row_index]),
                .out_state_valid(row_out_state_valid[row_index]),
                .out_m_fixed(
                    row_out_m_fixed[
                        row_index*SCORE_W +: SCORE_W]),
                .out_l_q23(
                    row_out_l_q23[
                        row_index*L_SUM_W +: L_SUM_W]),
                .out_alpha_q23(
                    row_out_alpha_q23[
                        row_index*EXP_W +: EXP_W]),
                .out_alpha_q15(
                    row_out_alpha_q15[row_index*16 +: 16]),
                .out_alpha_bf16(
                    row_out_alpha_bf16[row_index*16 +: 16]),
                .out_weights_q23(
                    row_out_weights_q23[
                        row_index*TILE*EXP_W +: TILE*EXP_W]),
                .out_weights_q15(
                    row_out_weights_q15[
                        row_index*TILE*16 +: TILE*16]),
                .out_weights_bf16(
                    row_out_weights_bf16[
                        row_index*TILE*16 +: TILE*16]),
                .out_row_sum_q23(
                    row_out_sum_q23[
                        row_index*L_SUM_W +: L_SUM_W]),
                .out_all_masked_tile(
                    row_out_all_masked[row_index]),
                .out_numeric_error(
                    row_out_numeric_error[row_index]),
                .busy(row_busy[row_index])
            );
        end
    endgenerate

    integer capture_row;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            collect_active <= 1'b0;
            row_done <= '0;
            out_valid <= 1'b0;
            out_state_valid <= '0;
            out_m_fixed <= '0;
            out_l_q23 <= '0;
            out_alpha_q23 <= '0;
            out_alpha_q15 <= '0;
            out_alpha_bf16 <= '0;
            out_weights_q23 <= '0;
            out_weights_q15 <= '0;
            out_weights_bf16 <= '0;
            out_row_sum_q23 <= '0;
            out_all_masked_rows <= '0;
            out_numeric_error <= '0;
        end else begin
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (tile_input_fire) begin
                collect_active <= 1'b1;
                row_done <= '0;
            end

            if (collect_active) begin
                for (capture_row = 0; capture_row < TILE;
                     capture_row = capture_row + 1) begin
                    if (row_accept[capture_row]) begin
                        row_done[capture_row] <= 1'b1;
                        out_state_valid[capture_row] <=
                            row_out_state_valid[capture_row];
                        out_m_fixed[
                            capture_row*SCORE_W +: SCORE_W] <=
                            row_out_m_fixed[
                                capture_row*SCORE_W +: SCORE_W];
                        out_l_q23[
                            capture_row*L_SUM_W +: L_SUM_W] <=
                            row_out_l_q23[
                                capture_row*L_SUM_W +: L_SUM_W];
                        out_alpha_q23[
                            capture_row*EXP_W +: EXP_W] <=
                            row_out_alpha_q23[
                                capture_row*EXP_W +: EXP_W];
                        out_alpha_q15[capture_row*16 +: 16] <=
                            row_out_alpha_q15[
                                capture_row*16 +: 16];
                        out_alpha_bf16[capture_row*16 +: 16] <=
                            row_out_alpha_bf16[
                                capture_row*16 +: 16];
                        out_weights_q23[
                            capture_row*TILE*EXP_W +: TILE*EXP_W] <=
                            row_out_weights_q23[
                                capture_row*TILE*EXP_W +: TILE*EXP_W];
                        out_weights_q15[
                            capture_row*TILE*16 +: TILE*16] <=
                            row_out_weights_q15[
                                capture_row*TILE*16 +: TILE*16];
                        out_weights_bf16[
                            capture_row*TILE*16 +: TILE*16] <=
                            row_out_weights_bf16[
                                capture_row*TILE*16 +: TILE*16];
                        out_row_sum_q23[
                            capture_row*L_SUM_W +: L_SUM_W] <=
                            row_out_sum_q23[
                                capture_row*L_SUM_W +: L_SUM_W];
                        out_all_masked_rows[capture_row] <=
                            row_out_all_masked[capture_row];
                        out_numeric_error[capture_row] <=
                            row_out_numeric_error[capture_row];
                    end
                end

                if (&(row_done | row_accept)) begin
                    collect_active <= 1'b0;
                    out_valid <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (TILE != 4)
            $error("flash_online_tile_update requires TILE=4");
        if ((EXP_W != 24) || (EXP_FRAC != 23))
            $error("Stage 2B requires Q1.23 online weights");
    end

endmodule
