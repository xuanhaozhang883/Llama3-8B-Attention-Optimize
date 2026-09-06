`timescale 1ns/1ps

// CATS-R4 cluster boundary shell (contract/elaboration aid only).
//
// This module deliberately does not implement A/B math or C storage/DMA.
// It exposes the frozen CATS_R4_IF_V1 command, memory-service and output
// interfaces so A/B and C can elaborate against one stable boundary.  The
// deterministic stub accepts one valid command, emits one zero output chunk,
// then emits the matching done descriptor.  Q/K/V request channels are kept
// quiescent and response channels are not consumed.
//
// This is NOT a CATS-R4 READY implementation and must not be used for board
// builds or performance claims.
module cats_r4_cluster_shell #(
    parameter int CLUSTERS  = 1,
    parameter int CLUSTER_ID = 0
) (
    input  logic         core_clk,
    input  logic         core_rst_n,

    // Frozen system-to-cluster command wrapper.
    input  logic         cmd_valid,
    output logic         cmd_ready,
    input  logic [15:0]  cmd_epoch,
    input  logic [1:0]   cmd_cluster_id,
    input  logic [2:0]   cmd_group_id,
    input  logic [4:0]   cmd_q_head_base,
    input  logic         cmd_kv_buffer,

    // Frozen cluster-to-system completion descriptor.
    output logic         done_valid,
    input  logic         done_ready,
    output logic [15:0]  done_epoch,
    output logic [2:0]   done_group,
    output logic         done_error,

    // Q service: scalar BF16 response, fixed two-cycle service at the
    // contract boundary (the stub never issues requests).
    output logic         q_req_valid,
    input  logic         q_req_ready,
    output logic [3:0]   q_req_context_tag,
    output logic [6:0]   q_req_d,
    input  logic         q_rsp_valid,
    output logic         q_rsp_ready,
    input  logic [3:0]   q_rsp_context_tag,
    input  logic [15:0]  q_rsp_bf16,

    // K service: 32-key vector response.
    output logic         k_req_valid,
    input  logic         k_req_ready,
    output logic [3:0]   k_req_context_tag,
    output logic [1:0]   k_req_key_block,
    output logic [6:0]   k_req_d,
    input  logic         k_rsp_valid,
    output logic         k_rsp_ready,
    input  logic [3:0]   k_rsp_context_tag,
    input  logic [511:0] k_rsp_vec,

    // V service: 32-feature vector response.
    output logic         v_req_valid,
    input  logic         v_req_ready,
    output logic [3:0]   v_req_context_tag,
    output logic [6:0]   v_req_key,
    output logic [1:0]   v_req_feature_block,
    input  logic         v_rsp_valid,
    output logic         v_rsp_ready,
    input  logic [3:0]   v_rsp_context_tag,
    input  logic [511:0] v_rsp_vec,

    // Frozen cluster-to-output 32-feature chunk.
    output logic         out_valid,
    input  logic         out_ready,
    output logic [15:0]  out_epoch,
    output logic [11:0]  out_seq,
    output logic [4:0]   out_global_q_head,
    output logic [6:0]   out_row,
    output logic [1:0]   out_feature_block,
    output logic [511:0] out_data_bf16,
    output logic         out_row_last,
    output logic         out_tensor_last,

    output logic         protocol_error
);
    typedef enum logic [1:0] { S_IDLE, S_EMIT, S_DONE } state_t;
    state_t state;

    logic [15:0] epoch_reg;
    logic [2:0]  group_reg;
    logic [4:0]  q_head_reg;

    localparam logic [1:0] CLUSTER_ID_BITS = CLUSTER_ID[1:0];

    // The stub does not consume memory responses.  All request payloads are
    // zero and valid is low, so upstream services must not treat these as
    // transfers.  Unused ready inputs are intentionally not inferred into
    // combinational paths.
    assign q_req_valid         = 1'b0;
    assign q_req_context_tag   = 4'd0;
    assign q_req_d             = 7'd0;
    assign q_rsp_ready         = 1'b0;

    assign k_req_valid         = 1'b0;
    assign k_req_context_tag   = 4'd0;
    assign k_req_key_block     = 2'd0;
    assign k_req_d             = 7'd0;
    assign k_rsp_ready         = 1'b0;

    assign v_req_valid         = 1'b0;
    assign v_req_context_tag   = 4'd0;
    assign v_req_key           = 7'd0;
    assign v_req_feature_block = 2'd0;
    assign v_rsp_ready         = 1'b0;

    assign cmd_ready = (state == S_IDLE) &&
                       (cmd_cluster_id == CLUSTER_ID_BITS);

    assign out_valid         = (state == S_EMIT);
    assign out_epoch         = epoch_reg;
    assign out_global_q_head = q_head_reg;
    assign out_row           = 7'd0;
    assign out_feature_block = 2'd0;
    assign out_seq           = {q_head_reg, 7'd0};
    assign out_data_bf16     = '0;
    assign out_row_last      = 1'b0;
    assign out_tensor_last   = 1'b0;

    assign done_valid = (state == S_DONE);
    assign done_epoch = epoch_reg;
    assign done_group = group_reg;
    assign done_error = protocol_error;

    always_ff @(posedge core_clk) begin
        if (!core_rst_n) begin
            state          <= S_IDLE;
            epoch_reg      <= '0;
            group_reg      <= '0;
            q_head_reg     <= '0;
            protocol_error <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid && cmd_ready) begin
                        epoch_reg      <= cmd_epoch;
                        group_reg      <= cmd_group_id;
                        q_head_reg     <= cmd_q_head_base;
                        protocol_error <= 1'b0;
                        state          <= S_EMIT;
                    end
                end

                S_EMIT: begin
                    // out_* remains registered/derived from latched command
                    // fields while out_valid && !out_ready, satisfying the
                    // stable-payload rule.
                    if (out_valid && out_ready)
                        state <= S_DONE;
                end

                S_DONE: begin
                    if (done_valid && done_ready)
                        state <= S_IDLE;
                end

                default: begin
                    protocol_error <= 1'b1;
                    state          <= S_IDLE;
                end
            endcase
        end
    end

    initial begin
        if (CLUSTERS != 1)
            $error("cats_r4_cluster_shell: stub is contract-only and requires CLUSTERS=1");
        if ((CLUSTER_ID < 0) || (CLUSTER_ID >= CLUSTERS))
            $error("cats_r4_cluster_shell: CLUSTER_ID outside CLUSTERS");
    end
endmodule
