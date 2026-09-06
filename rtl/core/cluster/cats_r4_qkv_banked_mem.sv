`timescale 1ns/1ps

// CATS-R4 cluster-local Q/K/V memory-service wrapper.
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

    input  logic         load_valid,
    output logic         load_ready,
    input  logic         load_buffer,
    input  logic [15:0]  load_epoch,
    input  logic [1:0]   load_kind,       // 0=Q, 1=K, 2=V
    input  logic [3:0]   load_context_tag,
    input  logic [6:0]   load_key,
    input  logic [6:0]   load_d,
    input  logic [15:0]  load_data_bf16,

    input  logic         publish_valid,
    output logic         publish_ready,
    input  logic         publish_buffer,
    input  logic [15:0]  publish_epoch,

    input  logic         activate_valid,
    output logic         activate_ready,
    input  logic         activate_buffer,
    input  logic [15:0]  activate_epoch,

    output logic         active_valid,
    output logic         active_buffer,
    output logic [15:0]  active_epoch,
    output logic [1:0]   buffer_ready,
    output logic [31:0]  buffer_epoch_flat,

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
    output logic         protocol_error_sticky
);
    localparam int Q_BANKS = 4;
    localparam int KV_BANKS = 32;
    localparam int Q_BANK_DEPTH = CONTEXTS * (HEAD_DIM/Q_BANKS);
    localparam int KV_BANK_DEPTH = (SEQ_LEN/KV_BANKS) * HEAD_DIM;

    (* ram_style = "block" *) logic [15:0] q_mem [0:1][0:Q_BANKS-1][0:Q_BANK_DEPTH-1];
    (* ram_style = "block" *) logic [15:0] k_mem [0:1][0:KV_BANKS-1][0:KV_BANK_DEPTH-1];
    (* ram_style = "block" *) logic [15:0] v_mem [0:1][0:KV_BANKS-1][0:KV_BANK_DEPTH-1];

    logic [1:0]  fill_owned;
    logic [15:0] fill_epoch [0:1];
    logic [15:0] ready_epoch [0:1];

    logic prep_legal, load_legal, publish_legal, activate_legal;
    logic prep_reject_seen, load_reject_seen;
    logic publish_reject_seen, activate_reject_seen;
    logic prep_reject_event, load_reject_event;
    logic publish_reject_event, activate_reject_event;
    logic [2:0] reject_event_count;
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

    logic [1:0] buffer_ready_reg;

    assign pipelines_empty = !(q_v0 || q_v1 || q_rsp_valid ||
                               k_v0 || k_v1 || k_rsp_valid ||
                               v_v0 || v_v1 || v_rsp_valid);

    assign prep_legal = !active_valid || (prep_buffer != active_buffer);
    assign prep_ready = prep_legal;

    assign load_legal = fill_owned[load_buffer] &&
                        (fill_epoch[load_buffer] == load_epoch) &&
                        (!active_valid || (load_buffer != active_buffer)) &&
                        (load_kind != 2'd3);
    assign load_ready = load_legal;

    assign publish_legal = fill_owned[publish_buffer] &&
                           (fill_epoch[publish_buffer] == publish_epoch) &&
                           (!active_valid || (publish_buffer != active_buffer));
    assign publish_ready = publish_legal;

    assign activate_legal = buffer_ready_reg[activate_buffer] &&
                            (ready_epoch[activate_buffer] == activate_epoch) &&
                            pipelines_empty;
    assign activate_ready = activate_legal;

    assign prep_reject_event = prep_valid && !prep_ready &&
                               !prep_reject_seen;
    assign load_reject_event = load_valid && !load_ready &&
                               !load_reject_seen;
    assign publish_reject_event = publish_valid && !publish_ready &&
                                  !publish_reject_seen;
    assign activate_reject_event = activate_valid && !activate_ready &&
                                   !activate_reject_seen;
    assign reject_event_count = {2'b0, prep_reject_event} +
                                {2'b0, load_reject_event} +
                                {2'b0, publish_reject_event} +
                                {2'b0, activate_reject_event};

    // During any activation attempt, all memory services pause.  Once a
    // buffer is active, independent Q/K/V services each accept one request per
    // cycle and cannot conflict because they use distinct physical arrays.
    assign q_req_ready = active_valid && !activate_valid;
    assign k_req_ready = active_valid && !activate_valid;
    assign v_req_ready = active_valid && !activate_valid;

    always_ff @(posedge core_clk) begin
        if (!core_rst_n) begin
            fill_owned <= '0;
            fill_epoch[0] <= '0;
            fill_epoch[1] <= '0;
            ready_epoch[0] <= '0;
            ready_epoch[1] <= '0;
            buffer_ready_reg <= '0;
            active_valid <= 1'b0;
            active_buffer <= 1'b0;
            active_epoch <= '0;

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
            prep_reject_seen <= 1'b0;
            load_reject_seen <= 1'b0;
            publish_reject_seen <= 1'b0;
            activate_reject_seen <= 1'b0;
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
                q_data0 <= q_mem[active_buffer][q_req_d[1:0]]
                                  [{q_req_context_tag, q_req_d[6:2]}];
            end

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
                buffer_ready_reg[prep_buffer] <= 1'b0;
            end

            if (load_valid && load_ready) begin
                case (load_kind)
                    2'd0: q_mem[load_buffer][load_d[1:0]]
                                [{load_context_tag, load_d[6:2]}]
                                <= load_data_bf16;
                    2'd1: k_mem[load_buffer][load_key[4:0]]
                                [{load_key[6:5], load_d}]
                                <= load_data_bf16;
                    2'd2: v_mem[load_buffer][load_d[4:0]]
                                [{load_key, load_d[6:5]}]
                                <= load_data_bf16;
                    default: ;
                endcase
            end

            if (publish_valid && publish_ready) begin
                buffer_ready_reg[publish_buffer] <= 1'b1;
                ready_epoch[publish_buffer] <= publish_epoch;
                fill_owned[publish_buffer] <= 1'b0;
            end

            if (activate_valid && activate_ready) begin
                active_valid <= 1'b1;
                active_buffer <= activate_buffer;
                active_epoch <= activate_epoch;
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
                if (active_valid && (load_buffer == active_buffer)) begin
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
            end
        end
    end

    initial begin
        if ((SEQ_LEN != 128) || (HEAD_DIM != 128) || (CONTEXTS != 16))
            $error("cats_r4_qkv_banked_mem: CATS_R4_IF_V1 requires S=D=128,R=16");
    end
endmodule
