`timescale 1ns/1ps

module cats_r4_qk_row_handoff_wrapper #(
    parameter int SEQ_LEN=128, LANES=32, SLOTS=3
) (
    input logic clk,rst_n,clear,counter_clear,
    input logic txn_start_valid, output logic txn_start_ready,
    input logic [15:0] txn_epoch, input logic [1:0] txn_numeric_mode,
    input logic row_open_valid, output logic row_open_ready,
    input logic [15:0] row_open_epoch, input logic [2:0] row_open_group,
    input logic [4:0] row_open_global_q_head, input logic [6:0] row_open_row,
    input logic [1:0] row_open_slot_id,row_open_numeric_mode,
    input logic block_valid, output logic block_ready,
    input logic [15:0] block_epoch, input logic [2:0] block_group,
    input logic [4:0] block_global_q_head, input logic [6:0] block_row,
    input logic [1:0] block_slot_id,block_numeric_mode,block_key_block,
    input logic [LANES-1:0] block_lane_valid,
    input logic [LANES*16-1:0] block_score_bf16,
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
    output logic protocol_error_sticky
);
    logic asm_open_valid,asm_open_ready;
    logic owner_reserve_valid,owner_reserve_ready;
    logic ar_valid,ar_ready; logic [15:0] ar_epoch,ar_max;
    logic [2:0] ar_group; logic [4:0] ar_head; logic [6:0] ar_row;
    logic [1:0] ar_slot,ar_mode;
    logic aa_valid,aa_ready; logic [15:0] aa_epoch; logic [2:0] aa_group;
    logic [4:0] aa_head; logic [6:0] aa_row,aa_key;
    logic [1:0] aa_slot,aa_mode; logic [2:0] aa_code;
    logic ha_valid,ha_ready; logic [15:0] ha_epoch; logic [2:0] ha_group;
    logic [4:0] ha_head; logic [6:0] ha_row,ha_key;
    logic [1:0] ha_slot,ha_mode; logic [2:0] ha_code;
    logic hs_valid,hs_ready,hs_last; logic [15:0] hs_epoch,hs_data;
    logic [2:0] hs_group; logic [4:0] hs_head; logic [6:0] hs_row,hs_key;
    logic [1:0] hs_slot,hs_mode;
    logic owner_handoff_valid,owner_handoff_ready;
    logic asm_sticky,ho_sticky,owner_sticky;

    assign row_open_ready=asm_open_ready&&owner_reserve_ready;
    assign asm_open_valid=row_open_valid&&owner_reserve_ready;
    assign owner_reserve_valid=row_open_valid&&asm_open_ready;

    cats_r4_qk_row_assembler #(.SEQ_LEN(SEQ_LEN),.LANES(LANES),.SLOTS(SLOTS)) u_assembler(
        .clk,.rst_n,.clear,.counter_clear,.txn_start_valid,.txn_start_ready,.txn_epoch,.txn_numeric_mode,
        .row_open_valid(asm_open_valid),.row_open_ready(asm_open_ready),.row_open_epoch,.row_open_group,
        .row_open_global_q_head,.row_open_row,.row_open_slot_id,.row_open_numeric_mode,
        .block_valid,.block_ready,.block_epoch,.block_group,.block_global_q_head,.block_row,
        .block_slot_id,.block_numeric_mode,.block_key_block,.block_lane_valid,.block_score_bf16,
        .store_wr_valid,.store_wr_ready,.store_wr_slot_id,.store_wr_key_base,.store_wr_lane_valid,.store_wr_score_bf16,
        .row_valid(ar_valid),.row_ready(ar_ready),.row_epoch(ar_epoch),.row_group(ar_group),
        .row_global_q_head(ar_head),.row_index(ar_row),.row_slot_id(ar_slot),.row_numeric_mode(ar_mode),.row_max_bf16(ar_max),
        .abort_valid(aa_valid),.abort_ready(aa_ready),.abort_epoch(aa_epoch),.abort_group(aa_group),
        .abort_global_q_head(aa_head),.abort_row(aa_row),.abort_slot_id(aa_slot),.abort_numeric_mode(aa_mode),
        .abort_error_code(aa_code),.abort_error_key(aa_key),.rows_opened(),.blocks_accepted(),.scores_accepted(),
        .rows_completed,.protocol_errors(),.numeric_errors(),.mode_errors(),.protocol_error_sticky(asm_sticky));

    cats_r4_qk_ab_handoff u_handoff(
        .clk,.rst_n,.clear,.counter_clear,.in_row_valid(ar_valid),.in_row_ready(ar_ready),
        .in_row_epoch(ar_epoch),.in_row_group(ar_group),.in_row_global_q_head(ar_head),.in_row_index(ar_row),
        .in_row_slot_id(ar_slot),.in_row_numeric_mode(ar_mode),.in_row_max_bf16(ar_max),
        .score_rd_req_valid,.score_rd_req_ready,.score_rd_req_epoch,.score_rd_req_group,
        .score_rd_req_global_q_head,.score_rd_req_row,.score_rd_req_slot_id,.score_rd_req_numeric_mode,.score_rd_req_key,
        .score_rd_rsp_valid,.score_rd_rsp_ready,.score_rd_rsp_epoch,.score_rd_rsp_group,
        .score_rd_rsp_global_q_head,.score_rd_rsp_row,.score_rd_rsp_slot_id,.score_rd_rsp_numeric_mode,
        .score_rd_rsp_key,.score_rd_rsp_bf16,.row_valid(b_row_valid),.row_ready(b_row_ready),
        .row_epoch(b_row_epoch),.row_group(b_row_group),.row_global_q_head(b_row_global_q_head),
        .row_index(b_row_index),.row_slot_id(b_row_slot_id),.row_numeric_mode(b_row_numeric_mode),.row_max_bf16(b_row_max_bf16),
        .score_valid(hs_valid),.score_ready(hs_ready),.score_epoch(hs_epoch),.score_group(hs_group),
        .score_global_q_head(hs_head),.score_row(hs_row),.score_slot_id(hs_slot),.score_numeric_mode(hs_mode),
        .score_key(hs_key),.score_bf16(hs_data),.score_last(hs_last),
        .abort_valid(ha_valid),.abort_ready(ha_ready),.abort_epoch(ha_epoch),.abort_group(ha_group),
        .abort_global_q_head(ha_head),.abort_row(ha_row),.abort_slot_id(ha_slot),.abort_numeric_mode(ha_mode),
        .abort_error_code(ha_code),.abort_error_key(ha_key),.row_headers_transferred(),.score_reads_requested(),
        .score_reads_returned(),.scores_transferred,.rows_transferred,.protocol_errors(),.numeric_errors(),
        .protocol_error_sticky(ho_sticky));

    assign b_score_valid=hs_valid&&(!hs_last||owner_handoff_ready);
    assign hs_ready=b_score_ready&&(!hs_last||owner_handoff_ready);
    assign b_score_epoch=hs_epoch; assign b_score_group=hs_group; assign b_score_global_q_head=hs_head;
    assign b_score_row=hs_row; assign b_score_slot_id=hs_slot; assign b_score_numeric_mode=hs_mode;
    assign b_score_key=hs_key; assign b_score_bf16=hs_data; assign b_score_last=hs_last;
    assign owner_handoff_valid=hs_valid&&hs_last&&b_score_ready;

    cats_r4_qk_slot_lifecycle u_owner(
        .clk,.rst_n,.clear,.counter_clear,.reserve_valid(owner_reserve_valid),.reserve_ready(owner_reserve_ready),
        .reserve_epoch(row_open_epoch),.reserve_group(row_open_group),.reserve_global_q_head(row_open_global_q_head),
        .reserve_row(row_open_row),.reserve_slot_id(row_open_slot_id),.reserve_numeric_mode(row_open_numeric_mode),
        .handoff_valid(owner_handoff_valid),.handoff_ready(owner_handoff_ready),.handoff_epoch(hs_epoch),
        .handoff_group(hs_group),.handoff_global_q_head(hs_head),.handoff_row(hs_row),
        .handoff_slot_id(hs_slot),.handoff_numeric_mode(hs_mode),.release_valid(final_release_valid),
        .release_ready(final_release_ready),.release_epoch(final_release_epoch),.release_group(final_release_group),
        .release_global_q_head(final_release_global_q_head),.release_row(final_release_row),
        .release_slot_id(final_release_slot_id),.release_numeric_mode(final_release_numeric_mode),
        .slot_owner,.reserves(),.handoffs(),.releases(),.owner_errors,.owner_error_sticky(owner_sticky));

    cats_r4_qk_row_abort_arbiter u_abort_arbiter(
        .clk,.rst_n,.clear,
        .a_valid(aa_valid),.a_ready(aa_ready),.a_epoch(aa_epoch),.a_group(aa_group),
        .a_head(aa_head),.a_row(aa_row),.a_slot(aa_slot),.a_mode(aa_mode),.a_code(aa_code),.a_key(aa_key),
        .b_valid(ha_valid),.b_ready(ha_ready),.b_epoch(ha_epoch),.b_group(ha_group),
        .b_head(ha_head),.b_row(ha_row),.b_slot(ha_slot),.b_mode(ha_mode),.b_code(ha_code),.b_key(ha_key),
        .out_valid(row_abort_valid),.out_ready(row_abort_ready),.out_epoch(row_abort_epoch),
        .out_group(row_abort_group),.out_head(row_abort_global_q_head),.out_row(row_abort_row),
        .out_slot(row_abort_slot_id),.out_mode(row_abort_numeric_mode),
        .out_code(row_abort_error_code),.out_key(row_abort_error_key));
    assign protocol_error_sticky=asm_sticky||ho_sticky||owner_sticky;
endmodule
