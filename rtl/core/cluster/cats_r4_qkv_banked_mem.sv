`timescale 1ns/1ps

// CATS-R4 cluster-local Q/K/V memory-service wrapper (CATS_R4_IF_V2).
//
// Contract scope:
//   * S=D=128, BF16 payloads, R=16 Q contexts.
//   * Two buffers with explicit prepare/load/publish/activate ownership.
//   * Q: 4 banks, bank=d[1:0].
//   * K: 32 key banks, lane i is key=32*key_block+i.
//   * V: 32 feature banks, lane i is d=32*feature_block+i.
//   * Accepted core requests have II=1 and produce a non-backpressured
//     response exactly two subsequent core-clock edges later.
//
// The load/control port is intentionally in core_clk for this C2 unit.  A
// later CDC wrapper must bridge AXI-domain writes and ownership messages; this
// module must not be wired directly across clock domains.
module cats_r4_qkv_banked_mem #(
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int CONTEXTS = 16
) (
    input  logic         core_clk,
    input  logic         core_rst_n,
    input  logic         counter_clear,

    // Inactive-buffer ownership protocol.
    input  logic         prep_valid,
    output logic         prep_ready,
    input  logic         prep_buffer,
    input  logic [15:0]  prep_epoch,
    input  logic [2:0]   prep_group,

    input  logic         load_valid,
    output logic         load_ready,
    input  logic         load_buffer,
    input  logic [15:0]  load_epoch,
    input  logic [2:0]   load_group,
    input  logic [4:0]   load_global_q_head,
    input  logic [2:0]   load_row_window,
    input  logic [1:0]   load_kind,       // 0=Q, 1=K, 2=V
    input  logic [3:0]   load_context_tag,
    input  logic [6:0]   load_key,
    input  logic [6:0]   load_d,
    input  logic [15:0]  load_data_bf16,

    input  logic         publish_valid,
    output logic         publish_ready,
    input  logic         publish_buffer,
    input  logic [15:0]  publish_epoch,
    input  logic [2:0]   publish_group,

    input  logic         activate_valid,
    output logic         activate_ready,
    input  logic         activate_buffer,
    input  logic [15:0]  activate_epoch,
    input  logic [2:0]   activate_group,

    output logic         active_valid,
    output logic         active_buffer,
    output logic [15:0]  active_epoch,
    output logic [2:0]   active_group,
    output logic [1:0]   buffer_ready,
    output logic [31:0]  buffer_epoch_flat,
    output logic [5:0]   buffer_group_flat,

    // IF_V2 A/C Q-slab ownership.  The q_fill/q_publish sideband terminates
    // at the cluster-local DMA adapter; it is not an additional A interface.
    input  logic         q_slab_need_valid,
    output logic         q_slab_need_ready,
    input  logic [15:0]  q_slab_need_epoch,
    input  logic [2:0]   q_slab_need_group,
    input  logic [4:0]   q_slab_need_global_q_head,
    input  logic [2:0]   q_slab_need_row_window,

    output logic         q_fill_valid,
    input  logic         q_fill_ready,
    output logic         q_fill_buffer,
    output logic [15:0]  q_fill_epoch,
    output logic [2:0]   q_fill_group,
    output logic [4:0]   q_fill_global_q_head,
    output logic [2:0]   q_fill_row_window,

    input  logic         q_publish_valid,
    output logic         q_publish_ready,
    input  logic         q_publish_buffer,
    input  logic [15:0]  q_publish_epoch,
    input  logic [2:0]   q_publish_group,
    input  logic [4:0]   q_publish_global_q_head,
    input  logic [2:0]   q_publish_row_window,

    output logic         q_slab_ready_valid,
    input  logic         q_slab_ready_ready,
    output logic [15:0]  q_slab_ready_epoch,
    output logic [2:0]   q_slab_ready_group,
    output logic [4:0]   q_slab_ready_global_q_head,
    output logic [2:0]   q_slab_ready_row_window,
    output logic         q_slab_ready_buffer,

    input  logic         q_slab_retire_valid,
    output logic         q_slab_retire_ready,
    input  logic [15:0]  q_slab_retire_epoch,
    input  logic [2:0]   q_slab_retire_group,
    input  logic [4:0]   q_slab_retire_global_q_head,
    input  logic [2:0]   q_slab_retire_row_window,
    input  logic         q_slab_retire_buffer,

    // Frozen Q service.
    input  logic         q_req_valid,
    output logic         q_req_ready,
    input  logic [3:0]   q_req_context_tag,
    input  logic [6:0]   q_req_d,
    output logic         q_rsp_valid,
    output logic [3:0]   q_rsp_context_tag,
    output logic [15:0]  q_rsp_bf16,

    // Frozen K service.
    input  logic         k_req_valid,
    output logic         k_req_ready,
    input  logic [3:0]   k_req_context_tag,
    input  logic [1:0]   k_req_key_block,
    input  logic [6:0]   k_req_d,
    output logic         k_rsp_valid,
    output logic [3:0]   k_rsp_context_tag,
    output logic [511:0] k_rsp_vec,

    // Frozen V service.
    input  logic         v_req_valid,
    output logic         v_req_ready,
    input  logic [3:0]   v_req_context_tag,
    input  logic [6:0]   v_req_key,
    input  logic [1:0]   v_req_feature_block,
    output logic         v_rsp_valid,
    output logic [3:0]   v_rsp_context_tag,
    output logic [511:0] v_rsp_vec,

    output logic [63:0]  q_requests_accepted,
    output logic [63:0]  k_requests_accepted,
    output logic [63:0]  v_requests_accepted,
    output logic [63:0]  active_write_conflicts,
    output logic [63:0]  bank_conflicts,
    output logic [63:0]  protocol_errors,
    output logic         protocol_error_sticky,

    output logic [63:0]  q_slab_need_count,
    output logic [63:0]  q_slab_fill_count,
    output logic [63:0]  q_slab_ready_count,
    output logic [63:0]  q_slab_activate_count,
    output logic [63:0]  q_slab_retire_count,
    output logic [63:0]  q_slab_refill_wait,
    output logic [63:0]  q_slab_reuse_stall,
    output logic [63:0]  q_slab_outstanding_max,
    output logic [63:0]  q_slab_tag_error,
    output logic [63:0]  q_slab_epoch_error,
    output logic [63:0]  q_slab_overwrite_error,
    output logic [63:0]  q_slab_early_retire_error,
    output logic [63:0]  kv_paired_ready_error,
    output logic [63:0]  q_buffer_reuse_stall,
    output logic [63:0]  kv_buffer_reuse_stall
);
    localparam int Q_BANKS = 4;
    localparam int KV_BANKS = 32;
    localparam int Q_BANK_DEPTH = CONTEXTS * (HEAD_DIM/Q_BANKS);
    localparam int KV_BANK_DEPTH = (SEQ_LEN/KV_BANKS) * HEAD_DIM;
    localparam logic [2:0] Q_FREE     = 3'd0;
    localparam logic [2:0] Q_FILLING  = 3'd1;
    localparam logic [2:0] Q_READY    = 3'd2;
    localparam logic [2:0] Q_ACTIVE   = 3'd3;
    localparam logic [2:0] Q_RETIRING = 3'd4;

    (* ram_style = "block" *) logic [15:0] q_mem [0:1][0:Q_BANKS-1][0:Q_BANK_DEPTH-1];
    (* ram_style = "block" *) logic [15:0] k_mem [0:1][0:KV_BANKS-1][0:KV_BANK_DEPTH-1];
    (* ram_style = "block" *) logic [15:0] v_mem [0:1][0:KV_BANKS-1][0:KV_BANK_DEPTH-1];

    logic [1:0]  fill_owned;
    logic [15:0] fill_epoch [0:1];
    logic [15:0] ready_epoch [0:1];
    logic [2:0] kv_fill_group [0:1];
    logic [2:0] kv_ready_group [0:1];
    logic [1:0] kv_seen_k, kv_seen_v;

    logic [2:0] q_state [0:1];
    logic [15:0] q_epoch [0:1];
    logic [2:0] q_group [0:1];
    logic [4:0] q_head [0:1];
    logic [2:0] q_window [0:1];
    logic q_active_valid, q_active_buffer;
    logic [2:0] q_outstanding;
    logic [255:0] q_token_seen;
    logic [1:0] q_fill_issued;
    logic [11:0] q_load_count [0:1];
    logic [14:0] kv_k_load_count [0:1];
    logic [14:0] kv_v_load_count [0:1];
    logic q_alloc_valid, q_alloc_buffer, q_prefetch_present;
    logic q_all_free, q_need_token_sane, q_need_token_current;
    logic q_need_duplicate, q_publish_token_match;
    logic q_retire_token_match;
    logic q_need_invalid, q_publish_invalid, q_retire_invalid;
    logic q_load_legal, kv_load_legal;

    logic prep_legal, load_legal, publish_legal, activate_legal;
    logic kv_publish_token_match, activate_token_match;
    logic prep_reject_seen, load_reject_seen;
    logic publish_reject_seen, activate_reject_seen;
    logic q_need_reject_seen, q_publish_reject_seen;
    logic q_retire_reject_seen;
    logic q_reuse_stall_seen;
    logic prep_reject_event, load_reject_event;
    logic publish_reject_event, activate_reject_event;
    logic q_need_reject_event, q_publish_reject_event;
    logic q_retire_reject_event;
    logic [3:0] reject_event_count;
    logic [2:0] q_tag_event_count, q_epoch_event_count;
    logic pipelines_empty;

    logic q_v0, q_v1;
    logic [3:0] q_tag0, q_tag1;
    logic [15:0] q_data0, q_data1;
    logic k_v0, k_v1;
    logic [3:0] k_tag0, k_tag1;
    logic [511:0] k_data0, k_data1;
    logic v_v0, v_v1;
    logic [3:0] v_tag0, v_tag1;
    logic [511:0] v_data0, v_data1;

    integer lane;

    assign buffer_ready = {buffer_ready_reg[1], buffer_ready_reg[0]};
    assign buffer_epoch_flat = {ready_epoch[1], ready_epoch[0]};
    assign buffer_group_flat = {kv_ready_group[1], kv_ready_group[0]};

    logic [1:0] buffer_ready_reg;

    assign pipelines_empty = !(k_v0 || k_v1 || k_rsp_valid ||
                               v_v0 || v_v1 || v_rsp_valid);

    assign q_prefetch_present = (q_state[0] == Q_FILLING) ||
                                (q_state[0] == Q_READY) ||
                                (q_state[1] == Q_FILLING) ||
                                (q_state[1] == Q_READY);
    assign q_all_free = (q_state[0] == Q_FREE) &&
                        (q_state[1] == Q_FREE);

    always_comb begin
        q_alloc_valid = 1'b0;
        q_alloc_buffer = 1'b0;
        if (!q_prefetch_present) begin
            if (q_active_valid) begin
                q_alloc_buffer = ~q_active_buffer;
                q_alloc_valid = (q_state[~q_active_buffer] == Q_FREE);
            end else if (q_state[0] == Q_FREE) begin
                q_alloc_valid = 1'b1;
                q_alloc_buffer = 1'b0;
            end else if (q_state[1] == Q_FREE) begin
                q_alloc_valid = 1'b1;
                q_alloc_buffer = 1'b1;
            end
        end
    end

    assign q_need_token_sane =
        (q_slab_need_global_q_head[4:2] == q_slab_need_group);
    assign q_need_token_current = active_valid &&
        (q_slab_need_epoch == active_epoch) &&
        (q_slab_need_group == active_group);
    assign q_need_duplicate =
        q_token_seen[{q_slab_need_global_q_head, q_slab_need_row_window}];
    assign q_slab_need_ready = q_alloc_valid && q_need_token_sane &&
                               q_need_token_current && !q_need_duplicate;

    always_comb begin
        q_fill_valid = 1'b0;
        q_fill_buffer = 1'b0;
        q_fill_epoch = '0;
        q_fill_group = '0;
        q_fill_global_q_head = '0;
        q_fill_row_window = '0;
        if ((q_state[0] == Q_FILLING) && !q_fill_issued[0]) begin
            q_fill_valid = 1'b1;
            q_fill_buffer = 1'b0;
            q_fill_epoch = q_epoch[0];
            q_fill_group = q_group[0];
            q_fill_global_q_head = q_head[0];
            q_fill_row_window = q_window[0];
        end else if ((q_state[1] == Q_FILLING) && !q_fill_issued[1]) begin
            q_fill_valid = 1'b1;
            q_fill_buffer = 1'b1;
            q_fill_epoch = q_epoch[1];
            q_fill_group = q_group[1];
            q_fill_global_q_head = q_head[1];
            q_fill_row_window = q_window[1];
        end
    end

    assign q_publish_token_match =
        (q_state[q_publish_buffer] == Q_FILLING) &&
        q_fill_issued[q_publish_buffer] &&
        (q_epoch[q_publish_buffer] == q_publish_epoch) &&
        (q_group[q_publish_buffer] == q_publish_group) &&
        (q_head[q_publish_buffer] == q_publish_global_q_head) &&
        (q_window[q_publish_buffer] == q_publish_row_window);
    assign q_publish_ready = q_publish_token_match &&
                             (q_load_count[q_publish_buffer] == 12'd2048);

    always_comb begin
        q_slab_ready_valid = 1'b0;
        q_slab_ready_buffer = 1'b0;
        q_slab_ready_epoch = '0;
        q_slab_ready_group = '0;
        q_slab_ready_global_q_head = '0;
        q_slab_ready_row_window = '0;
        if (!q_active_valid && (q_outstanding == 0)) begin
            if (q_state[0] == Q_READY) begin
                q_slab_ready_valid = 1'b1;
                q_slab_ready_buffer = 1'b0;
                q_slab_ready_epoch = q_epoch[0];
                q_slab_ready_group = q_group[0];
                q_slab_ready_global_q_head = q_head[0];
                q_slab_ready_row_window = q_window[0];
            end else if (q_state[1] == Q_READY) begin
                q_slab_ready_valid = 1'b1;
                q_slab_ready_buffer = 1'b1;
                q_slab_ready_epoch = q_epoch[1];
                q_slab_ready_group = q_group[1];
                q_slab_ready_global_q_head = q_head[1];
                q_slab_ready_row_window = q_window[1];
            end
        end
    end

    assign q_retire_token_match = q_active_valid &&
        ((q_state[q_slab_retire_buffer] == Q_ACTIVE) ||
         (q_state[q_slab_retire_buffer] == Q_RETIRING)) &&
        (q_slab_retire_buffer == q_active_buffer) &&
        (q_epoch[q_slab_retire_buffer] == q_slab_retire_epoch) &&
        (q_group[q_slab_retire_buffer] == q_slab_retire_group) &&
        (q_head[q_slab_retire_buffer] == q_slab_retire_global_q_head) &&
        (q_window[q_slab_retire_buffer] == q_slab_retire_row_window);
    assign q_slab_retire_ready = q_retire_token_match &&
                                 (q_outstanding == 0) && !q_req_valid;

    assign prep_legal = (!active_valid || (prep_buffer != active_buffer)) &&
                        !fill_owned[prep_buffer] &&
                        !buffer_ready_reg[prep_buffer];
    assign prep_ready = prep_legal;

    assign q_load_legal = (load_kind == 2'd0) &&
        (q_state[load_buffer] == Q_FILLING) &&
        q_fill_issued[load_buffer] &&
        (q_epoch[load_buffer] == load_epoch) &&
        (q_group[load_buffer] == load_group) &&
        (q_head[load_buffer] == load_global_q_head) &&
        (q_window[load_buffer] == load_row_window) &&
        (q_load_count[load_buffer] < 12'd2048);
    assign kv_load_legal = ((load_kind == 2'd1) || (load_kind == 2'd2)) &&
        fill_owned[load_buffer] &&
        (fill_epoch[load_buffer] == load_epoch) &&
        (kv_fill_group[load_buffer] == load_group) &&
        (((load_kind == 2'd1) &&
          (kv_k_load_count[load_buffer] < 15'd16384)) ||
         ((load_kind == 2'd2) &&
          (kv_v_load_count[load_buffer] < 15'd16384))) &&
        (!active_valid || (load_buffer != active_buffer));
    assign load_legal = q_load_legal || kv_load_legal;
    assign load_ready = load_legal;

    assign kv_publish_token_match = fill_owned[publish_buffer] &&
                           (fill_epoch[publish_buffer] == publish_epoch) &&
                           (kv_fill_group[publish_buffer] == publish_group) &&
                           (!active_valid ||
                            (publish_buffer != active_buffer));
    assign publish_legal = kv_publish_token_match &&
                           (kv_k_load_count[publish_buffer] == 15'd16384) &&
                           (kv_v_load_count[publish_buffer] == 15'd16384);
    assign publish_ready = publish_legal;

    assign activate_token_match = buffer_ready_reg[activate_buffer] &&
                            (ready_epoch[activate_buffer] == activate_epoch) &&
                            (kv_ready_group[activate_buffer] == activate_group) &&
                            (!active_valid ||
                             (activate_buffer != active_buffer));
    assign activate_legal = activate_token_match && pipelines_empty &&
                            q_all_free;
    assign activate_ready = activate_legal;

    assign prep_reject_event = prep_valid && !prep_ready &&
                               !prep_reject_seen;
    assign load_reject_event = load_valid && !load_ready &&
                               !load_reject_seen;
    assign publish_reject_event = publish_valid &&
                                  !kv_publish_token_match &&
                                  !publish_reject_seen;
    assign activate_reject_event = activate_valid &&
                                   !activate_token_match &&
                                   !activate_reject_seen;
    assign q_need_invalid = q_slab_need_valid &&
        (!q_need_token_sane || !q_need_token_current || q_need_duplicate);
    assign q_publish_invalid = q_publish_valid && !q_publish_token_match;
    assign q_retire_invalid = q_slab_retire_valid &&
                              (!q_retire_token_match || q_req_valid);
    assign q_need_reject_event = q_need_invalid &&
                                 !q_need_reject_seen;
    assign q_publish_reject_event = q_publish_invalid &&
                                    !q_publish_reject_seen;
    assign q_retire_reject_event = q_retire_invalid &&
                                   !q_retire_reject_seen;
    assign reject_event_count = {3'b0, load_reject_event} +
        {3'b0, publish_reject_event} +
        {3'b0, activate_reject_event} + {3'b0, q_need_reject_event} +
        {3'b0, q_publish_reject_event} + {3'b0, q_retire_reject_event};

    assign q_epoch_event_count =
        {2'b0, (q_need_reject_event && active_valid &&
         (q_slab_need_epoch != active_epoch))} +
        {2'b0, (load_reject_event && (load_kind == 2'd0) &&
         (q_epoch[load_buffer] != load_epoch))} +
        {2'b0, (q_publish_reject_event &&
         (q_epoch[q_publish_buffer] != q_publish_epoch))} +
        {2'b0, (q_retire_reject_event && q_active_valid &&
         (q_epoch[q_active_buffer] != q_slab_retire_epoch))};
    assign q_tag_event_count =
        {2'b0, (q_need_reject_event &&
         (!active_valid || !q_need_token_sane || q_need_duplicate ||
          ((q_slab_need_epoch == active_epoch) &&
           (q_slab_need_group != active_group))))} +
        {2'b0, (load_reject_event && (load_kind == 2'd0) &&
         (q_state[load_buffer] == Q_FILLING) &&
         (q_epoch[load_buffer] == load_epoch) &&
         ((q_group[load_buffer] != load_group) ||
          (q_head[load_buffer] != load_global_q_head) ||
          (q_window[load_buffer] != load_row_window)))} +
        {2'b0, (q_publish_reject_event &&
         (q_epoch[q_publish_buffer] == q_publish_epoch))} +
        {2'b0, (q_retire_reject_event &&
         (!q_active_valid ||
          ((q_epoch[q_active_buffer] == q_slab_retire_epoch) &&
           !q_retire_token_match)))};

    assign q_req_ready = q_active_valid &&
                         (q_state[q_active_buffer] == Q_ACTIVE) &&
                         !q_slab_retire_valid;
    assign k_req_ready = active_valid && !activate_valid;
    assign v_req_ready = active_valid && !activate_valid;

    always_ff @(posedge core_clk) begin
        if (!core_rst_n) begin
            fill_owned <= '0;
            fill_epoch[0] <= '0;
            fill_epoch[1] <= '0;
            ready_epoch[0] <= '0;
            ready_epoch[1] <= '0;
            kv_fill_group[0] <= '0; kv_fill_group[1] <= '0;
            kv_ready_group[0] <= '0; kv_ready_group[1] <= '0;
            kv_seen_k <= '0; kv_seen_v <= '0;
            kv_k_load_count[0] <= '0; kv_k_load_count[1] <= '0;
            kv_v_load_count[0] <= '0; kv_v_load_count[1] <= '0;
            buffer_ready_reg <= '0;
            active_valid <= 1'b0;
            active_buffer <= 1'b0;
            active_epoch <= '0;
            active_group <= '0;

            q_state[0] <= Q_FREE; q_state[1] <= Q_FREE;
            q_epoch[0] <= '0; q_epoch[1] <= '0;
            q_group[0] <= '0; q_group[1] <= '0;
            q_head[0] <= '0; q_head[1] <= '0;
            q_window[0] <= '0; q_window[1] <= '0;
            q_active_valid <= 1'b0;
            q_active_buffer <= 1'b0;
            q_outstanding <= '0;
            q_token_seen <= '0;
            q_fill_issued <= '0;
            q_load_count[0] <= '0; q_load_count[1] <= '0;

            q_v0 <= 1'b0; q_v1 <= 1'b0; q_rsp_valid <= 1'b0;
            q_tag0 <= '0; q_tag1 <= '0; q_rsp_context_tag <= '0;
            q_data0 <= '0; q_data1 <= '0; q_rsp_bf16 <= '0;
            k_v0 <= 1'b0; k_v1 <= 1'b0; k_rsp_valid <= 1'b0;
            k_tag0 <= '0; k_tag1 <= '0; k_rsp_context_tag <= '0;
            k_data0 <= '0; k_data1 <= '0; k_rsp_vec <= '0;
            v_v0 <= 1'b0; v_v1 <= 1'b0; v_rsp_valid <= 1'b0;
            v_tag0 <= '0; v_tag1 <= '0; v_rsp_context_tag <= '0;
            v_data0 <= '0; v_data1 <= '0; v_rsp_vec <= '0;

            q_requests_accepted <= '0;
            k_requests_accepted <= '0;
            v_requests_accepted <= '0;
            active_write_conflicts <= '0;
            bank_conflicts <= '0;
            protocol_errors <= '0;
            protocol_error_sticky <= 1'b0;
            q_slab_need_count <= '0;
            q_slab_fill_count <= '0;
            q_slab_ready_count <= '0;
            q_slab_activate_count <= '0;
            q_slab_retire_count <= '0;
            q_slab_refill_wait <= '0;
            q_slab_reuse_stall <= '0;
            q_slab_outstanding_max <= '0;
            q_slab_tag_error <= '0;
            q_slab_epoch_error <= '0;
            q_slab_overwrite_error <= '0;
            q_slab_early_retire_error <= '0;
            kv_paired_ready_error <= '0;
            q_buffer_reuse_stall <= '0;
            kv_buffer_reuse_stall <= '0;
            prep_reject_seen <= 1'b0;
            load_reject_seen <= 1'b0;
            publish_reject_seen <= 1'b0;
            activate_reject_seen <= 1'b0;
            q_need_reject_seen <= 1'b0;
            q_publish_reject_seen <= 1'b0;
            q_retire_reject_seen <= 1'b0;
            q_reuse_stall_seen <= 1'b0;
        end else begin
            // Two-cycle fixed response pipelines.  These outputs are pulses;
            // the frozen service has no response backpressure.
            q_rsp_valid <= q_v1;
            q_rsp_context_tag <= q_tag1;
            q_rsp_bf16 <= q_data1;
            q_v1 <= q_v0;
            q_tag1 <= q_tag0;
            q_data1 <= q_data0;
            q_v0 <= q_req_valid && q_req_ready;
            if (q_req_valid && q_req_ready) begin
                q_tag0 <= q_req_context_tag;
                q_data0 <= q_mem[q_active_buffer][q_req_d[1:0]]
                                  [{q_req_context_tag, q_req_d[6:2]}];
            end

            case ({q_req_valid && q_req_ready, q_v1})
                2'b10: q_outstanding <= q_outstanding + 1'b1;
                2'b01: q_outstanding <= q_outstanding - 1'b1;
                default: ;
            endcase
            if ((q_req_valid && q_req_ready) && !q_v1 &&
                ((q_outstanding + 1'b1) > q_slab_outstanding_max))
                q_slab_outstanding_max <= q_outstanding + 1'b1;

            k_rsp_valid <= k_v1;
            k_rsp_context_tag <= k_tag1;
            k_rsp_vec <= k_data1;
            k_v1 <= k_v0;
            k_tag1 <= k_tag0;
            k_data1 <= k_data0;
            k_v0 <= k_req_valid && k_req_ready;
            if (k_req_valid && k_req_ready) begin
                k_tag0 <= k_req_context_tag;
                for (lane = 0; lane < KV_BANKS; lane = lane + 1)
                    k_data0[lane*16 +: 16] <=
                        k_mem[active_buffer][lane][{k_req_key_block, k_req_d}];
            end

            v_rsp_valid <= v_v1;
            v_rsp_context_tag <= v_tag1;
            v_rsp_vec <= v_data1;
            v_v1 <= v_v0;
            v_tag1 <= v_tag0;
            v_data1 <= v_data0;
            v_v0 <= v_req_valid && v_req_ready;
            if (v_req_valid && v_req_ready) begin
                v_tag0 <= v_req_context_tag;
                for (lane = 0; lane < KV_BANKS; lane = lane + 1)
                    v_data0[lane*16 +: 16] <=
                        v_mem[active_buffer][lane]
                             [{v_req_key, v_req_feature_block}];
            end

            if (prep_valid && prep_ready) begin
                fill_owned[prep_buffer] <= 1'b1;
                fill_epoch[prep_buffer] <= prep_epoch;
                kv_fill_group[prep_buffer] <= prep_group;
                kv_seen_k[prep_buffer] <= 1'b0;
                kv_seen_v[prep_buffer] <= 1'b0;
                kv_k_load_count[prep_buffer] <= '0;
                kv_v_load_count[prep_buffer] <= '0;
                buffer_ready_reg[prep_buffer] <= 1'b0;
            end

            if (load_valid && load_ready) begin
                case (load_kind)
                    2'd0: begin
                        q_mem[load_buffer][load_d[1:0]]
                                [{load_context_tag, load_d[6:2]}]
                                <= load_data_bf16;
                        q_load_count[load_buffer] <=
                            q_load_count[load_buffer] + 1'b1;
                    end
                    2'd1: begin
                        k_mem[load_buffer][load_key[4:0]]
                             [{load_key[6:5], load_d}] <= load_data_bf16;
                        kv_seen_k[load_buffer] <= 1'b1;
                        kv_k_load_count[load_buffer] <=
                            kv_k_load_count[load_buffer] + 1'b1;
                    end
                    2'd2: begin
                        v_mem[load_buffer][load_d[4:0]]
                             [{load_key, load_d[6:5]}] <= load_data_bf16;
                        kv_seen_v[load_buffer] <= 1'b1;
                        kv_v_load_count[load_buffer] <=
                            kv_v_load_count[load_buffer] + 1'b1;
                    end
                    default: ;
                endcase
            end

            if (publish_valid && publish_ready) begin
                buffer_ready_reg[publish_buffer] <= 1'b1;
                ready_epoch[publish_buffer] <= publish_epoch;
                kv_ready_group[publish_buffer] <= publish_group;
                fill_owned[publish_buffer] <= 1'b0;
            end

            if (activate_valid && activate_ready) begin
                if (active_valid && (active_buffer != activate_buffer))
                    buffer_ready_reg[active_buffer] <= 1'b0;
                active_valid <= 1'b1;
                active_buffer <= activate_buffer;
                active_epoch <= activate_epoch;
                active_group <= activate_group;
                q_token_seen <= '0;
            end

            if (q_slab_need_valid && q_slab_need_ready) begin
                q_state[q_alloc_buffer] <= Q_FILLING;
                q_epoch[q_alloc_buffer] <= q_slab_need_epoch;
                q_group[q_alloc_buffer] <= q_slab_need_group;
                q_head[q_alloc_buffer] <= q_slab_need_global_q_head;
                q_window[q_alloc_buffer] <= q_slab_need_row_window;
                q_fill_issued[q_alloc_buffer] <= 1'b0;
                q_load_count[q_alloc_buffer] <= '0;
                q_token_seen[{q_slab_need_global_q_head,
                              q_slab_need_row_window}] <= 1'b1;
                q_slab_need_count <= q_slab_need_count + 1'b1;
            end

            if (q_fill_valid && q_fill_ready)
                q_fill_issued[q_fill_buffer] <= 1'b1;

            if (q_publish_valid && q_publish_ready) begin
                q_state[q_publish_buffer] <= Q_READY;
                q_slab_fill_count <= q_slab_fill_count + 1'b1;
                q_slab_ready_count <= q_slab_ready_count + 1'b1;
            end

            if (q_slab_ready_valid && q_slab_ready_ready) begin
                q_state[q_slab_ready_buffer] <= Q_ACTIVE;
                q_active_valid <= 1'b1;
                q_active_buffer <= q_slab_ready_buffer;
                q_slab_activate_count <= q_slab_activate_count + 1'b1;
            end

            // A matching early-retire freezes new Q requests.  The channel
            // transfer and half release still wait for outstanding==0.
            if (q_slab_retire_valid && q_retire_token_match &&
                (q_outstanding != 0))
                q_state[q_active_buffer] <= Q_RETIRING;

            if (q_slab_retire_valid && q_slab_retire_ready) begin
                q_state[q_slab_retire_buffer] <= Q_FREE;
                q_active_valid <= 1'b0;
                q_slab_retire_count <= q_slab_retire_count + 1'b1;
            end

            // Count each rejected assertion once until the requester drops
            // valid, avoiding a counter that depends on stall duration.
            if (!prep_valid) prep_reject_seen <= 1'b0;
            else if (prep_reject_event) begin
                prep_reject_seen <= 1'b1;
            end

            if (!load_valid) load_reject_seen <= 1'b0;
            else if (load_reject_event) begin
                load_reject_seen <= 1'b1;
                if ((load_kind == 2'd0) &&
                    ((q_state[load_buffer] == Q_ACTIVE) ||
                     (q_state[load_buffer] == Q_RETIRING))) begin
                    q_slab_overwrite_error <=
                        q_slab_overwrite_error + 1'b1;
                    active_write_conflicts <= active_write_conflicts + 1'b1;
                    bank_conflicts <= bank_conflicts + 1'b1;
                end else if ((load_kind != 2'd0) && active_valid &&
                             (load_buffer == active_buffer)) begin
                    active_write_conflicts <= active_write_conflicts + 1'b1;
                    bank_conflicts <= bank_conflicts + 1'b1;
                end
            end

            if (!publish_valid) publish_reject_seen <= 1'b0;
            else if (publish_reject_event) begin
                publish_reject_seen <= 1'b1;
            end

            if (!activate_valid) activate_reject_seen <= 1'b0;
            else if (activate_reject_event) begin
                activate_reject_seen <= 1'b1;
            end

            if (!q_slab_need_valid) q_need_reject_seen <= 1'b0;
            else if (q_need_reject_event) q_need_reject_seen <= 1'b1;
            if (!q_publish_valid) q_publish_reject_seen <= 1'b0;
            else if (q_publish_reject_event)
                q_publish_reject_seen <= 1'b1;
            if (!q_slab_retire_valid) q_retire_reject_seen <= 1'b0;
            else if (q_retire_reject_event)
                q_retire_reject_seen <= 1'b1;
            if (!q_slab_need_valid || q_slab_need_ready)
                q_reuse_stall_seen <= 1'b0;
            else if (!q_need_invalid && !q_alloc_valid)
                q_reuse_stall_seen <= 1'b1;

            if ((q_slab_need_valid && !q_slab_need_ready &&
                 !q_need_invalid) || (q_fill_valid && !q_fill_ready)) begin
                q_slab_refill_wait <= q_slab_refill_wait + 1'b1;
            end
            if (q_slab_need_valid && !q_slab_need_ready &&
                !q_need_invalid && !q_alloc_valid)
                q_buffer_reuse_stall <= q_buffer_reuse_stall + 1'b1;
            if (q_slab_need_valid && !q_slab_need_ready &&
                !q_need_invalid && !q_alloc_valid && !q_reuse_stall_seen)
                q_slab_reuse_stall <= q_slab_reuse_stall + 1'b1;
            if (prep_reject_event)
                kv_buffer_reuse_stall <= kv_buffer_reuse_stall + 1'b1;
            if (publish_reject_event && fill_owned[publish_buffer] &&
                !(kv_seen_k[publish_buffer] && kv_seen_v[publish_buffer]))
                kv_paired_ready_error <= kv_paired_ready_error + 1'b1;

            if (q_retire_reject_event)
                q_slab_early_retire_error <=
                    q_slab_early_retire_error + 1'b1;
            if (q_tag_event_count != 0)
                q_slab_tag_error <= q_slab_tag_error + q_tag_event_count;
            if (q_epoch_event_count != 0)
                q_slab_epoch_error <= q_slab_epoch_error + q_epoch_event_count;

            // A single accumulated update preserves every independent
            // rejection when several control channels fail in one cycle.
            if (reject_event_count != 0) begin
                protocol_errors <= protocol_errors + reject_event_count;
                protocol_error_sticky <= 1'b1;
            end

            if (q_req_valid && q_req_ready)
                q_requests_accepted <= q_requests_accepted + 1'b1;
            if (k_req_valid && k_req_ready)
                k_requests_accepted <= k_requests_accepted + 1'b1;
            if (v_req_valid && v_req_ready)
                v_requests_accepted <= v_requests_accepted + 1'b1;

            if (counter_clear) begin
                q_requests_accepted <= '0;
                k_requests_accepted <= '0;
                v_requests_accepted <= '0;
                active_write_conflicts <= '0;
                bank_conflicts <= '0;
                protocol_errors <= '0;
                protocol_error_sticky <= 1'b0;
                q_slab_need_count <= '0;
                q_slab_fill_count <= '0;
                q_slab_ready_count <= '0;
                q_slab_activate_count <= '0;
                q_slab_retire_count <= '0;
                q_slab_refill_wait <= '0;
                q_slab_reuse_stall <= '0;
                q_slab_outstanding_max <= '0;
                q_slab_tag_error <= '0;
                q_slab_epoch_error <= '0;
                q_slab_overwrite_error <= '0;
                q_slab_early_retire_error <= '0;
                kv_paired_ready_error <= '0;
                q_buffer_reuse_stall <= '0;
                kv_buffer_reuse_stall <= '0;
            end
        end
    end

    initial begin
        if ((SEQ_LEN != 128) || (HEAD_DIM != 128) || (CONTEXTS != 16))
            $error("cats_r4_qkv_banked_mem: CATS_R4_IF_V2 requires S=D=128,R=16");
    end
endmodule
