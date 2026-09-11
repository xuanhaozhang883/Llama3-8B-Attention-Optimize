`timescale 1ns/1ps

// V3-token adapter around the Compatibility arithmetic core only.  Staging
// is deliberately external so Compatibility and Accuracy can share exactly
// one scheme-A weight stager in the common B2 wrapper.
module cats_r4_b2_compatibility_core_adapter #(
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        counter_clear,

    input  logic        row_valid,
    output logic        row_ready,
    input  logic [15:0] row_epoch,
    input  logic [2:0]  row_group,
    input  logic [4:0]  row_global_q_head,
    input  logic [6:0]  row_index,
    input  logic [1:0]  row_slot_id,
    input  logic [1:0]  row_numeric_mode,
    input  logic [15:0] row_max_bf16,

    input  logic        score_valid,
    output logic        score_ready,
    input  logic [15:0] score_epoch,
    input  logic [2:0]  score_group,
    input  logic [4:0]  score_global_q_head,
    input  logic [6:0]  score_row,
    input  logic [1:0]  score_slot_id,
    input  logic [1:0]  score_numeric_mode,
    input  logic [6:0]  score_key,
    input  logic [15:0] score_bf16,
    input  logic        score_last,

    output logic        weight_valid,
    input  logic        weight_ready,
    output logic [15:0] weight_epoch,
    output logic [2:0]  weight_group,
    output logic [4:0]  weight_global_q_head,
    output logic [6:0]  weight_row,
    output logic [1:0]  weight_slot_id,
    output logic [1:0]  weight_numeric_mode,
    output logic [6:0]  weight_key,
    output logic [31:0] weight_data,
    output logic        weight_last,

    output logic        done_valid,
    input  logic        done_ready,
    output logic [15:0] done_epoch,
    output logic [2:0]  done_group,
    output logic [4:0]  done_global_q_head,
    output logic [6:0]  done_row,
    output logic [1:0]  done_slot_id,
    output logic [1:0]  done_numeric_mode,
    output logic [31:0] done_sum_fp32,
    output logic [31:0] done_inv_sum_fp32,
    output logic        done_error,

    output logic [63:0] rows_issue,
    output logic [63:0] rows_result,
    output logic [63:0] rows_commit,
    output logic [63:0] exp_issue,
    output logic [63:0] exp_result,
    output logic [63:0] exp_commit,
    output logic [63:0] sum_issue,
    output logic [63:0] sum_result,
    output logic [63:0] sum_commit,
    output logic [63:0] reciprocal_issue,
    output logic [63:0] reciprocal_result,
    output logic [63:0] reciprocal_commit,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] reciprocal_busy_stall_cycles,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_special_count,
    output logic        error_sticky
);
    logic [3:0] core_weight_context;
    logic [15:0] core_weight_bf16;
    logic [3:0] core_done_context;
    logic [22:0] core_done_sum_q15;
    logic [30:0] core_done_reciprocal_q30;
    logic [63:0] core_weight_issue;
    logic [63:0] core_weight_result;
    logic [63:0] core_weight_commit;
    logic core_clear;

    // The legacy Compatibility core resets counters together with state.
    // The common wrapper therefore permits counter_clear only while quiescent.
    assign core_clear = clear || counter_clear;

    function automatic logic [31:0] q15_sum_to_fp32(
        input logic [22:0] sum_q15
    );
        integer msb_index;
        integer bit_index;
        logic [46:0] normalized;
        logic [7:0] exponent;
        begin
            if (sum_q15 == 0) begin
                q15_sum_to_fp32 = 0;
            end else begin
                msb_index = 0;
                for (bit_index = 0; bit_index < 23;
                     bit_index = bit_index + 1)
                    if (sum_q15[bit_index])
                        msb_index = bit_index;
                exponent = msb_index + 112;
                normalized = {24'd0, sum_q15} << (23-msb_index);
                q15_sum_to_fp32 = {1'b0, exponent, normalized[22:0]};
            end
        end
    endfunction

    assign weight_group = weight_global_q_head[4:2];
    assign weight_slot_id = core_weight_context[1:0];
    assign weight_numeric_mode = 0;
    assign weight_data = {16'd0, core_weight_bf16};
    assign done_group = done_global_q_head[4:2];
    assign done_slot_id = core_done_context[1:0];
    assign done_numeric_mode = 0;
    assign done_sum_fp32 = q15_sum_to_fp32(core_done_sum_q15);

    cats_r4_row_softmax_compatibility #(
        .CONTEXTS(16),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_core (
        .clk,
        .rst_n,
        .clear(core_clear),
        .row_valid,
        .row_ready,
        .row_epoch,
        .row_context_tag({2'd0, row_slot_id}),
        .row_global_q_head,
        .row_index,
        .row_key_count({1'b0, row_index} + 1'b1),
        .row_max_bf16,
        .score_valid,
        .score_ready,
        .score_epoch,
        .score_context_tag({2'd0, score_slot_id}),
        .score_global_q_head,
        .score_row,
        .score_key,
        .score_bf16,
        .score_mask(1'b0),
        .score_last,
        .weight_valid,
        .weight_ready,
        .weight_epoch,
        .weight_context_tag(core_weight_context),
        .weight_global_q_head,
        .weight_row,
        .weight_key,
        .weight_bf16(core_weight_bf16),
        .weight_last,
        .done_valid,
        .done_ready,
        .done_epoch,
        .done_context_tag(core_done_context),
        .done_global_q_head,
        .done_row,
        .done_sum_q15(core_done_sum_q15),
        .done_reciprocal_q30(core_done_reciprocal_q30),
        .done_reciprocal_fp32(done_inv_sum_fp32),
        .done_error,
        .rows_issue,
        .rows_result,
        .rows_commit,
        .exp_issue,
        .exp_result,
        .exp_commit,
        .weight_issue(core_weight_issue),
        .weight_result(core_weight_result),
        .weight_commit(core_weight_commit),
        .sum_issue,
        .sum_result,
        .sum_commit,
        .reciprocal_issue,
        .reciprocal_result,
        .reciprocal_commit,
        .output_stall_cycles,
        .reciprocal_busy_stall_cycles,
        .protocol_error_count,
        .numeric_special_count,
        .protocol_error_sticky(error_sticky)
    );

    logic unused_input_metadata;
    logic unused_core_metadata;
    assign unused_input_metadata = |{row_group, row_numeric_mode,
                                     score_group, score_numeric_mode};
    assign unused_core_metadata = |{core_done_reciprocal_q30,
                                    core_weight_issue,
                                    core_weight_result,
                                    core_weight_commit};
endmodule
