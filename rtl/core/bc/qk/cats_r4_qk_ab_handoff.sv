`timescale 1ns/1ps

// A-owned serializer between a completed score row and B's row Softmax.
// Score storage remains behind the score_rd_* service owned by C.
module cats_r4_qk_ab_handoff (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,

    input  logic          in_row_valid,
    output logic          in_row_ready,
    input  logic [15:0]   in_row_epoch,
    input  logic [2:0]    in_row_group,
    input  logic [4:0]    in_row_global_q_head,
    input  logic [6:0]    in_row_index,
    input  logic [1:0]    in_row_slot_id,
    input  logic [1:0]    in_row_numeric_mode,
    input  logic [15:0]   in_row_max_bf16,

    output logic          score_rd_req_valid,
    input  logic          score_rd_req_ready,
    output logic [15:0]   score_rd_req_epoch,
    output logic [2:0]    score_rd_req_group,
    output logic [4:0]    score_rd_req_global_q_head,
    output logic [6:0]    score_rd_req_row,
    output logic [1:0]    score_rd_req_slot_id,
    output logic [1:0]    score_rd_req_numeric_mode,
    output logic [6:0]    score_rd_req_key,

    input  logic          score_rd_rsp_valid,
    output logic          score_rd_rsp_ready,
    input  logic [15:0]   score_rd_rsp_epoch,
    input  logic [2:0]    score_rd_rsp_group,
    input  logic [4:0]    score_rd_rsp_global_q_head,
    input  logic [6:0]    score_rd_rsp_row,
    input  logic [1:0]    score_rd_rsp_slot_id,
    input  logic [1:0]    score_rd_rsp_numeric_mode,
    input  logic [6:0]    score_rd_rsp_key,
    input  logic [15:0]   score_rd_rsp_bf16,

    output logic          row_valid,
    input  logic          row_ready,
    output logic [15:0]   row_epoch,
    output logic [2:0]    row_group,
    output logic [4:0]    row_global_q_head,
    output logic [6:0]    row_index,
    output logic [1:0]    row_slot_id,
    output logic [1:0]    row_numeric_mode,
    output logic [15:0]   row_max_bf16,

    output logic          score_valid,
    input  logic          score_ready,
    output logic [15:0]   score_epoch,
    output logic [2:0]    score_group,
    output logic [4:0]    score_global_q_head,
    output logic [6:0]    score_row,
    output logic [1:0]    score_slot_id,
    output logic [1:0]    score_numeric_mode,
    output logic [6:0]    score_key,
    output logic [15:0]   score_bf16,
    output logic          score_last,

    output logic          abort_valid,
    input  logic          abort_ready,
    output logic [15:0]   abort_epoch,
    output logic [2:0]    abort_group,
    output logic [4:0]    abort_global_q_head,
    output logic [6:0]    abort_row,
    output logic [1:0]    abort_slot_id,
    output logic [1:0]    abort_numeric_mode,
    output logic [2:0]    abort_error_code,
    output logic [6:0]    abort_error_key,

    output logic [63:0]   row_headers_transferred,
    output logic [63:0]   score_reads_requested,
    output logic [63:0]   score_reads_returned,
    output logic [63:0]   scores_transferred,
    output logic [63:0]   rows_transferred,
    output logic [63:0]   protocol_errors,
    output logic [63:0]   numeric_errors,
    output logic          protocol_error_sticky
);
    typedef enum logic [2:0] {
        ST_IDLE  = 3'd0,
        ST_ROW   = 3'd1,
        ST_REQ   = 3'd2,
        ST_WAIT  = 3'd3,
        ST_SCORE = 3'd4,
        ST_ABORT = 3'd5
    } state_t;

    state_t state;
    logic [15:0] token_epoch;
    logic [2:0] token_group;
    logic [4:0] token_head;
    logic [6:0] token_row;
    logic [1:0] token_slot;
    logic [1:0] token_mode;
    logic [15:0] token_max;
    logic [6:0] next_key;
    logic [15:0] score_reg;
    logic [2:0] error_code_reg;
    logic [6:0] error_key_reg;
    logic response_token_match;
    logic response_finite;

    assign in_row_ready = state == ST_IDLE;
    assign row_valid = state == ST_ROW;
    assign score_rd_req_valid = state == ST_REQ;
    assign score_rd_rsp_ready = state == ST_WAIT;
    assign score_valid = state == ST_SCORE;

    assign row_epoch = token_epoch;
    assign row_group = token_group;
    assign row_global_q_head = token_head;
    assign row_index = token_row;
    assign row_slot_id = token_slot;
    assign row_numeric_mode = token_mode;
    assign row_max_bf16 = token_max;

    assign score_rd_req_epoch = token_epoch;
    assign score_rd_req_group = token_group;
    assign score_rd_req_global_q_head = token_head;
    assign score_rd_req_row = token_row;
    assign score_rd_req_slot_id = token_slot;
    assign score_rd_req_numeric_mode = token_mode;
    assign score_rd_req_key = next_key;

    assign score_epoch = token_epoch;
    assign score_group = token_group;
    assign score_global_q_head = token_head;
    assign score_row = token_row;
    assign score_slot_id = token_slot;
    assign score_numeric_mode = token_mode;
    assign score_key = next_key;
    assign score_bf16 = score_reg;
    assign score_last = next_key == token_row;

    assign response_token_match =
        score_rd_rsp_epoch == token_epoch &&
        score_rd_rsp_group == token_group &&
        score_rd_rsp_global_q_head == token_head &&
        score_rd_rsp_row == token_row &&
        score_rd_rsp_slot_id == token_slot &&
        score_rd_rsp_numeric_mode == token_mode &&
        score_rd_rsp_key == next_key;
    assign response_finite = score_rd_rsp_bf16[14:7] != 8'hff;
    assign abort_valid = state == ST_ABORT;
    assign abort_epoch = token_epoch;
    assign abort_group = token_group;
    assign abort_global_q_head = token_head;
    assign abort_row = token_row;
    assign abort_slot_id = token_slot;
    assign abort_numeric_mode = token_mode;
    assign abort_error_code = error_code_reg;
    assign abort_error_key = error_key_reg;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            token_epoch <= '0;
            token_group <= '0;
            token_head <= '0;
            token_row <= '0;
            token_slot <= '0;
            token_mode <= '0;
            token_max <= '0;
            next_key <= '0;
            score_reg <= '0;
            error_code_reg <= '0;
            error_key_reg <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (in_row_valid && in_row_ready) begin
                        token_epoch <= in_row_epoch;
                        token_group <= in_row_group;
                        token_head <= in_row_global_q_head;
                        token_row <= in_row_index;
                        token_slot <= in_row_slot_id;
                        token_mode <= in_row_numeric_mode;
                        token_max <= in_row_max_bf16;
                        next_key <= 0;
                        state <= ST_ROW;
                    end
                end
                ST_ROW: begin
                    if (row_valid && row_ready)
                        state <= ST_REQ;
                end
                ST_REQ: begin
                    if (score_rd_req_valid && score_rd_req_ready)
                        state <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (score_rd_rsp_valid && score_rd_rsp_ready) begin
                        if (!response_token_match) begin
                            error_code_reg <= 3'd1;
                            error_key_reg <= score_rd_rsp_key;
                            state <= ST_ABORT;
                        end else if (!response_finite) begin
                            error_code_reg <= 3'd2;
                            error_key_reg <= score_rd_rsp_key;
                            state <= ST_ABORT;
                        end else begin
                            score_reg <= score_rd_rsp_bf16;
                            state <= ST_SCORE;
                        end
                    end
                end
                ST_SCORE: begin
                    if (score_valid && score_ready) begin
                        if (score_last) begin
                            state <= ST_IDLE;
                        end else begin
                            next_key <= next_key + 1'b1;
                            state <= ST_REQ;
                        end
                    end
                end
                ST_ABORT: begin
                    if (abort_valid && abort_ready)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || counter_clear) begin
            row_headers_transferred <= 0;
            score_reads_requested <= 0;
            score_reads_returned <= 0;
            scores_transferred <= 0;
            rows_transferred <= 0;
            protocol_errors <= 0;
            numeric_errors <= 0;
            protocol_error_sticky <= 0;
        end else if (!clear) begin
            if (row_valid && row_ready)
                row_headers_transferred <= row_headers_transferred + 1'b1;
            if (score_rd_req_valid && score_rd_req_ready)
                score_reads_requested <= score_reads_requested + 1'b1;
            if (score_rd_rsp_valid && score_rd_rsp_ready)
                score_reads_returned <= score_reads_returned + 1'b1;
            if (score_rd_rsp_valid && score_rd_rsp_ready &&
                !response_token_match) begin
                protocol_errors <= protocol_errors + 1'b1;
                protocol_error_sticky <= 1'b1;
            end
            if (score_rd_rsp_valid && score_rd_rsp_ready &&
                response_token_match && !response_finite)
                numeric_errors <= numeric_errors + 1'b1;
            if (score_valid && score_ready) begin
                scores_transferred <= scores_transferred + 1'b1;
                if (score_last)
                    rows_transferred <= rows_transferred + 1'b1;
            end
        end
    end

    logic unused_abort_ready;
    assign unused_abort_ready = abort_ready;
endmodule
