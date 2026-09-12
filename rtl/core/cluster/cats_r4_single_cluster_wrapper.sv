`timescale 1ns/1ps

// CATS-R4 single-cluster integration candidate.
//
// This wrapper is the first executable connection of the frozen IF_V3
// weight-slot service, C-side PV path, and output reorder/CDC/writer path.
// A/B score production and the board AXI master remain external stimulus
// ports.  The wrapper is deliberately not added to the production manifest
// until the Vivado/XSim/OOC gates are run on this exact source set.
module cats_r4_single_cluster_wrapper #(
    parameter int CLUSTER_ID = 0,
    parameter int TOTAL_BEATS = 32*128*4*8
) (
    input  logic core_clk,
    input  logic core_rst_n,
    input  logic axi_clk,
    input  logic axi_rst_n,
    input  logic arst_n,
    input  logic clear,

    // B -> C IF_V3 weight write and row commit.
    input  logic weight_wr_valid,
    output logic weight_wr_ready,
    input  logic [15:0] weight_wr_epoch,
    input  logic [2:0] weight_wr_group,
    input  logic [4:0] weight_wr_global_q_head,
    input  logic [6:0] weight_wr_row,
    input  logic [1:0] weight_wr_slot_id,
    input  logic [1:0] weight_wr_numeric_mode,
    input  logic [6:0] weight_wr_key,
    input  logic weight_wr_mask,
    input logic [31:0] weight_wr_data,
    input logic weight_wr_last,
    input logic row_commit_valid,
    output logic row_commit_ready,
    input logic [15:0] row_commit_epoch,
    input logic [2:0] row_commit_group,
    input logic [4:0] row_commit_global_q_head,
    input logic [6:0] row_commit_row,
    input logic [1:0] row_commit_slot_id,
    input logic [1:0] row_commit_numeric_mode,
    input logic [31:0] row_commit_sum_fp32,
    input logic [31:0] row_commit_inv_sum_fp32,

    // External V-cache service.  Responses are valid-only, as required by
    // IF_V3's fixed-latency scalar/vector memory boundary.
    output logic v_req_valid,
    input logic v_req_ready,
    output logic [6:0] v_req_key,
    output logic [1:0] v_req_feature_block,
    input logic v_rsp_valid,
    input logic [511:0] v_rsp_vec,
    output logic v_rsp_ready,

    // AXI/DDR writer boundary in axi_clk domain.
    input logic output_start,
    input logic [31:0] output_base_addr,
    output logic wr_valid,
    input logic wr_ready,
    output logic [31:0] wr_addr,
    output logic [63:0] wr_data,
    output logic wr_row_last,
    output logic wr_tensor_last,
    output logic output_busy,
    output logic output_done,
    output logic output_error,

    // GPIO-domain abort/drain coordinator.
    input logic abort_valid,
    output logic abort_ready,
    output logic abort_done_valid,
    input logic abort_done_ready,
    output logic [15:0] abort_done_epoch,
    output logic [15:0] current_epoch,
    input logic core_outstanding_zero,
    input logic axi_outstanding_zero,
    output logic core_accept_enable,
    output logic axi_accept_enable,
    output logic core_clear,
    output logic axi_clear,
    output logic drain_active,

    // Public counters: IF_V3 owner counters plus integration counters.
    output logic [63:0] weight_wr_accept,
    output logic [63:0] weight_rd_request,
    output logic [63:0] weight_rd_response,
    output logic [63:0] row_commit_count,
    output logic [63:0] pv_row_count,
    output logic [63:0] weight_release_count,
    output logic [63:0] owner_error,
    output logic [63:0] mask_error,
    output logic [63:0] last_error,
    output logic [63:0] mode_error,
    output logic [63:0] numeric_error,
    output logic [63:0] epoch_drop,
    output logic [63:0] bank_conflict,
    output logic [63:0] outstanding_max,
    output logic [63:0] rows_started,
    output logic [63:0] weights_forwarded,
    output logic [63:0] rows_released,
    output logic [63:0] product_accept_count,
    output logic [63:0] add_commit_count,
    output logic [63:0] context_emit_count,
    output logic [63:0] output_chunks_accepted,
    output logic [63:0] output_beats_committed,
    output logic [63:0] protocol_error_count
);
    logic local_core_clear, local_axi_clear;
    logic slot_wr_valid, slot_commit_valid, slot_release_valid;
    logic slot_wr_ready, slot_commit_ready, slot_release_ready;
    logic slot_pv_valid, slot_pv_ready;
    logic [15:0] slot_pv_epoch, slot_pv_rsp_epoch;
    logic [2:0] slot_pv_group, slot_pv_rsp_group;
    logic [4:0] slot_pv_head, slot_pv_rsp_head;
    logic [6:0] slot_pv_row, slot_pv_rsp_row;
    logic [1:0] slot_pv_slot, slot_pv_mode, slot_pv_rsp_slot, slot_pv_rsp_mode;
    logic [31:0] slot_pv_sum, slot_pv_inv_sum;
    logic [31:0] slot_pv_rsp_sum;
    logic [6:0] slot_pv_rsp_key;
    logic slot_pv_rsp_mask;
    logic [31:0] slot_pv_rsp_data;
    logic slot_rd_valid, slot_rd_ready;
    logic [15:0] slot_rd_epoch;
    logic [2:0] slot_rd_group;
    logic [4:0] slot_rd_head;
    logic [6:0] slot_rd_row, slot_rd_key;
    logic [1:0] slot_rd_slot, slot_rd_mode;
    logic slot_rsp_valid;
    logic [15:0] slot_rsp_epoch;
    logic [2:0] slot_rsp_group;
    logic [4:0] slot_rsp_head;
    logic [6:0] slot_rsp_row;
    logic [1:0] slot_rsp_slot, slot_rsp_mode;
    logic slot_rsp_mask;

    logic pv_row_valid_i, pv_wrapper_ready_i;
    logic [15:0] pv_row_epoch_i;
    logic [2:0] pv_row_group_i;
    logic [4:0] pv_row_head_i;
    logic [6:0] pv_row_row_i;
    logic [1:0] pv_row_slot_i, pv_row_mode_i;
    logic [31:0] pv_row_sum_i, pv_row_inv_i;

    logic row_start_valid_i, row_start_ready_i;
    logic [31:0] row_start_inv_i;
    logic weight_valid_i, weight_ready_i, weight_mask_i, weight_last_i;
    logic [6:0] weight_key_i;
    logic [31:0] weight_data_i;
    logic bcast_active, bcast_in_ready, bcast_valid, bcast_ready, bcast_last_in, bcast_last;
    logic [6:0] bcast_key;
    logic [1:0] bcast_block;
    logic [31:0] bcast_data;
    logic pv_done_valid_i, pv_done_ready_i;
    logic release_valid_i, release_ready_i;
    logic [15:0] release_epoch_i;
    logic [2:0] release_group_i;
    logic [4:0] release_head_i;
    logic [6:0] release_row_i;
    logic [1:0] release_slot_i, release_mode_i;

    logic [15:0] row_epoch_reg;
    logic [2:0] row_group_reg;
    logic [4:0] row_head_reg;
    logic [6:0] row_number_reg;
    logic [1:0] row_slot_reg, row_mode_reg;
    logic row_token_fire;

    logic product_valid_i, product_ready_i;
    logic [6:0] product_key_i;
    logic [1:0] product_block_i;
    logic [1023:0] product_data_i;
    logic product_last_i;
    logic acc_context_valid, acc_context_ready;
    logic [15:0] acc_context_epoch;
    logic [2:0] acc_context_group;
    logic [4:0] acc_context_head;
    logic [6:0] acc_context_row;
    logic [1:0] acc_context_slot, acc_context_mode, acc_context_block;
    logic [511:0] acc_context_data;
    logic acc_context_row_last;
    logic output_protocol_error;
    logic output_in_ready;
    logic output_context_tensor_last;
    logic output_wr_valid_i, output_wr_ready_i;
    logic [31:0] output_wr_addr_i;
    logic [63:0] output_wr_data_i;
    logic output_wr_row_last_i, output_wr_tensor_last_i;

    logic [63:0] adapter_weight_accept, adapter_v_request, adapter_product_emit;
    logic [63:0] adapter_protocol_error;
    logic [63:0] pv_wrapper_errors;
    logic [63:0] pv_rows_started, pv_weights_forwarded, pv_rows_released;
    logic [63:0] pv_product_errors;
    logic [63:0] cdc_protocol_errors;
    logic [63:0] abort_count, drain_cycles, epoch_wrap_count;
    logic output_done_toggle_axi, output_done_sync1, output_done_sync2, output_done_seen;

    assign local_core_clear = clear | core_clear;
    assign local_axi_clear = clear | axi_clear;
    assign slot_wr_valid = weight_wr_valid && core_accept_enable;
    assign slot_commit_valid = row_commit_valid && core_accept_enable;
    assign slot_release_valid = release_valid_i && core_accept_enable;
    assign release_ready_i = slot_release_ready;
    assign weight_wr_ready = core_accept_enable && slot_wr_ready;
    assign row_commit_ready = core_accept_enable && slot_commit_ready;
    assign slot_pv_ready = pv_wrapper_ready_i && core_accept_enable;
    assign output_context_tensor_last = acc_context_row_last &&
        ({acc_context_head, acc_context_row, acc_context_block} == ((TOTAL_BEATS/8)-1));
    assign output_wr_ready_i = wr_ready && axi_accept_enable;
    assign wr_valid = output_wr_valid_i;
    assign wr_addr = output_wr_addr_i;
    assign wr_data = output_wr_data_i;
    assign wr_row_last = output_wr_row_last_i;
    assign wr_tensor_last = output_wr_tensor_last_i;
    assign v_rsp_ready = 1'b1;
    assign row_token_fire = pv_row_valid_i && slot_pv_ready;
    assign bcast_in_ready = !bcast_active && core_accept_enable;
    assign weight_ready_i = bcast_in_ready;
    assign bcast_valid = bcast_active;
    assign bcast_last = bcast_last_in && (bcast_block == 2'd3);

    // The abort coordinator is deliberately fed owner-domain outstanding
    // status from the integration boundary.  It blocks new writes and output
    // transfers before issuing clear pulses and incrementing epoch.
    cats_r4_abort_drain_controller u_abort (
        .arst_n, .gpio_clk(core_clk), .core_clk, .axi_clk,
        .abort_valid, .abort_ready, .abort_done_valid, .abort_done_ready,
        .abort_done_epoch, .current_epoch,
        .core_outstanding_zero, .axi_outstanding_zero,
        .core_accept_enable, .axi_accept_enable, .core_clear, .axi_clear,
        .drain_active, .abort_count, .drain_cycles, .epoch_wrap_count
    );

    cats_r4_weight_slot_mem u_slot (
        .clk(core_clk), .rst_n(core_rst_n), .clear(local_core_clear),
        .weight_wr_valid(slot_wr_valid), .weight_wr_ready(slot_wr_ready),
        .weight_wr_epoch, .weight_wr_group, .weight_wr_global_q_head,
        .weight_wr_row, .weight_wr_slot_id, .weight_wr_numeric_mode,
        .weight_wr_key, .weight_wr_mask, .weight_wr_data, .weight_wr_last,
        .row_commit_valid(slot_commit_valid), .row_commit_ready(slot_commit_ready),
        .row_commit_epoch, .row_commit_group, .row_commit_global_q_head,
        .row_commit_row, .row_commit_slot_id, .row_commit_numeric_mode,
        .row_commit_sum_fp32, .row_commit_inv_sum_fp32,
        .pv_row_valid(pv_row_valid_i), .pv_row_ready(slot_pv_ready),
        .pv_row_epoch(pv_row_epoch_i), .pv_row_group(pv_row_group_i),
        .pv_row_global_q_head(pv_row_head_i), .pv_row_row(pv_row_row_i),
        .pv_row_slot_id(pv_row_slot_i), .pv_row_numeric_mode(pv_row_mode_i),
        .pv_row_sum_fp32(pv_row_sum_i), .pv_row_inv_sum_fp32(pv_row_inv_i),
        .weight_rd_req_valid(slot_rd_valid), .weight_rd_req_ready(slot_rd_ready),
        .weight_rd_req_epoch(slot_rd_epoch), .weight_rd_req_group(slot_rd_group),
        .weight_rd_req_global_q_head(slot_rd_head), .weight_rd_req_row(slot_rd_row),
        .weight_rd_req_slot_id(slot_rd_slot), .weight_rd_req_numeric_mode(slot_rd_mode),
        .weight_rd_req_key(slot_rd_key),
        .weight_rd_rsp_valid(slot_rsp_valid), .weight_rd_rsp_epoch(slot_rsp_epoch),
        .weight_rd_rsp_group(slot_rsp_group), .weight_rd_rsp_global_q_head(slot_rsp_head),
        .weight_rd_rsp_row(slot_rsp_row), .weight_rd_rsp_slot_id(slot_rsp_slot),
        .weight_rd_rsp_numeric_mode(slot_rsp_mode), .weight_rd_rsp_key(slot_pv_rsp_key),
        .weight_rd_rsp_mask(slot_pv_rsp_mask), .weight_rd_rsp_data(slot_pv_rsp_data),
        .weight_release_valid(slot_release_valid), .weight_release_ready(slot_release_ready),
        .weight_release_epoch(release_epoch_i), .weight_release_group(release_group_i),
        .weight_release_global_q_head(release_head_i), .weight_release_row(release_row_i),
        .weight_release_slot_id(release_slot_i), .weight_release_numeric_mode(release_mode_i),
        .weight_wr_accept, .weight_rd_request, .weight_rd_response,
        .row_commit_count, .pv_row_count, .weight_release_count,
        .owner_error, .mask_error, .last_error, .mode_error, .numeric_error,
        .epoch_drop, .bank_conflict, .outstanding_max
    );

    cats_r4_weight_pv_wrapper u_weight_pv (
        .clk(core_clk), .rst_n(core_rst_n), .clear(local_core_clear),
        .pv_row_valid(pv_row_valid_i), .pv_row_ready(pv_wrapper_ready_i),
        .pv_row_epoch(pv_row_epoch_i), .pv_row_group(pv_row_group_i),
        .pv_row_global_q_head(pv_row_head_i), .pv_row_row(pv_row_row_i),
        .pv_row_slot_id(pv_row_slot_i), .pv_row_numeric_mode(pv_row_mode_i),
        .pv_row_inv_sum_fp32(pv_row_inv_i),
        .weight_rd_req_valid(slot_rd_valid), .weight_rd_req_ready(slot_rd_ready),
        .weight_rd_req_epoch(slot_rd_epoch), .weight_rd_req_group(slot_rd_group),
        .weight_rd_req_global_q_head(slot_rd_head), .weight_rd_req_row(slot_rd_row),
        .weight_rd_req_slot_id(slot_rd_slot), .weight_rd_req_numeric_mode(slot_rd_mode),
        .weight_rd_req_key(slot_rd_key),
        .weight_rd_rsp_valid(slot_rsp_valid), .weight_rd_rsp_epoch(slot_rsp_epoch),
        .weight_rd_rsp_group(slot_rsp_group), .weight_rd_rsp_global_q_head(slot_rsp_head),
        .weight_rd_rsp_row(slot_rsp_row), .weight_rd_rsp_slot_id(slot_rsp_slot),
        .weight_rd_rsp_numeric_mode(slot_rsp_mode), .weight_rd_rsp_key(slot_pv_rsp_key),
        .weight_rd_rsp_mask(slot_pv_rsp_mask), .weight_rd_rsp_data(slot_pv_rsp_data),
        .row_start_valid(row_start_valid_i), .row_start_ready(row_start_ready_i),
        .row_start_inv_sum_fp32(row_start_inv_i),
        .weight_valid(weight_valid_i), .weight_ready(weight_ready_i),
        .weight_key(weight_key_i), .weight_mask(weight_mask_i),
        .weight_data(weight_data_i), .weight_last(weight_last_i),
        .pv_done_valid(pv_done_valid_i), .pv_done_ready(pv_done_ready_i),
        .weight_release_valid(release_valid_i), .weight_release_ready(release_ready_i),
        .weight_release_epoch(release_epoch_i), .weight_release_group(release_group_i),
        .weight_release_global_q_head(release_head_i), .weight_release_row(release_row_i),
        .weight_release_slot_id(release_slot_i), .weight_release_numeric_mode(release_mode_i),
        .rows_started(pv_rows_started), .weights_forwarded(pv_weights_forwarded),
        .rows_released(pv_rows_released), .protocol_error_count(pv_wrapper_errors)
    );

    always_ff @(posedge core_clk) begin
        if (!core_rst_n || local_core_clear) begin
            bcast_active <= 1'b0;
            bcast_key <= '0;
            bcast_block <= '0;
            bcast_data <= '0;
            bcast_last_in <= 1'b0;
        end else begin
            if (!bcast_active && weight_valid_i && bcast_in_ready) begin
                bcast_active <= 1'b1;
                bcast_key <= weight_key_i;
                bcast_data <= weight_data_i;
                bcast_last_in <= weight_last_i;
                bcast_block <= 2'd0;
            end else if (bcast_active && bcast_ready) begin
                if (bcast_block == 2'd3)
                    bcast_active <= 1'b0;
                else
                    bcast_block <= bcast_block + 1'b1;
            end
        end
    end
    cats_r4_pv_weight_v_product_adapter u_product (
        .clk(core_clk), .rst_n(core_rst_n), .clear(local_core_clear),
        .weight_valid(bcast_valid), .weight_ready(bcast_ready),
        .weight_key(bcast_key), .weight_feature_block(bcast_block),
        .weight_fp32(bcast_data), .weight_last(bcast_last),
        .v_req_valid, .v_req_ready, .v_req_key, .v_req_feature_block,
        .v_rsp_valid, .v_rsp_vec,
        .product_valid(product_valid_i), .product_ready(product_ready_i),
        .product_key(product_key_i), .product_feature_block(product_block_i),
        .product_fp32(product_data_i), .product_last(product_last_i),
        .weight_accept_count(adapter_weight_accept), .v_request_count(adapter_v_request),
        .product_emit_count(adapter_product_emit), .protocol_error_count(adapter_protocol_error)
    );

    always_ff @(posedge core_clk) begin
        if (!core_rst_n || local_core_clear) begin
            row_epoch_reg <= '0; row_group_reg <= '0; row_head_reg <= '0;
            row_number_reg <= '0; row_slot_reg <= '0; row_mode_reg <= '0;
        end else if (row_token_fire) begin
            row_epoch_reg <= pv_row_epoch_i; row_group_reg <= pv_row_group_i;
            row_head_reg <= pv_row_head_i; row_number_reg <= pv_row_row_i;
            row_slot_reg <= pv_row_slot_i; row_mode_reg <= pv_row_mode_i;
        end
    end

    cats_r4_pv_fp32_accumulator u_acc (
        .clk(core_clk), .rst_n(core_rst_n), .clear(local_core_clear),
        .row_start_valid(row_start_valid_i), .row_start_ready(row_start_ready_i),
        .row_epoch(row_epoch_reg), .row_group(row_group_reg),
        .row_global_q_head(row_head_reg), .row_number(row_number_reg),
        .row_slot_id(row_slot_reg), .row_numeric_mode(row_mode_reg),
        .row_inv_sum_fp32(row_start_inv_i),
        .product_valid(product_valid_i), .product_ready(product_ready_i),
        .product_key(product_key_i), .product_feature_block(product_block_i),
        .product_fp32(product_data_i), .product_last(product_last_i),
        .context_valid(acc_context_valid), .context_ready(acc_context_ready),
        .context_epoch(acc_context_epoch), .context_group(acc_context_group),
        .context_global_q_head(acc_context_head), .context_row(acc_context_row),
        .context_slot_id(acc_context_slot), .context_numeric_mode(acc_context_mode),
        .context_feature_block(acc_context_block), .context_data_bf16(acc_context_data),
        .context_row_last(acc_context_row_last),
        .product_accept_count, .add_commit_count, .context_emit_count,
        .protocol_error_count(pv_product_errors)
    );
    assign pv_done_valid_i = output_done_sync2 ^ output_done_seen;

    always_ff @(posedge axi_clk) begin
        if (!axi_rst_n || local_axi_clear)
            output_done_toggle_axi <= 1'b0;
        else if (output_done)
            output_done_toggle_axi <= ~output_done_toggle_axi;
    end
    always_ff @(posedge core_clk) begin
        if (!core_rst_n || local_core_clear) begin
            output_done_sync1 <= 1'b0;
            output_done_sync2 <= 1'b0;
            output_done_seen <= 1'b0;
        end else begin
            output_done_sync1 <= output_done_toggle_axi;
            output_done_sync2 <= output_done_sync1;
            if (pv_done_valid_i && pv_done_ready_i)
                output_done_seen <= output_done_sync2;
        end
    end
    cats_r4_output_reorder_cdc_writer_candidate #(.TOTAL_BEATS(TOTAL_BEATS)) u_output (
        .core_clk, .core_rst_n, .core_counter_clear(local_core_clear),
        .in_valid(acc_context_valid), .in_ready(acc_context_ready),
        .in_cluster_id(2'd0),
        .in_epoch(acc_context_epoch), .in_global_q_head(acc_context_head),
        .in_row(acc_context_row), .in_feature_block(acc_context_block),
        .in_data_bf16(acc_context_data), .in_row_last(acc_context_row_last),
        .in_tensor_last(output_context_tensor_last),
        .axi_clk, .axi_rst_n, .axi_counter_clear(local_axi_clear),
        .start(output_start && axi_accept_enable), .base_addr(output_base_addr),
        .wr_valid(output_wr_valid_i), .wr_ready(output_wr_ready_i),
        .wr_addr(output_wr_addr_i), .wr_data(output_wr_data_i),
        .wr_row_last(output_wr_row_last_i), .wr_tensor_last(output_wr_tensor_last_i),
        .busy(output_busy), .done(output_done), .error(output_error),
        .protocol_error_count(cdc_protocol_errors)
    );

    assign output_chunks_accepted = u_output.chunks_accepted;
    assign output_beats_committed = u_output.beats_committed;
    assign protocol_error_count = pv_wrapper_errors | pv_product_errors |
        adapter_protocol_error | cdc_protocol_errors;
    assign rows_started = pv_rows_started;
    assign weights_forwarded = pv_weights_forwarded;
    assign rows_released = pv_rows_released;

    // Protocol assertions are active in simulation and synthesis-safe under
    // the usual SVA-off flow.  They make the frozen contract executable:
    // every accepted B write must be accepted only while core traffic is open,
    // and every output payload must remain stable while stalled.
`ifndef SYNTHESIS
    logic assert_stall_hold;
    logic [31:0] assert_hold_addr;
    logic [63:0] assert_hold_data;
    logic assert_hold_row_last, assert_hold_tensor_last;
    always_ff @(posedge core_clk) begin
        if (!core_rst_n) begin
        end else if (!core_accept_enable && slot_wr_valid) begin
            $error("IF_V3 write accepted while abort drain is active");
        end
    end
    always_ff @(posedge axi_clk) begin
        if (!axi_rst_n) begin
            assert_stall_hold <= 1'b0;
            assert_hold_addr <= '0;
            assert_hold_data <= '0;
            assert_hold_row_last <= 1'b0;
            assert_hold_tensor_last <= 1'b0;
        end else begin
            if (assert_stall_hold) begin
                if (!wr_valid || wr_addr !== assert_hold_addr ||
                    wr_data !== assert_hold_data ||
                    wr_row_last !== assert_hold_row_last ||
                    wr_tensor_last !== assert_hold_tensor_last)
                    $error("output writer payload changed under backpressure");
            end
            assert_stall_hold <= wr_valid && !wr_ready;
            if (wr_valid && !wr_ready) begin
                assert_hold_addr <= wr_addr;
                assert_hold_data <= wr_data;
                assert_hold_row_last <= wr_row_last;
                assert_hold_tensor_last <= wr_tensor_last;
            end
        end
    end
`endif
endmodule