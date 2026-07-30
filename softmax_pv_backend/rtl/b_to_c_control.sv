`timescale 1ns/1ps

// Runs the eight Llama3 GQA groups sequentially:
//   B row stream -> metadata tracker -> softmax_bf16 -> C/PV backend.
// B and C receive the same one-cycle group_start and latch the same group_id.
module b_to_c_control #(
    parameter int Q_HEADS = 4,
    parameter int GLOBAL_KV_HEADS = 8,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int TILE = 2,
    parameter EXP_LUT_FILE = "softmax_module/rtl/exp_lut_q15.mem"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,

    // Group launch for the upstream QK->Softmax frontend owner.
    input  logic b_busy,
    input  logic b_protocol_error,
    output logic b_group_start,
    output logic [2:0] b_group_id,

    // B-side row stream, after qk_softmax_adapter.
    input  logic        row_valid,
    output logic        row_ready,
    input  logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] row_head,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] row_index,
    input  logic [15:0] row_data,
    input  logic        row_mask,
    input  logic        row_last,

    // V memory request/response.
    output logic        v_req_valid,
    input  logic        v_req_ready,
    output logic [((GLOBAL_KV_HEADS <= 1) ? 1 : $clog2(GLOBAL_KV_HEADS))-1:0] v_req_kv_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] v_req_reduce_index,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] v_req_feature_base,
    output logic [(((GLOBAL_KV_HEADS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 : $clog2(GLOBAL_KV_HEADS*SEQ_LEN*HEAD_DIM))-1:0] v_req_addr,
    input  logic        v_rsp_valid,
    output logic        v_rsp_ready,
    input  logic [TILE*16-1:0] v_rsp_data,

    // C-side PV vector stream.
    output logic [TILE*16-1:0] p_vec_bf16,
    output logic [TILE*16-1:0] v_vec_bf16,
    output logic        vec_valid,
    input  logic        vec_ready,
    output logic        vec_first,
    output logic        vec_last,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] vec_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] vec_row_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] vec_feature_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] vec_reduce_index,

    output logic        group_done,
    output logic        done,
    output logic        busy,
    output logic [2:0]  active_group_id,
    output logic [3:0]  groups_completed,
    output logic [7:0]  group_error,
    output logic        protocol_error
);

    typedef enum logic [1:0] {
        S_IDLE      = 2'd0,
        S_LAUNCH    = 2'd1,
        S_RUN       = 2'd2,
        S_WAIT_IDLE = 2'd3
    } state_t;

    state_t state;
    logic [2:0] group_id_reg;
    logic b_done_seen;
    logic c_done_seen;
    logic group_fault_seen;
    logic control_error;

    logic tracker_busy;
    logic tracker_done;
    logic tracker_error;
    logic softmax_in_valid;
    logic softmax_in_ready;
    logic [15:0] softmax_in_data;
    logic softmax_in_mask;
    logic softmax_in_last;
    logic softmax_out_valid;
    logic softmax_out_ready;
    logic [15:0] softmax_out_data;
    logic softmax_out_last;
    logic softmax_busy;
    logic softmax_row_error;

    logic prob_valid;
    logic prob_ready;
    logic [15:0] prob_data;
    logic [2:0] prob_group_id;
    logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] prob_head;
    logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] prob_row;
    logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] prob_col;
    logic prob_first;
    logic prob_last;
    logic prob_group_last;

    logic c_done;
    logic c_busy;
    logic c_error;
    logic group_fault_now;

    assign b_group_start = (state == S_LAUNCH);
    assign b_group_id = group_id_reg;
    assign active_group_id = group_id_reg;
    assign group_fault_now = b_protocol_error || tracker_error || c_error ||
                             softmax_row_error;
    // Keep an earlier Group's failure visible through the end of the eight-
    // Group transaction. group_error is reset only when a new top-level run
    // is accepted in S_IDLE.
    assign protocol_error = control_error || group_fault_now || (|group_error);
    assign busy = (state != S_IDLE) || b_busy || tracker_busy || c_busy ||
                  softmax_busy;

    softmax_metadata_tracker #(
        .Q_HEADS(Q_HEADS),
        .SEQ_LEN(SEQ_LEN)
    ) u_metadata_tracker (
        .clk(clk),
        .rst_n(rst_n),
        .group_start(b_group_start),
        .group_id(group_id_reg),
        .row_valid(row_valid),
        .row_ready(row_ready),
        .row_head(row_head),
        .row_index(row_index),
        .row_data(row_data),
        .row_mask(row_mask),
        .row_last(row_last),
        .softmax_in_valid(softmax_in_valid),
        .softmax_in_ready(softmax_in_ready),
        .softmax_in_data(softmax_in_data),
        .softmax_in_mask(softmax_in_mask),
        .softmax_in_last(softmax_in_last),
        .softmax_out_valid(softmax_out_valid),
        .softmax_out_ready(softmax_out_ready),
        .softmax_out_data(softmax_out_data),
        .softmax_out_last(softmax_out_last),
        .prob_valid(prob_valid),
        .prob_ready(prob_ready),
        .prob_data(prob_data),
        .prob_group_id(prob_group_id),
        .prob_head(prob_head),
        .prob_row(prob_row),
        .prob_col(prob_col),
        .prob_first(prob_first),
        .prob_last(prob_last),
        .prob_group_last(prob_group_last),
        .done(tracker_done),
        .busy(tracker_busy),
        .protocol_error(tracker_error)
    );

    softmax_bf16 #(
        .MAX_LEN(SEQ_LEN),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_softmax (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(softmax_in_valid),
        .in_ready(softmax_in_ready),
        .in_data(softmax_in_data),
        .in_last(softmax_in_last),
        .in_mask(softmax_in_mask),
        .out_valid(softmax_out_valid),
        .out_ready(softmax_out_ready),
        .out_data(softmax_out_data),
        .out_last(softmax_out_last),
        .busy(softmax_busy),
        .row_error(softmax_row_error)
    );

    softmax_pv_backend #(
        .Q_HEADS(Q_HEADS),
        .KV_HEADS(1),
        .V_KV_HEADS(GLOBAL_KV_HEADS),
        .USE_GROUP_ID_FOR_KV(1'b1),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .TILE(TILE)
    ) u_c_backend (
        .clk(clk),
        .rst_n(rst_n),
        .start(b_group_start),
        .group_id(group_id_reg),
        .prob_valid(prob_valid),
        .prob_ready(prob_ready),
        .prob_data(prob_data),
        .prob_group_id(prob_group_id),
        .prob_head(prob_head),
        .prob_row(prob_row),
        .prob_col(prob_col),
        .prob_first(prob_first),
        .prob_last(prob_last),
        .prob_group_last(prob_group_last),
        .v_req_valid(v_req_valid),
        .v_req_ready(v_req_ready),
        .v_req_kv_head(v_req_kv_head),
        .v_req_reduce_index(v_req_reduce_index),
        .v_req_feature_base(v_req_feature_base),
        .v_req_addr(v_req_addr),
        .v_rsp_valid(v_rsp_valid),
        .v_rsp_ready(v_rsp_ready),
        .v_rsp_data(v_rsp_data),
        .p_vec_bf16(p_vec_bf16),
        .v_vec_bf16(v_vec_bf16),
        .vec_valid(vec_valid),
        .vec_ready(vec_ready),
        .vec_first(vec_first),
        .vec_last(vec_last),
        .vec_head(vec_head),
        .vec_row_base(vec_row_base),
        .vec_feature_base(vec_feature_base),
        .vec_reduce_index(vec_reduce_index),
        .done(c_done),
        .busy(c_busy),
        .protocol_error(c_error)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            group_id_reg     <= '0;
            b_done_seen      <= 1'b0;
            c_done_seen      <= 1'b0;
            group_fault_seen <= 1'b0;
            control_error    <= 1'b0;
            group_done       <= 1'b0;
            done             <= 1'b0;
            groups_completed <= '0;
            group_error      <= '0;
        end else begin
            group_done <= 1'b0;
            done       <= 1'b0;

            if (start && (state != S_IDLE))
                control_error <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        if (b_busy || tracker_busy || c_busy || softmax_busy) begin
                            control_error <= 1'b1;
                        end else begin
                            group_id_reg     <= '0;
                            groups_completed <= '0;
                            group_error      <= '0;
                            control_error    <= 1'b0;
                            state            <= S_LAUNCH;
                        end
                    end
                end

                S_LAUNCH: begin
                    b_done_seen      <= 1'b0;
                    c_done_seen      <= 1'b0;
                    group_fault_seen <= 1'b0;
                    state            <= S_RUN;
                end

                S_RUN: begin
                    if (tracker_done)
                        b_done_seen <= 1'b1;
                    if (c_done)
                        c_done_seen <= 1'b1;
                    if (group_fault_now)
                        group_fault_seen <= 1'b1;

                    if ((b_done_seen || tracker_done) &&
                        (c_done_seen || c_done)) begin
                        group_error[group_id_reg] <= group_fault_seen ||
                                                     group_fault_now;
                        group_done <= 1'b1;
                        groups_completed <= groups_completed + 1'b1;

                        if (group_id_reg == 3'd7) begin
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            state <= S_WAIT_IDLE;
                        end
                    end
                end

                S_WAIT_IDLE: begin
                    // Do not expose the next Group number while the upstream
                    // B owner is still reporting the current Group busy.
                    // b_group_id therefore remains stable from group_start
                    // through every group's fully-idle boundary.
                    if (!b_busy && !tracker_busy && !c_busy && !softmax_busy) begin
                        group_id_reg <= group_id_reg + 1'b1;
                        state <= S_LAUNCH;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (Q_HEADS != 4)
            $error("b_to_c_control: this Group controller expects Q_HEADS=4");
        if (GLOBAL_KV_HEADS != 8)
            $error("b_to_c_control: this Group controller expects 8 global KV heads");
    end

endmodule
