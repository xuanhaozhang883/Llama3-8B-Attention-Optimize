`timescale 1ns/1ps

// Sequencing bridge: prepare and cache one rotated Group, then launch the
// unchanged QK->Softmax->PV pipeline and serve all of its vector requests.
module rope_group_bridge #(
    parameter int QK_TILE = 4,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int Q_HEADS = 4,
    parameter int GQA_GROUPS = 8,
    parameter int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W = ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
                                      $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int PAIR_W = ((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2),
    parameter int ROM_DEPTH = SEQ_LEN*(HEAD_DIM/2),
    parameter SIN_ROM_FILE = "sin_bf16.hex",
    parameter COS_ROM_FILE = "cos_bf16.hex"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic group_start,
    input  logic [GROUP_W-1:0] group_id,
    output logic group_start_ready,
    output logic [GROUP_W-1:0] active_group_id,
    output logic busy,
    output logic rope_done,

    output logic raw_req_valid,
    input  logic raw_req_ready,
    output logic raw_req_is_k,
    output logic [GLOBAL_Q_HEAD_W-1:0] raw_req_head,
    output logic [POS_W-1:0] raw_req_token,
    output logic [PAIR_W-1:0] raw_req_pair,
    input  logic raw_rsp_valid,
    output logic raw_rsp_ready,
    input  logic [15:0] raw_rsp_x0,
    input  logic [15:0] raw_rsp_x1,

    output logic pipeline_group_start,
    input  logic pipeline_group_start_ready,
    output logic [GROUP_W-1:0] pipeline_group_id,
    input  logic pipeline_done,
    input  logic [HEAD_W-1:0] req_head,
    input  logic [POS_W-1:0] req_row_base,
    input  logic [POS_W-1:0] req_col_base,
    input  logic [DIM_W-1:0] req_dim,
    input  logic qk_vec_ready,
    output logic qk_vec_valid,
    output logic [QK_TILE*16-1:0] q_vec_bf16,
    output logic [QK_TILE*16-1:0] k_vec_bf16
);
    typedef enum logic [1:0] {S_IDLE, S_PREPARE, S_LAUNCH, S_ACTIVE} state_t;
    state_t state;
    logic [GROUP_W-1:0] group_reg;
    logic prepare_start, prepare_ready, prepare_busy, prepare_done;
    logic cache_clear, cache_complete;
    logic cache_wr_valid, cache_wr_ready, cache_wr_is_k;
    logic [HEAD_W-1:0] cache_wr_head;
    logic [POS_W-1:0] cache_wr_token;
    logic [PAIR_W-1:0] cache_wr_pair;
    logic [15:0] cache_wr_y0, cache_wr_y1;
    logic cache_mark_complete;

    assign group_start_ready = (state == S_IDLE) && prepare_ready;
    assign active_group_id = group_reg;
    assign pipeline_group_id = group_reg;
    assign busy = (state != S_IDLE);

    rope_group_prepare #(
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS), .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W), .POS_W(POS_W), .PAIR_W(PAIR_W),
        .ROM_DEPTH(ROM_DEPTH), .SIN_ROM_FILE(SIN_ROM_FILE),
        .COS_ROM_FILE(COS_ROM_FILE)
    ) u_prepare (
        .clk, .rst_n, .start(prepare_start), .group_id(group_reg),
        .start_ready(prepare_ready), .busy(prepare_busy), .done(prepare_done),
        .cache_clear,
        .raw_req_valid, .raw_req_ready, .raw_req_is_k, .raw_req_head,
        .raw_req_token, .raw_req_pair, .raw_rsp_valid, .raw_rsp_ready,
        .raw_rsp_x0, .raw_rsp_x1,
        .cache_wr_valid, .cache_wr_ready, .cache_wr_is_k, .cache_wr_head,
        .cache_wr_token, .cache_wr_pair, .cache_wr_y0, .cache_wr_y1,
        .cache_mark_complete
    );

    rope_qk_group_cache #(
        .TILE(QK_TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .HEAD_W(HEAD_W), .POS_W(POS_W),
        .DIM_W(DIM_W), .PAIR_W(PAIR_W)
    ) u_cache (
        .clk, .rst_n, .clear(cache_clear),
        .wr_valid(cache_wr_valid), .wr_ready(cache_wr_ready),
        .wr_is_k(cache_wr_is_k), .wr_head(cache_wr_head),
        .wr_token(cache_wr_token), .wr_pair(cache_wr_pair),
        .wr_y0(cache_wr_y0), .wr_y1(cache_wr_y1),
        .mark_complete(cache_mark_complete), .cache_complete,
        .load_enable(state == S_ACTIVE), .req_head, .req_row_base,
        .req_col_base, .req_dim, .vec_valid(qk_vec_valid),
        .vec_ready(qk_vec_ready), .q_vec_bf16, .k_vec_bf16
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            group_reg <= '0;
            prepare_start <= 1'b0;
            pipeline_group_start <= 1'b0;
            rope_done <= 1'b0;
        end else begin
            prepare_start <= 1'b0;
            pipeline_group_start <= 1'b0;
            rope_done <= 1'b0;
            case (state)
                S_IDLE: if (group_start && group_start_ready) begin
                    group_reg <= group_id;
                    prepare_start <= 1'b1;
                    state <= S_PREPARE;
                end
                S_PREPARE: if (prepare_done) begin
                    rope_done <= 1'b1;
                    state <= S_LAUNCH;
                end
                S_LAUNCH: if (pipeline_group_start_ready) begin
                    pipeline_group_start <= 1'b1;
                    state <= S_ACTIVE;
                end
                S_ACTIVE: if (pipeline_done)
                    state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    logic unused_prepare_busy;
    logic unused_cache_complete;
    assign unused_prepare_busy = prepare_busy;
    assign unused_cache_complete = cache_complete;
endmodule
