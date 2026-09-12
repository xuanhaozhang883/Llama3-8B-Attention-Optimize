`timescale 1ns/1ps

// Test-only all-equal-score B2 protocol model.  Full B4 scale tests use this
// lightweight implementation; production and direct arithmetic tests compile
// the real shared wrapper instead.
module cats_r4_b2_shared_stager_v3_wrapper #(
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input logic clk,input logic rst_n,input logic clear,input logic counter_clear,
    input logic row_valid,output logic row_ready,
    input logic [15:0] row_epoch,input logic [2:0] row_group,
    input logic [4:0] row_global_q_head,input logic [6:0] row_index,
    input logic [1:0] row_slot_id,input logic [1:0] row_numeric_mode,
    input logic [15:0] row_max_bf16,
    input logic score_valid,output logic score_ready,
    input logic [15:0] score_epoch,input logic [2:0] score_group,
    input logic [4:0] score_global_q_head,input logic [6:0] score_row,
    input logic [1:0] score_slot_id,input logic [1:0] score_numeric_mode,
    input logic [6:0] score_key,input logic [15:0] score_bf16,
    input logic score_last,
    output logic weight_wr_valid,input logic weight_wr_ready,
    output logic [15:0] weight_wr_epoch,output logic [2:0] weight_wr_group,
    output logic [4:0] weight_wr_global_q_head,
    output logic [6:0] weight_wr_row,output logic [1:0] weight_wr_slot_id,
    output logic [1:0] weight_wr_numeric_mode,
    output logic [6:0] weight_wr_key,output logic weight_wr_mask,
    output logic [31:0] weight_wr_data,output logic weight_wr_last,
    output logic row_commit_valid,input logic row_commit_ready,
    output logic [15:0] row_commit_epoch,output logic [2:0] row_commit_group,
    output logic [4:0] row_commit_global_q_head,
    output logic [6:0] row_commit_row,output logic [1:0] row_commit_slot_id,
    output logic [1:0] row_commit_numeric_mode,
    output logic [31:0] row_commit_sum_fp32,
    output logic [31:0] row_commit_inv_sum_fp32,
    output logic row_error_valid,input logic row_error_ready,
    output logic [15:0] row_error_epoch,output logic [2:0] row_error_group,
    output logic [4:0] row_error_global_q_head,
    output logic [6:0] row_error_row,output logic [1:0] row_error_slot_id,
    output logic [1:0] row_error_numeric_mode,
    output logic [3:0] row_error_code,output logic [6:0] row_error_bad_key,
    input logic slot_release_valid,output logic slot_release_ready,
    input logic [15:0] slot_release_epoch,input logic [2:0] slot_release_group,
    input logic [4:0] slot_release_global_q_head,
    input logic [6:0] slot_release_row,
    input logic [1:0] slot_release_slot_id,
    input logic [1:0] slot_release_numeric_mode,
    output logic [2:0] slot_owned_state,output logic [5:0] slot_mode_state,
    output logic [63:0] rows_issue,output logic [63:0] rows_result,
    output logic [63:0] exp_issue,output logic [63:0] exp_result,
    output logic [63:0] exp_commit,output logic [63:0] sum_issue,
    output logic [63:0] sum_result,output logic [63:0] sum_commit,
    output logic [63:0] reciprocal_issue,
    output logic [63:0] reciprocal_result,
    output logic [63:0] reciprocal_commit,
    output logic [63:0] staged_weight_accept,
    output logic [63:0] weight_wr_accept,
    output logic [63:0] row_commit_count,
    output logic [63:0] slot_release_count,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_error_count,
    output logic [63:0] owner_error_count,
    output logic [63:0] mask_error_count,
    output logic [63:0] mode_error_count,
    output logic [63:0] weight_conflict_cycles,
    output logic [63:0] finalize_conflict_cycles,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] exp_stall_cycles,
    output logic [63:0] sum_stall_cycles,
    output logic [63:0] reciprocal_busy_stall_cycles,
    output logic [63:0] reciprocal_output_stall_cycles,
    output logic error_sticky
);
    localparam logic [2:0] S_FREE=0,S_FILL=1,S_PUBLISH=2,
                           S_COMMIT=3,S_HELD=4;
    logic [2:0] state [0:2];
    logic [15:0] token_epoch [0:2];
    logic [2:0] token_group [0:2];
    logic [4:0] token_head [0:2];
    logic [6:0] token_row [0:2];
    logic [1:0] token_mode [0:2];
    logic [7:0] score_count [0:2];
    logic publish_active;
    logic [1:0] publish_slot;
    logic [7:0] publish_key;
    logic commit_found;
    logic [1:0] commit_slot;
    logic row_fire,score_fire,weight_fire,commit_fire,release_fire;
    integer idx;

    function automatic logic [31:0] positive_integer_fp32(input integer value);
        integer msb,scan,fraction;
        begin
            if (value == 0) positive_integer_fp32 = 0;
            else begin
                msb = 0;
                for (scan=0;scan<8;scan=scan+1)
                    if (value >= (1<<scan)) msb=scan;
                fraction=(value-(1<<msb))<<(23-msb);
                positive_integer_fp32=((127+msb)<<23)|fraction;
            end
        end
    endfunction

    always_comb begin
        row_ready=row_slot_id<3 && state[row_slot_id]==S_FREE;
        score_ready=score_slot_id<3 && state[score_slot_id]==S_FILL;
        commit_found=1'b0;
        commit_slot=0;
        for (idx=0;idx<3;idx=idx+1)
            if (!commit_found && state[idx]==S_COMMIT) begin
                commit_found=1'b1;
                commit_slot=idx[1:0];
            end
    end
    assign row_fire=row_valid&&row_ready;
    assign score_fire=score_valid&&score_ready;
    assign weight_wr_valid=publish_active;
    assign weight_wr_epoch=token_epoch[publish_slot];
    assign weight_wr_group=token_group[publish_slot];
    assign weight_wr_global_q_head=token_head[publish_slot];
    assign weight_wr_row=token_row[publish_slot];
    assign weight_wr_slot_id=publish_slot;
    assign weight_wr_numeric_mode=token_mode[publish_slot];
    assign weight_wr_key=publish_key[6:0];
    assign weight_wr_mask=publish_key>token_row[publish_slot];
    assign weight_wr_data=weight_wr_mask ? 0 :
        (token_mode[publish_slot]==0 ? 32'h00003f80 : 32'h3f800000);
    assign weight_wr_last=publish_key==127;
    assign weight_fire=weight_wr_valid&&weight_wr_ready;
    assign row_commit_valid=commit_found;
    assign row_commit_epoch=token_epoch[commit_slot];
    assign row_commit_group=token_group[commit_slot];
    assign row_commit_global_q_head=token_head[commit_slot];
    assign row_commit_row=token_row[commit_slot];
    assign row_commit_slot_id=commit_slot;
    assign row_commit_numeric_mode=token_mode[commit_slot];
    assign row_commit_sum_fp32=positive_integer_fp32(token_row[commit_slot]+1);
    assign row_commit_inv_sum_fp32=32'h3f800000;
    assign commit_fire=row_commit_valid&&row_commit_ready;
    assign row_error_valid=1'b0;
    assign row_error_epoch=0;
    assign row_error_group=0;
    assign row_error_global_q_head=0;
    assign row_error_row=0;
    assign row_error_slot_id=0;
    assign row_error_numeric_mode=0;
    assign row_error_code=0;
    assign row_error_bad_key=0;
    assign slot_release_ready=slot_release_slot_id<3 &&
        state[slot_release_slot_id]==S_HELD &&
        token_epoch[slot_release_slot_id]==slot_release_epoch &&
        token_group[slot_release_slot_id]==slot_release_group &&
        token_head[slot_release_slot_id]==slot_release_global_q_head &&
        token_row[slot_release_slot_id]==slot_release_row &&
        token_mode[slot_release_slot_id]==slot_release_numeric_mode;
    assign release_fire=slot_release_valid&&slot_release_ready;
    assign slot_owned_state={state[2]!=S_FREE,state[1]!=S_FREE,
                             state[0]!=S_FREE};
    assign slot_mode_state={token_mode[2],token_mode[1],token_mode[0]};

    always_ff @(posedge clk or negedge rst_n) begin
        integer slot;
        if (!rst_n) begin
            publish_active<=0;publish_slot<=0;publish_key<=0;
            for (idx=0;idx<3;idx=idx+1) begin
                state[idx]<=S_FREE;token_epoch[idx]<=0;token_group[idx]<=0;
                token_head[idx]<=0;token_row[idx]<=0;token_mode[idx]<=0;
                score_count[idx]<=0;
            end
        end else if (clear) begin
            publish_active<=0;
            for (idx=0;idx<3;idx=idx+1) begin
                state[idx]<=S_FREE;score_count[idx]<=0;
            end
        end else begin
            if (row_fire) begin
                slot=row_slot_id;
                if (row_group!=row_global_q_head[4:2] ||
                    row_numeric_mode>=2 || row_max_bf16!=0)
                    $fatal(1,"B4 B2 model invalid row header");
                state[slot]<=S_FILL;token_epoch[slot]<=row_epoch;
                token_group[slot]<=row_group;token_head[slot]<=row_global_q_head;
                token_row[slot]<=row_index;token_mode[slot]<=row_numeric_mode;
                score_count[slot]<=0;
            end
            if (score_fire) begin
                slot=score_slot_id;
                if (score_epoch!=token_epoch[slot] ||
                    score_group!=token_group[slot] ||
                    score_global_q_head!=token_head[slot] ||
                    score_row!=token_row[slot] ||
                    score_numeric_mode!=token_mode[slot] ||
                    score_key!=score_count[slot] || score_bf16!=0 ||
                    score_last!=(score_key==token_row[slot]))
                    $fatal(1,"B4 B2 model score/token mismatch");
                score_count[slot]<=score_count[slot]+1'b1;
                if (score_last) state[slot]<=S_PUBLISH;
            end
            if (!publish_active) begin
                if (state[0]==S_PUBLISH) begin
                    publish_active<=1;publish_slot<=0;publish_key<=0;
                end else if (state[1]==S_PUBLISH) begin
                    publish_active<=1;publish_slot<=1;publish_key<=0;
                end else if (state[2]==S_PUBLISH) begin
                    publish_active<=1;publish_slot<=2;publish_key<=0;
                end
            end else if (weight_fire) begin
                if (publish_key==127) begin
                    state[publish_slot]<=S_COMMIT;publish_active<=0;
                end else publish_key<=publish_key+1'b1;
            end
            if (commit_fire) state[commit_slot]<=S_HELD;
            if (release_fire) begin
                state[slot_release_slot_id]<=S_FREE;
                score_count[slot_release_slot_id]<=0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rows_issue<=0;rows_result<=0;exp_issue<=0;exp_result<=0;
            exp_commit<=0;sum_issue<=0;sum_result<=0;sum_commit<=0;
            reciprocal_issue<=0;reciprocal_result<=0;reciprocal_commit<=0;
            staged_weight_accept<=0;weight_wr_accept<=0;row_commit_count<=0;
            slot_release_count<=0;protocol_error_count<=0;numeric_error_count<=0;
            owner_error_count<=0;mask_error_count<=0;mode_error_count<=0;
            weight_conflict_cycles<=0;finalize_conflict_cycles<=0;
            output_stall_cycles<=0;exp_stall_cycles<=0;sum_stall_cycles<=0;
            reciprocal_busy_stall_cycles<=0;reciprocal_output_stall_cycles<=0;
            error_sticky<=0;
        end else if (counter_clear) begin
            rows_issue<=0;rows_result<=0;exp_issue<=0;exp_result<=0;
            exp_commit<=0;sum_issue<=0;sum_result<=0;sum_commit<=0;
            reciprocal_issue<=0;reciprocal_result<=0;reciprocal_commit<=0;
            staged_weight_accept<=0;weight_wr_accept<=0;row_commit_count<=0;
            slot_release_count<=0;output_stall_cycles<=0;
        end else begin
            if (row_fire) rows_issue<=rows_issue+1'b1;
            if (score_fire) begin
                exp_issue<=exp_issue+1'b1;exp_result<=exp_result+1'b1;
                exp_commit<=exp_commit+1'b1;sum_issue<=sum_issue+1'b1;
                sum_result<=sum_result+1'b1;sum_commit<=sum_commit+1'b1;
                staged_weight_accept<=staged_weight_accept+1'b1;
                if (score_last) begin
                    rows_result<=rows_result+1'b1;
                    reciprocal_issue<=reciprocal_issue+1'b1;
                    reciprocal_result<=reciprocal_result+1'b1;
                    reciprocal_commit<=reciprocal_commit+1'b1;
                end
            end
            if (weight_fire) weight_wr_accept<=weight_wr_accept+1'b1;
            if (commit_fire) row_commit_count<=row_commit_count+1'b1;
            if (release_fire) slot_release_count<=slot_release_count+1'b1;
            if ((weight_wr_valid&&!weight_wr_ready)||
                (row_commit_valid&&!row_commit_ready))
                output_stall_cycles<=output_stall_cycles+1'b1;
        end
    end

    logic unused;
    assign unused=row_error_ready|row_max_bf16[0]|score_bf16[0];
endmodule
