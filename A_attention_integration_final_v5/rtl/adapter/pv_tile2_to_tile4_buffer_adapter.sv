`timescale 1ns/1ps

// ============================================================================
// pv_tile2_to_tile4_buffer_adapter
// ----------------------------------------------------------------------------
// Preserves the formally delivered B+C v5 interface (PV_TILE=2) and repacks
// one complete GQA Group for the uploaded real PV core (TILE=4).
//
// B+C TILE2 order:
//   head -> row_base(step2) -> feature_base(step2) -> reduce
//
// Real PV TILE4 request order:
//   head -> row_base(step4) -> col_base(step4) -> reduce
//
// The two orders cannot be joined by simple wire concatenation. This adapter
// captures one complete Group into four P banks and four V banks, then serves
// the real PV engine according to its request metadata.
//
// P is written only when feature_base==0 because B+C repeats the same P rows
// for every feature tile.
// V is written only when head==0 && row_base==0 because B+C repeats the same V
// values for every Q head and row tile.
// ============================================================================
module pv_tile2_to_tile4_buffer_adapter #(
    parameter int SEQ_LEN      = 128,
    parameter int HEAD_DIM     = 128,
    parameter int Q_HEADS      = 4,
    parameter int GQA_GROUPS   = 8,
    parameter int HEAD_W       =
        (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W      =
        (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W =
        ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
        $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W        =
        (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W        =
        (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic capture_start,
    input  logic [GROUP_W-1:0] expected_group_id,

    // B+C v5 TILE2 stream.
    input  logic [31:0] in_p_vec_bf16,
    input  logic [31:0] in_v_vec_bf16,
    input  logic in_valid,
    output logic in_ready,
    input  logic in_first,
    input  logic in_last,
    input  logic in_group_last,
    input  logic [GROUP_W-1:0] in_group_id,
    input  logic [HEAD_W-1:0] in_head,
    input  logic [GLOBAL_Q_HEAD_W-1:0] in_global_q_head,
    input  logic [POS_W-1:0] in_row_base,
    input  logic [DIM_W-1:0] in_feature_base,
    input  logic [POS_W-1:0] in_reduce_index,

    output logic capture_complete,
    output logic capture_done,

    // Real TILE4 PV request/replay boundary.
    input  logic feed_enable,
    input  logic [HEAD_W-1:0] req_head,
    input  logic [POS_W-1:0] req_row_base,
    input  logic [DIM_W-1:0] req_col_base,
    input  logic [POS_W-1:0] req_reduce,

    output logic [63:0] out_p_vec_bf16,
    output logic [63:0] out_v_vec_bf16,
    output logic out_valid,
    input  logic out_ready,

    output logic protocol_error
);

    localparam int ROW_TILES4 = SEQ_LEN / 4;
    localparam int COL_TILES4 = HEAD_DIM / 4;

    localparam int P_BANK_DEPTH =
        Q_HEADS * ROW_TILES4 * SEQ_LEN;
    localparam int V_BANK_DEPTH =
        SEQ_LEN * COL_TILES4;

    logic [15:0] p_bank0 [0:P_BANK_DEPTH-1];
    logic [15:0] p_bank1 [0:P_BANK_DEPTH-1];
    logic [15:0] p_bank2 [0:P_BANK_DEPTH-1];
    logic [15:0] p_bank3 [0:P_BANK_DEPTH-1];

    logic [15:0] v_bank0 [0:V_BANK_DEPTH-1];
    logic [15:0] v_bank1 [0:V_BANK_DEPTH-1];
    logic [15:0] v_bank2 [0:V_BANK_DEPTH-1];
    logic [15:0] v_bank3 [0:V_BANK_DEPTH-1];

    logic capturing;

    logic [HEAD_W-1:0] expected_head;
    logic [POS_W-1:0] expected_row_base2;
    logic [DIM_W-1:0] expected_feature_base2;
    logic [POS_W-1:0] expected_reduce;

    logic expected_first;
    logic expected_last;
    logic expected_group_last;
    logic [GLOBAL_Q_HEAD_W-1:0] expected_global_q_head;

    integer p_write_addr;
    integer v_write_addr;
    integer p_read_addr;
    integer v_read_addr;

    logic request_legal;

    assign in_ready = capturing && !capture_complete;

    always_comb begin
        expected_first = (expected_reduce == 0);
        expected_last  =
            ($unsigned(expected_reduce) == SEQ_LEN-1);
        expected_group_last =
            ($unsigned(expected_head) == Q_HEADS-1) &&
            ($unsigned(expected_row_base2) == SEQ_LEN-2) &&
            ($unsigned(expected_feature_base2) == HEAD_DIM-2) &&
            ($unsigned(expected_reduce) == SEQ_LEN-1);

        expected_global_q_head =
            ($unsigned(expected_group_id) * Q_HEADS) +
            $unsigned(expected_head);

        p_write_addr =
            (($unsigned(in_head) * ROW_TILES4 +
              ($unsigned(in_row_base) >> 2)) * SEQ_LEN) +
            $unsigned(in_reduce_index);

        v_write_addr =
            ($unsigned(in_reduce_index) * COL_TILES4) +
            ($unsigned(in_feature_base) >> 2);

        p_read_addr =
            (($unsigned(req_head) * ROW_TILES4 +
              ($unsigned(req_row_base) >> 2)) * SEQ_LEN) +
            $unsigned(req_reduce);

        v_read_addr =
            ($unsigned(req_reduce) * COL_TILES4) +
            ($unsigned(req_col_base) >> 2);

        request_legal =
            ($unsigned(req_head) < Q_HEADS) &&
            ($unsigned(req_row_base) < SEQ_LEN) &&
            ($unsigned(req_col_base) < HEAD_DIM) &&
            ($unsigned(req_reduce) < SEQ_LEN) &&
            (($unsigned(req_row_base) & 3) == 0) &&
            (($unsigned(req_col_base) & 3) == 0);

        out_valid = feed_enable && capture_complete && request_legal;

        out_p_vec_bf16 = {
            p_bank3[p_read_addr],
            p_bank2[p_read_addr],
            p_bank1[p_read_addr],
            p_bank0[p_read_addr]
        };

        out_v_vec_bf16 = {
            v_bank3[v_read_addr],
            v_bank2[v_read_addr],
            v_bank1[v_read_addr],
            v_bank0[v_read_addr]
        };
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            capturing                <= 1'b0;
            capture_complete         <= 1'b0;
            capture_done             <= 1'b0;
            protocol_error           <= 1'b0;
            expected_head            <= '0;
            expected_row_base2       <= '0;
            expected_feature_base2   <= '0;
            expected_reduce          <= '0;
        end else begin
            capture_done <= 1'b0;

            if (capture_start) begin
                capturing              <= 1'b1;
                capture_complete       <= 1'b0;
                protocol_error         <= 1'b0;
                expected_head          <= '0;
                expected_row_base2     <= '0;
                expected_feature_base2 <= '0;
                expected_reduce        <= '0;
            end

            if (feed_enable && !request_legal)
                protocol_error <= 1'b1;

            if (in_valid && in_ready) begin
                if ((in_group_id        != expected_group_id) ||
                    (in_head            != expected_head) ||
                    (in_global_q_head   != expected_global_q_head) ||
                    (in_row_base        != expected_row_base2) ||
                    (in_feature_base    != expected_feature_base2) ||
                    (in_reduce_index    != expected_reduce) ||
                    (in_first           != expected_first) ||
                    (in_last            != expected_last) ||
                    (in_group_last      != expected_group_last)) begin
                    protocol_error <= 1'b1;
                end

                // Store each P scalar once.
                if ($unsigned(in_feature_base) == 0) begin
                    case ($unsigned(in_row_base) & 3)
                        0: begin
                            p_bank0[p_write_addr] <= in_p_vec_bf16[15:0];
                            p_bank1[p_write_addr] <= in_p_vec_bf16[31:16];
                        end
                        2: begin
                            p_bank2[p_write_addr] <= in_p_vec_bf16[15:0];
                            p_bank3[p_write_addr] <= in_p_vec_bf16[31:16];
                        end
                        default: protocol_error <= 1'b1;
                    endcase
                end

                // Store each V scalar once.
                if (($unsigned(in_head) == 0) &&
                    ($unsigned(in_row_base) == 0)) begin
                    case ($unsigned(in_feature_base) & 3)
                        0: begin
                            v_bank0[v_write_addr] <= in_v_vec_bf16[15:0];
                            v_bank1[v_write_addr] <= in_v_vec_bf16[31:16];
                        end
                        2: begin
                            v_bank2[v_write_addr] <= in_v_vec_bf16[15:0];
                            v_bank3[v_write_addr] <= in_v_vec_bf16[31:16];
                        end
                        default: protocol_error <= 1'b1;
                    endcase
                end

                if (expected_group_last) begin
                    capturing        <= 1'b0;
                    capture_complete <= 1'b1;
                    capture_done     <= 1'b1;
                end else if ($unsigned(expected_reduce) < SEQ_LEN-1) begin
                    expected_reduce <= expected_reduce + 1'b1;
                end else begin
                    expected_reduce <= '0;

                    if ($unsigned(expected_feature_base2) <
                        HEAD_DIM-2) begin
                        expected_feature_base2 <=
                            expected_feature_base2 + 2;
                    end else begin
                        expected_feature_base2 <= '0;

                        if ($unsigned(expected_row_base2) <
                            SEQ_LEN-2) begin
                            expected_row_base2 <=
                                expected_row_base2 + 2;
                        end else begin
                            expected_row_base2 <= '0;
                            expected_head      <= expected_head + 1'b1;
                        end
                    end
                end
            end
        end
    end

    initial begin
        if ((SEQ_LEN % 4) != 0)
            $error("pv_tile2_to_tile4_buffer_adapter: SEQ_LEN must divide by 4");

        if ((HEAD_DIM % 4) != 0)
            $error("pv_tile2_to_tile4_buffer_adapter: HEAD_DIM must divide by 4");

        if (Q_HEADS != 4)
            $error("pv_tile2_to_tile4_buffer_adapter: Q_HEADS must equal 4");
    end

endmodule
