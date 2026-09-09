`timescale 1ns/1ps

// A2 score-commit path: raw QK vectors -> scaled BF16 rows -> frozen A-to-B stream.
module cats_r4_qk_a2_row_pipeline #(
    parameter int SEQ_LEN=128, LANES=32, SLOTS=3,
    parameter logic [31:0] SCALE_FP32=32'h3db5_04f3
) (
    input logic clk,rst_n,clear,counter_clear,
    input logic txn_start_valid,output logic txn_start_ready,
    input logic [15:0] txn_epoch,input logic [1:0] txn_numeric_mode,
    input logic raw_score_valid,output logic raw_score_ready,
    input logic [15:0] raw_score_epoch,input logic [2:0] raw_score_group,
    input logic [4:0] raw_score_global_q_head,input logic [6:0] raw_score_row,
    input logic [1:0] raw_score_key_block,input logic [3:0] raw_score_context_tag,
    input logic [LANES-1:0] raw_score_lane_valid,
    input logic [LANES*32-1:0] raw_score_fp32,
    output logic store_wr_valid,input logic store_wr_ready,
    output logic [1:0] store_wr_slot_id,output logic [6:0] store_wr_key_base,
    output logic [LANES-1:0] store_wr_lane_valid,
    output logic [LANES*16-1:0] store_wr_score_bf16,
    output logic score_rd_req_valid,input logic score_rd_req_ready,
    output logic [15:0] score_rd_req_epoch,output logic [2:0] score_rd_req_group,
    output logic [4:0] score_rd_req_global_q_head,
    output logic [6:0] score_rd_req_row,score_rd_req_key,
    output logic [1:0] score_rd_req_slot_id,score_rd_req_numeric_mode,
    input logic score_rd_rsp_valid,output logic score_rd_rsp_ready,
    input logic [15:0] score_rd_rsp_epoch,input logic [2:0] score_rd_rsp_group,
    input logic [4:0] score_rd_rsp_global_q_head,
    input logic [6:0] score_rd_rsp_row,score_rd_rsp_key,
    input logic [1:0] score_rd_rsp_slot_id,score_rd_rsp_numeric_mode,
    input logic [15:0] score_rd_rsp_bf16,
    output logic b_row_valid,input logic b_row_ready,
    output logic [15:0] b_row_epoch,output logic [2:0] b_row_group,
    output logic [4:0] b_row_global_q_head,output logic [6:0] b_row_index,
    output logic [1:0] b_row_slot_id,b_row_numeric_mode,
    output logic [15:0] b_row_max_bf16,
    output logic b_score_valid,input logic b_score_ready,
    output logic [15:0] b_score_epoch,output logic [2:0] b_score_group,
    output logic [4:0] b_score_global_q_head,
    output logic [6:0] b_score_row,b_score_key,
    output logic [1:0] b_score_slot_id,b_score_numeric_mode,
    output logic [15:0] b_score_bf16,output logic b_score_last,
    input logic final_release_valid,output logic final_release_ready,
    input logic [15:0] final_release_epoch,input logic [2:0] final_release_group,
    input logic [4:0] final_release_global_q_head,input logic [6:0] final_release_row,
    input logic [1:0] final_release_slot_id,final_release_numeric_mode,
    output logic row_abort_valid,input logic row_abort_ready,
    output logic [15:0] row_abort_epoch,output logic [2:0] row_abort_group,
    output logic [4:0] row_abort_global_q_head,
    output logic [6:0] row_abort_row,row_abort_error_key,
    output logic [1:0] row_abort_slot_id,row_abort_numeric_mode,
    output logic [2:0] row_abort_error_code,
    output logic [5:0] slot_owner,
    output logic [63:0] rows_completed,scores_transferred,rows_transferred,owner_errors,
    output logic [63:0] scale_requests_accepted,scale_products_completed,
    output logic [63:0] score_format_transfers,formatter_protocol_errors,
    output logic protocol_error_sticky
);
    logic txn_mode_valid;
    logic [1:0] txn_mode_reg;
    logic fmt_in_ready,fmt_out_valid,fmt_out_ready;
    logic [15:0] fmt_epoch; logic [2:0] fmt_group; logic [4:0] fmt_head;
    logic [6:0] fmt_row; logic [1:0] fmt_key_block; logic [3:0] fmt_context;
    logic [LANES-1:0] fmt_lane_valid; logic [LANES*16-1:0] fmt_bf16;
    logic [LANES*32-1:0] fmt_scaled_fp32;
    logic fmt_sticky,row_sticky;
    logic formatted_row_opened;
    logic row_open_valid,row_open_ready,block_valid,block_ready;

    assign raw_score_ready=txn_mode_valid&&fmt_in_ready;
    assign row_open_valid=fmt_out_valid&&(fmt_key_block==0)&&!formatted_row_opened;
    assign block_valid=fmt_out_valid&&((fmt_key_block!=0)||formatted_row_opened);
    assign fmt_out_ready=block_valid&&block_ready;
    assign protocol_error_sticky=fmt_sticky||row_sticky;

    always_ff @(posedge clk) begin
        if(!rst_n||clear) begin
            txn_mode_valid<=0;txn_mode_reg<=0;formatted_row_opened<=0;
        end else begin
            if(txn_start_valid&&txn_start_ready) begin
                txn_mode_valid<=1;txn_mode_reg<=txn_numeric_mode;
            end
            if(row_open_valid&&row_open_ready) formatted_row_opened<=1;
            if(block_valid&&block_ready) formatted_row_opened<=0;
        end
    end

    cats_r4_qk_score_formatter #(.LANES(LANES),.SCALE_FP32(SCALE_FP32)) u_formatter(
        .clk,.rst_n,.clear,.counter_clear,
        .in_valid(raw_score_valid&&txn_mode_valid),.in_ready(fmt_in_ready),
        .in_epoch(raw_score_epoch),.in_group(raw_score_group),
        .in_global_q_head(raw_score_global_q_head),.in_row(raw_score_row),
        .in_key_block(raw_score_key_block),.in_context_tag(raw_score_context_tag),
        .in_lane_valid(raw_score_lane_valid),.in_raw_fp32(raw_score_fp32),
        .out_valid(fmt_out_valid),.out_ready(fmt_out_ready),.out_epoch(fmt_epoch),
        .out_group(fmt_group),.out_global_q_head(fmt_head),.out_row(fmt_row),
        .out_key_block(fmt_key_block),.out_context_tag(fmt_context),
        .out_lane_valid(fmt_lane_valid),.out_scaled_fp32(fmt_scaled_fp32),
        .out_score_bf16(fmt_bf16),.scale_requests_accepted,.scale_products_completed,
        .score_format_transfers,.protocol_errors(formatter_protocol_errors),
        .protocol_error_sticky(fmt_sticky));

    cats_r4_qk_row_handoff_wrapper #(.SEQ_LEN(SEQ_LEN),.LANES(LANES),.SLOTS(SLOTS)) u_rows(
        .clk,.rst_n,.clear,.counter_clear,.txn_start_valid,.txn_start_ready,.txn_epoch,.txn_numeric_mode,
        .row_open_valid,.row_open_ready,.row_open_epoch(fmt_epoch),.row_open_group(fmt_group),
        .row_open_global_q_head(fmt_head),.row_open_row(fmt_row),.row_open_slot_id(fmt_context[1:0]),
        .row_open_numeric_mode(txn_mode_reg),.block_valid,.block_ready,.block_epoch(fmt_epoch),
        .block_group(fmt_group),.block_global_q_head(fmt_head),.block_row(fmt_row),
        .block_slot_id(fmt_context[1:0]),.block_numeric_mode(txn_mode_reg),
        .block_key_block(fmt_key_block),.block_lane_valid(fmt_lane_valid),.block_score_bf16(fmt_bf16),
        .store_wr_valid,.store_wr_ready,.store_wr_slot_id,.store_wr_key_base,.store_wr_lane_valid,.store_wr_score_bf16,
        .score_rd_req_valid,.score_rd_req_ready,.score_rd_req_epoch,.score_rd_req_group,
        .score_rd_req_global_q_head,.score_rd_req_row,.score_rd_req_key,
        .score_rd_req_slot_id,.score_rd_req_numeric_mode,.score_rd_rsp_valid,.score_rd_rsp_ready,
        .score_rd_rsp_epoch,.score_rd_rsp_group,.score_rd_rsp_global_q_head,.score_rd_rsp_row,
        .score_rd_rsp_key,.score_rd_rsp_slot_id,.score_rd_rsp_numeric_mode,.score_rd_rsp_bf16,
        .b_row_valid,.b_row_ready,.b_row_epoch,.b_row_group,.b_row_global_q_head,.b_row_index,
        .b_row_slot_id,.b_row_numeric_mode,.b_row_max_bf16,.b_score_valid,.b_score_ready,
        .b_score_epoch,.b_score_group,.b_score_global_q_head,.b_score_row,.b_score_key,
        .b_score_slot_id,.b_score_numeric_mode,.b_score_bf16,.b_score_last,
        .final_release_valid,.final_release_ready,.final_release_epoch,.final_release_group,
        .final_release_global_q_head,.final_release_row,.final_release_slot_id,.final_release_numeric_mode,
        .row_abort_valid,.row_abort_ready,.row_abort_epoch,.row_abort_group,.row_abort_global_q_head,
        .row_abort_row,.row_abort_error_key,.row_abort_slot_id,.row_abort_numeric_mode,
        .row_abort_error_code,.slot_owner,.rows_completed,.scores_transferred,.rows_transferred,
        .owner_errors,.protocol_error_sticky(row_sticky));
endmodule
