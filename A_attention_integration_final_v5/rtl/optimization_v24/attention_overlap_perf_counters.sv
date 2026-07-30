`timescale 1ns/1ps

// Cycle and ordered-output counters for the inter-Group overlap engine.
module attention_overlap_perf_counters #(
    parameter int NUM_GROUPS = 8,
    parameter int Q_HEADS    = 4,
    parameter int SEQ_LEN    = 128,
    parameter int HEAD_DIM   = 128,
    parameter int GROUP_W =
        (NUM_GROUPS <= 1) ? 1 : $clog2(NUM_GROUPS),
    parameter int HEAD_W =
        (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int POS_W =
        (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W =
        (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic command_start,
    input  logic command_busy,
    input  logic command_done,

    input  logic bc_busy,
    input  logic pv_busy,
    input  logic bc_wait_for_empty_bank,
    input  logic pv_wait_for_ready_bank,

    input  logic context_valid,
    input  logic context_ready,
    input  logic [GROUP_W-1:0] context_group_id,
    input  logic [HEAD_W-1:0] context_head,
    input  logic [POS_W-1:0] context_row,
    input  logic [DIM_W-1:0] context_col,

    input  logic child_protocol_error,

    output logic [63:0] total_cycles,
    output logic [63:0] bc_cycles,
    output logic [63:0] pv_cycles,
    output logic [63:0] overlap_cycles,
    output logic [63:0] bank_full_wait_cycles,
    output logic [63:0] bank_empty_wait_cycles,
    output logic [31:0] context_count,
    output logic [31:0] duplicate_count,
    output logic [31:0] missing_count,
    output logic [31:0] error_bitmap
);

    localparam longint unsigned TOTAL_OUTPUTS =
        NUM_GROUPS * Q_HEADS * SEQ_LEN * HEAD_DIM;

    logic context_fire;
    logic context_legal;
    logic [63:0] context_linear_index;
    logic [63:0] expected_linear_index;
    logic [63:0] expected_after_context;
    logic [63:0] missing_gap;

    always_comb begin
        context_fire =
            context_valid && context_ready;

        context_legal =
            ($unsigned(context_group_id) < NUM_GROUPS) &&
            ($unsigned(context_head) < Q_HEADS) &&
            ($unsigned(context_row) < SEQ_LEN) &&
            ($unsigned(context_col) < HEAD_DIM);

        context_linear_index =
            ((($unsigned(context_group_id) * Q_HEADS +
               $unsigned(context_head)) * SEQ_LEN +
              $unsigned(context_row)) * HEAD_DIM) +
            $unsigned(context_col);

        expected_after_context = expected_linear_index;
        missing_gap             = '0;

        if (context_fire && context_legal &&
            (context_linear_index >= expected_linear_index)) begin
            expected_after_context = context_linear_index + 1'b1;
            missing_gap =
                context_linear_index - expected_linear_index;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            total_cycles           <= '0;
            bc_cycles              <= '0;
            pv_cycles              <= '0;
            overlap_cycles         <= '0;
            bank_full_wait_cycles  <= '0;
            bank_empty_wait_cycles <= '0;
            context_count          <= '0;
            duplicate_count        <= '0;
            missing_count          <= '0;
            expected_linear_index  <= '0;
            error_bitmap           <= '0;
        end else if (command_start) begin
            total_cycles           <= '0;
            bc_cycles              <= '0;
            pv_cycles              <= '0;
            overlap_cycles         <= '0;
            bank_full_wait_cycles  <= '0;
            bank_empty_wait_cycles <= '0;
            context_count          <= '0;
            duplicate_count        <= '0;
            missing_count          <= '0;
            expected_linear_index  <= '0;
            error_bitmap           <= '0;
        end else begin
            if (command_busy)
                total_cycles <= total_cycles + 1'b1;

            if (command_busy && bc_busy)
                bc_cycles <= bc_cycles + 1'b1;

            if (command_busy && pv_busy)
                pv_cycles <= pv_cycles + 1'b1;

            if (command_busy && bc_busy && pv_busy)
                overlap_cycles <= overlap_cycles + 1'b1;

            if (command_busy && bc_wait_for_empty_bank)
                bank_full_wait_cycles <=
                    bank_full_wait_cycles + 1'b1;

            if (command_busy && pv_wait_for_ready_bank)
                bank_empty_wait_cycles <=
                    bank_empty_wait_cycles + 1'b1;

            if (context_fire) begin
                context_count <= context_count + 1'b1;

                if (!context_legal) begin
                    error_bitmap[2] <= 1'b1;
                end else if (context_linear_index <
                             expected_linear_index) begin
                    duplicate_count  <= duplicate_count + 1'b1;
                    error_bitmap[0]  <= 1'b1;
                end else begin
                    expected_linear_index <= expected_after_context;

                    if (missing_gap != 0) begin
                        missing_count <=
                            missing_count + missing_gap[31:0];
                        error_bitmap[1] <= 1'b1;
                    end
                end
            end

            if (child_protocol_error)
                error_bitmap[4] <= 1'b1;

            if (command_done) begin
                if (expected_after_context < TOTAL_OUTPUTS) begin
                    missing_count <=
                        missing_count +
                        missing_gap[31:0] +
                        (TOTAL_OUTPUTS -
                         expected_after_context);
                    error_bitmap[1] <= 1'b1;
                end

                if ((context_count +
                     (context_fire ? 1 : 0)) != TOTAL_OUTPUTS)
                    error_bitmap[3] <= 1'b1;
            end
        end
    end

endmodule
