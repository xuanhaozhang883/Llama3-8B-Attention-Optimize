`timescale 1ns/1ps

// Preserves B-side row metadata across the existing softmax_bf16, whose output
// stream contains only probability data and out_last. The current Softmax
// accepts one row and emits that row before accepting the next, so one metadata
// entry is sufficient and avoids an unnecessary FIFO in the KV260 baseline.
module softmax_metadata_tracker #(
    parameter int Q_HEADS = 4,
    parameter int SEQ_LEN = 128
) (
    input  logic clk,
    input  logic rst_n,
    input  logic group_start,
    input  logic [2:0] group_id,

    // B-side, row-major score input.
    input  logic        row_valid,
    output logic        row_ready,
    input  logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] row_head,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] row_index,
    input  logic [15:0] row_data,
    input  logic        row_mask,
    input  logic        row_last,

    // Connection to softmax_bf16 input.
    output logic        softmax_in_valid,
    input  logic        softmax_in_ready,
    output logic [15:0] softmax_in_data,
    output logic        softmax_in_mask,
    output logic        softmax_in_last,

    // Connection from softmax_bf16 output.
    input  logic        softmax_out_valid,
    output logic        softmax_out_ready,
    input  logic [15:0] softmax_out_data,
    input  logic        softmax_out_last,

    // C-side probability stream with explicit metadata.
    output logic        prob_valid,
    input  logic        prob_ready,
    output logic [15:0] prob_data,
    output logic [2:0]  prob_group_id,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] prob_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] prob_row,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] prob_col,
    output logic        prob_first,
    output logic        prob_last,
    output logic        prob_group_last,

    output logic        done,
    output logic        busy,
    output logic        protocol_error
);

    localparam int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int SEQ_W  = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);

    logic run_active;
    logic [2:0] group_id_reg;
    logic [HEAD_W-1:0] expected_head;
    logic [SEQ_W-1:0] expected_row;
    logic [SEQ_W-1:0] expected_col;

    logic meta_valid;
    logic [HEAD_W-1:0] meta_head;
    logic [SEQ_W-1:0] meta_row;
    logic [SEQ_W-1:0] out_col;

    assign row_ready       = run_active && softmax_in_ready;
    assign softmax_in_valid = run_active && row_valid;
    assign softmax_in_data  = row_data;
    assign softmax_in_mask  = row_mask;
    assign softmax_in_last  = row_last;

    assign prob_valid      = run_active && meta_valid && softmax_out_valid;
    assign prob_data       = softmax_out_data;
    assign prob_group_id   = group_id_reg;
    assign prob_head       = meta_head;
    assign prob_row        = meta_row;
    assign prob_col        = out_col;
    assign prob_first      = (out_col == 0);
    assign prob_last       = softmax_out_last;
    assign prob_group_last = prob_valid && softmax_out_last &&
                             (meta_head == Q_HEADS-1) &&
                             (meta_row == SEQ_LEN-1);
    assign softmax_out_ready = run_active && meta_valid && prob_ready;

    assign busy = run_active || meta_valid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run_active    <= 1'b0;
            group_id_reg  <= '0;
            expected_head <= '0;
            expected_row  <= '0;
            expected_col  <= '0;
            meta_valid    <= 1'b0;
            meta_head     <= '0;
            meta_row      <= '0;
            out_col       <= '0;
            done          <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (group_start) begin
                if (busy) begin
                    protocol_error <= 1'b1;
                end else begin
                    run_active     <= 1'b1;
                    group_id_reg   <= group_id;
                    expected_head  <= '0;
                    expected_row   <= '0;
                    expected_col   <= '0;
                    meta_valid     <= 1'b0;
                    meta_head      <= '0;
                    meta_row       <= '0;
                    out_col        <= '0;
                    protocol_error <= 1'b0;
                end
            end

            if (row_valid && row_ready) begin
                if ((row_head != expected_head) ||
                    (row_index != expected_row) ||
                    (row_last != (expected_col == SEQ_LEN-1))) begin
                    protocol_error <= 1'b1;
                end

                if (expected_col == SEQ_LEN-1) begin
                    expected_col <= '0;
                    meta_valid   <= 1'b1;
                    meta_head    <= row_head;
                    meta_row     <= row_index;

                    if (expected_row == SEQ_LEN-1) begin
                        expected_row <= '0;
                        expected_head <= expected_head + 1'b1;
                    end else begin
                        expected_row <= expected_row + 1'b1;
                    end
                end else begin
                    expected_col <= expected_col + 1'b1;
                end
            end

            if (softmax_out_valid && !meta_valid)
                protocol_error <= 1'b1;

            if (prob_valid && prob_ready) begin
                if (softmax_out_last != (out_col == SEQ_LEN-1))
                    protocol_error <= 1'b1;

                if (softmax_out_last) begin
                    out_col    <= '0;
                    meta_valid <= 1'b0;

                    if ((meta_head == Q_HEADS-1) &&
                        (meta_row == SEQ_LEN-1)) begin
                        run_active <= 1'b0;
                        done       <= 1'b1;
                    end
                end else begin
                    out_col <= out_col + 1'b1;
                end
            end
        end
    end

    initial begin
        if (Q_HEADS < 1)
            $error("softmax_metadata_tracker: Q_HEADS must be >= 1");
        if (SEQ_LEN < 1)
            $error("softmax_metadata_tracker: SEQ_LEN must be >= 1");
    end

endmodule
