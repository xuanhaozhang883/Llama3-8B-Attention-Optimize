// CATS-R4 A2 local checkpoint: scheduler + FP32 service + score FIFO.
//
// This wrapper keeps the previously checked scheduler interface, connects it
// to the real 32-lane FP32 accumulator service, and buffers one score vector
// per active row so output backpressure cannot lose a completion.  It remains
// a local candidate and is not in the production source manifest.
module cats_r4_qk_32lane_engine #(
    parameter int SEQ_LEN  = 128,
    parameter int HEAD_DIM = 128,
    parameter int CONTEXTS = 16,
    parameter int LANES    = 32
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic counter_clear,

    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_epoch,
    input logic [2:0] start_group,
    input logic [4:0] start_global_q_head,
    input logic [2:0] start_row_window,
    input logic [4:0] start_row_count,
    input logic [1:0] start_key_block,

    output logic done_valid,
    input logic done_ready,
    output logic [15:0] done_epoch,
    output logic [2:0] done_group,
    output logic [4:0] done_global_q_head,
    output logic [2:0] done_row_window,
    output logic [1:0] done_key_block,
    output logic done_error,

    output logic q_req_valid,
    input logic q_req_ready,
    output logic [3:0] q_req_context_tag,
    output logic [6:0] q_req_d,
    input logic q_rsp_valid,
    input logic [3:0] q_rsp_context_tag,
    input logic [15:0] q_rsp_bf16,

    output logic k_req_valid,
    input logic k_req_ready,
    output logic [3:0] k_req_context_tag,
    output logic [1:0] k_req_key_block,
    output logic [6:0] k_req_d,
    input logic k_rsp_valid,
    input logic [3:0] k_rsp_context_tag,
    input logic [511:0] k_rsp_vec,

    output logic score_valid,
    input logic score_ready,
    output logic [15:0] score_epoch,
    output logic [2:0] score_group,
    output logic [4:0] score_global_q_head,
    output logic [6:0] score_row,
    output logic [1:0] score_key_block,
    output logic [3:0] score_context_tag,
    output logic [LANES-1:0] score_lane_valid,
    output logic [LANES*32-1:0] score_fp32,

    output logic [63:0] q_requests_accepted,
    output logic [63:0] k_requests_accepted,
    output logic [63:0] mac_steps_issued,
    output logic [63:0] mac_steps_completed,
    output logic [63:0] valid_macs,
    output logic [63:0] causal_lane_bubbles,
    output logic [63:0] causal_rows_skipped,
    output logic [63:0] memory_request_stalls,
    output logic [63:0] mac_issue_stalls,
    output logic [63:0] scheduler_protocol_errors,
    output logic scheduler_protocol_error_sticky,
    output logic [63:0] fp32_requests_accepted,
    output logic [63:0] fp32_mul_products_completed,
    output logic [63:0] fp32_add_results_completed,
    output logic [63:0] fp32_response_transfers,
    output logic [63:0] fp32_protocol_errors,
    output logic fp32_protocol_error_sticky,
    output logic [63:0] score_commits,
    output logic [63:0] score_commit_stalls,
    output logic [63:0] score_fifo_max_occupancy
);
    logic sched_mac_valid;
    logic sched_mac_ready;
    logic [15:0] sched_mac_epoch;
    logic [2:0] sched_mac_group;
    logic [4:0] sched_mac_head;
    logic [6:0] sched_mac_row;
    logic [1:0] sched_mac_key_block;
    logic [3:0] sched_mac_context;
    logic [6:0] sched_mac_d;
    logic [LANES-1:0] sched_mac_lane_valid;
    logic sched_mac_first, sched_mac_last;
    logic [15:0] sched_mac_q;
    logic [LANES*16-1:0] sched_mac_k;

    logic sched_rsp_valid, sched_rsp_ready;
    logic [15:0] sched_rsp_epoch;
    logic [2:0] sched_rsp_group;
    logic [4:0] sched_rsp_head;
    logic [6:0] sched_rsp_row;
    logic [1:0] sched_rsp_key_block;
    logic [3:0] sched_rsp_context;
    logic [6:0] sched_rsp_d;

    logic service_rsp_valid, service_rsp_ready;
    logic [15:0] service_rsp_epoch;
    logic [2:0] service_rsp_group;
    logic [4:0] service_rsp_head;
    logic [6:0] service_rsp_row;
    logic [1:0] service_rsp_key_block;
    logic [3:0] service_rsp_context;
    logic [6:0] service_rsp_d;
    logic service_rsp_score_valid;
    logic [LANES-1:0] service_rsp_lane_valid;
    logic [LANES*32-1:0] service_rsp_score_fp32;

    logic sched_start_ready;
    logic [3:0] score_wr_ptr, score_rd_ptr;
    logic [4:0] score_count;


    cats_r4_qk_32lane_scheduler #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .CONTEXTS(CONTEXTS),
        .LANES(LANES)
    ) u_scheduler (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .start_valid(start_valid && (score_count == 0)),
        .start_ready(sched_start_ready),
        .start_epoch,
        .start_group,
        .start_global_q_head,
        .start_row_window,
        .start_row_count,
        .start_key_block,
        .done_valid,
        .done_ready,
        .done_epoch,
        .done_group,
        .done_global_q_head,
        .done_row_window,
        .done_key_block,
        .done_error,
        .q_req_valid,
        .q_req_ready,
        .q_req_context_tag,
        .q_req_d,
        .q_rsp_valid,
        .q_rsp_context_tag,
        .q_rsp_bf16,
        .k_req_valid,
        .k_req_ready,
        .k_req_context_tag,
        .k_req_key_block,
        .k_req_d,
        .k_rsp_valid,
        .k_rsp_context_tag,
        .k_rsp_vec,
        .mac_valid(sched_mac_valid),
        .mac_ready(sched_mac_ready),
        .mac_epoch(sched_mac_epoch),
        .mac_group(sched_mac_group),
        .mac_global_q_head(sched_mac_head),
        .mac_row(sched_mac_row),
        .mac_key_block(sched_mac_key_block),
        .mac_context_tag(sched_mac_context),
        .mac_d(sched_mac_d),
        .mac_lane_valid(sched_mac_lane_valid),
        .mac_first(sched_mac_first),
        .mac_last(sched_mac_last),
        .mac_q_bf16(sched_mac_q),
        .mac_k_vec(sched_mac_k),
        .mac_rsp_valid(sched_rsp_valid),
        .mac_rsp_ready(sched_rsp_ready),
        .mac_rsp_epoch(sched_rsp_epoch),
        .mac_rsp_group(sched_rsp_group),
        .mac_rsp_global_q_head(sched_rsp_head),
        .mac_rsp_row(sched_rsp_row),
        .mac_rsp_key_block(sched_rsp_key_block),
        .mac_rsp_context_tag(sched_rsp_context),
        .mac_rsp_d(sched_rsp_d),
        .q_requests_accepted,
        .k_requests_accepted,
        .mac_steps_issued,
        .mac_steps_completed,
        .valid_macs,
        .causal_lane_bubbles,
        .causal_rows_skipped,
        .memory_request_stalls,
        .mac_issue_stalls,
        .protocol_errors(scheduler_protocol_errors),
        .protocol_error_sticky(scheduler_protocol_error_sticky)
    );

    assign start_ready = sched_start_ready && (score_count == 0);

    cats_r4_qk_32lane_fp32_service #(
        .CONTEXTS(CONTEXTS),
        .LANES(LANES),
        .HEAD_DIM(HEAD_DIM)
    ) u_fp32_service (
        .clk,
        .rst_n,
        .clear,
        .req_valid(sched_mac_valid),
        .req_ready(sched_mac_ready),
        .req_epoch(sched_mac_epoch),
        .req_group(sched_mac_group),
        .req_global_q_head(sched_mac_head),
        .req_row(sched_mac_row),
        .req_key_block(sched_mac_key_block),
        .req_context_tag(sched_mac_context),
        .req_d(sched_mac_d),
        .req_lane_valid(sched_mac_lane_valid),
        .req_first(sched_mac_first),
        .req_last(sched_mac_last),
        .req_q_bf16(sched_mac_q),
        .req_k_vec(sched_mac_k),
        .rsp_valid(service_rsp_valid),
        .rsp_ready(service_rsp_ready),
        .rsp_epoch(service_rsp_epoch),
        .rsp_group(service_rsp_group),
        .rsp_global_q_head(service_rsp_head),
        .rsp_row(service_rsp_row),
        .rsp_key_block(service_rsp_key_block),
        .rsp_context_tag(service_rsp_context),
        .rsp_d(service_rsp_d),
        .rsp_score_valid(service_rsp_score_valid),
        .rsp_lane_valid(service_rsp_lane_valid),
        .rsp_score_fp32(service_rsp_score_fp32),
        .requests_accepted(fp32_requests_accepted),
        .mul_products_completed(fp32_mul_products_completed),
        .add_results_completed(fp32_add_results_completed),
        .response_transfers(fp32_response_transfers),
        .protocol_errors(fp32_protocol_errors),
        .protocol_error_sticky(fp32_protocol_error_sticky)
    );

    // One-entry tagged response buffer between the service and scheduler.
    logic response_buf_valid;
    logic [15:0] response_buf_epoch;
    logic [2:0] response_buf_group;
    logic [4:0] response_buf_head;
    logic [6:0] response_buf_row;
    logic [1:0] response_buf_key_block;
    logic [3:0] response_buf_context;
    logic [6:0] response_buf_d;
    logic response_buf_score_valid;
    logic [LANES-1:0] response_buf_lane_valid;
    logic [LANES*32-1:0] response_buf_score_fp32;

    logic score_fifo_full;
    logic score_fifo_empty;
    logic response_buf_visible;
    logic response_buf_pop;
    logic score_push;
    logic score_pop;


    logic [15:0] score_epoch_mem [0:15];
    logic [2:0] score_group_mem [0:15];
    logic [4:0] score_head_mem [0:15];
    logic [6:0] score_row_mem [0:15];
    logic [1:0] score_key_block_mem [0:15];
    logic [3:0] score_context_mem [0:15];
    logic [LANES-1:0] score_lane_valid_mem [0:15];
    logic [LANES*32-1:0] score_fp32_mem [0:15];

    assign score_fifo_full = (score_count == 5'd16);
    assign score_fifo_empty = (score_count == 5'd0);
    assign response_buf_visible =
        response_buf_valid &&
        (!response_buf_score_valid || !score_fifo_full);
    assign sched_rsp_valid = response_buf_visible;
    assign sched_rsp_epoch = response_buf_epoch;
    assign sched_rsp_group = response_buf_group;
    assign sched_rsp_head = response_buf_head;
    assign sched_rsp_row = response_buf_row;
    assign sched_rsp_key_block = response_buf_key_block;
    assign sched_rsp_context = response_buf_context;
    assign sched_rsp_d = response_buf_d;
    assign response_buf_pop = response_buf_visible && sched_rsp_ready;
    assign service_rsp_ready = !response_buf_valid || response_buf_pop;
    assign score_push = response_buf_pop && response_buf_score_valid;
    assign score_pop = !score_fifo_empty && score_ready;
    assign score_valid = !score_fifo_empty;

    assign score_epoch = score_epoch_mem[score_rd_ptr];
    assign score_group = score_group_mem[score_rd_ptr];
    assign score_global_q_head = score_head_mem[score_rd_ptr];
    assign score_row = score_row_mem[score_rd_ptr];
    assign score_key_block = score_key_block_mem[score_rd_ptr];
    assign score_context_tag = score_context_mem[score_rd_ptr];
    assign score_lane_valid = score_lane_valid_mem[score_rd_ptr];
    assign score_fp32 = score_fp32_mem[score_rd_ptr];

    always_ff @(posedge clk) begin : p_wrapper
        integer fifo_index;
        if (!rst_n || clear) begin
            response_buf_valid <= 1'b0;
            response_buf_epoch <= '0;
            response_buf_group <= '0;
            response_buf_head <= '0;
            response_buf_row <= '0;
            response_buf_key_block <= '0;
            response_buf_context <= '0;
            response_buf_d <= '0;
            response_buf_score_valid <= 1'b0;
            response_buf_lane_valid <= '0;
            response_buf_score_fp32 <= '0;
            score_wr_ptr <= '0;
            score_rd_ptr <= '0;
            score_count <= '0;
            score_commits <= '0;
            score_commit_stalls <= '0;
            score_fifo_max_occupancy <= '0;
        end else begin
            if (score_valid && !score_ready)
                score_commit_stalls <= score_commit_stalls + 1'b1;

            if (service_rsp_valid && service_rsp_ready) begin
                response_buf_valid <= 1'b1;
                response_buf_epoch <= service_rsp_epoch;
                response_buf_group <= service_rsp_group;
                response_buf_head <= service_rsp_head;
                response_buf_row <= service_rsp_row;
                response_buf_key_block <= service_rsp_key_block;
                response_buf_context <= service_rsp_context;
                response_buf_d <= service_rsp_d;
                response_buf_score_valid <= service_rsp_score_valid;
                response_buf_lane_valid <= service_rsp_lane_valid;
                response_buf_score_fp32 <= service_rsp_score_fp32;
            end else if (response_buf_pop) begin
                response_buf_valid <= 1'b0;
            end

            if (score_push) begin
                score_epoch_mem[score_wr_ptr] <= response_buf_epoch;
                score_group_mem[score_wr_ptr] <= response_buf_group;
                score_head_mem[score_wr_ptr] <= response_buf_head;
                score_row_mem[score_wr_ptr] <= response_buf_row;
                score_key_block_mem[score_wr_ptr] <= response_buf_key_block;
                score_context_mem[score_wr_ptr] <= response_buf_context;
                score_lane_valid_mem[score_wr_ptr] <= response_buf_lane_valid;
                score_fp32_mem[score_wr_ptr] <= response_buf_score_fp32;
                score_wr_ptr <= score_wr_ptr + 1'b1;
                score_commits <= score_commits + 1'b1;
            end
            if (score_pop)
                score_rd_ptr <= score_rd_ptr + 1'b1;

            case ({score_push, score_pop})
                2'b10: score_count <= score_count + 1'b1;
                2'b01: score_count <= score_count - 1'b1;
                default: score_count <= score_count;
            endcase

            if (score_count > score_fifo_max_occupancy)
                score_fifo_max_occupancy <= score_count;
        end
    end
endmodule
