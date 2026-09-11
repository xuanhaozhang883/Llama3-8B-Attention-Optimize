`timescale 1ns/1ps

// B2 Accuracy exp candidate.
//
// The datapath is the bit-exact RTL counterpart of
// python/cats_r4_b2_accuracy_fixed_model.py:
//   finite BF16 max/score -> saturated Q16 gap
//   Q16 multiply by log2(e)
//   33-entry Q31 exp2(-fraction) LUT with linear interpolation
//   exponent shift and IEEE binary32 RNE encoding
//
// This is a standalone B-owned checkpoint, not a public/system top.  Its
// one-entry elastic output preserves payload and metadata under backpressure.
module cats_r4_accuracy_exp_fixed #(
    parameter int META_W = 44
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              clear,
    input  logic              counter_clear,

    input  logic              in_valid,
    output logic              in_ready,
    input  logic [15:0]       in_row_max_bf16,
    input  logic [15:0]       in_score_bf16,
    input  logic [META_W-1:0] in_meta,

    output logic              out_valid,
    input  logic              out_ready,
    output logic [31:0]       out_weight_fp32,
    output logic              out_numeric_error,
    output logic [META_W-1:0] out_meta,

    output logic [63:0]       exp_issue,
    output logic [63:0]       exp_result,
    output logic [63:0]       exp_commit,
    output logic [63:0]       numeric_error_count,
    output logic [63:0]       output_stall_cycles
);
    localparam logic [22:0] MAX_GAP_Q16 = 23'd6815744;
    localparam logic [16:0] LOG2_E_Q16 = 17'd94548;

    // Four elastic stages keep the BF16 decode/range reduction, LUT
    // interpolation and FP32 packing off the same 150 MHz timing arc.  The
    // arithmetic boundary is unchanged; only its registered schedule changes.
    logic stage0_valid;
    logic [15:0] stage0_max_bf16, stage0_score_bf16;
    logic [META_W-1:0] stage0_meta;
    logic decode_valid, decode_both_zero, decode_score_greater, decode_inputs_equal;
    logic [7:0] decode_max_exponent, decode_score_exponent;
    logic signed [31:0] decode_maximum_q16, decode_score_q16;
    logic [META_W-1:0] decode_meta;
    logic stage1_valid, stage1_error;
    logic [7:0] stage1_binary_exponent;
    logic [15:0] stage1_binary_fraction;
    logic [META_W-1:0] stage1_meta;
    logic stage2_valid, stage2_error;
    logic [7:0] stage2_binary_exponent;
    logic [31:0] stage2_interpolated_q31;
    logic [META_W-1:0] stage2_meta;
    logic stage0_ready, decode_ready, stage1_ready, stage2_ready;
    logic decode_both_zero_comb, decode_score_greater_comb, decode_inputs_equal_comb;
    logic [7:0] decode_max_exponent_comb, decode_score_exponent_comb;
    logic signed [31:0] decode_maximum_q16_comb, decode_score_q16_comb;
    logic stage1_error_comb;
    logic [7:0] stage1_binary_exponent_comb;
    logic [15:0] stage1_binary_fraction_comb;
    logic stage2_error_comb;
    logic [7:0] stage2_binary_exponent_comb;
    logic [31:0] stage2_interpolated_q31_comb;
    logic [31:0] computed_weight;
    logic out_valid_reg;
    logic [31:0] out_weight_reg;
    logic out_error_reg;
    logic [META_W-1:0] out_meta_reg;

    logic [7:0] max_exponent;
    logic [7:0] score_exponent;
    logic both_zero;
    logic score_greater;
    logic signed [31:0] maximum_q16;
    logic signed [31:0] score_q16;
    logic signed [32:0] gap_wide;
    logic [22:0] gap_q16;
    logic [39:0] scaled_product;
    logic [23:0] scaled_quotient;
    logic scaled_round_up;
    logic [23:0] scaled_q16;
    logic [7:0] binary_exponent;
    logic [15:0] binary_fraction;
    logic [4:0] lut_index;
    logic [10:0] local_q11;
    logic [31:0] lut_lower;
    logic [31:0] lut_upper;
    logic [31:0] lut_difference;
    logic [42:0] interpolation_product;
    logic [31:0] interpolation_quotient;
    logic interpolation_round_up;
    logic [31:0] interpolation_decrement;
    logic [31:0] interpolated_q31;

    function automatic logic [15:0] bf16_ordered_key(
        input logic [15:0] value
    );
        begin
            bf16_ordered_key = value[15] ? ~value : (value ^ 16'h8000);
        end
    endfunction

    function automatic logic signed [31:0] bf16_to_q16(
        input logic [15:0] value
    );
        logic [7:0] exponent;
        logic [7:0] significand;
        logic [31:0] magnitude;
        logic [31:0] quotient;
        logic [31:0] remainder;
        logic [31:0] halfway;
        integer shift;
        begin
            exponent = value[14:7];
            significand = {1'b1,value[6:0]};
            magnitude = 0;
            quotient = 0;
            remainder = 0;
            halfway = 0;
            shift = 0;
            if (exponent == 0) begin
                magnitude = 0;
            end else if (exponent >= 118) begin
                magnitude = {24'd0,significand} << (exponent-118);
            end else begin
                shift = 118-exponent;
                if (shift <= 8) begin
                    quotient = significand >> shift;
                    remainder = significand & ((32'd1 << shift)-1'b1);
                    halfway = 32'd1 << (shift-1);
                    if ((remainder > halfway) ||
                        ((remainder == halfway) && quotient[0]))
                        quotient = quotient + 1'b1;
                    magnitude = quotient;
                end
            end
            bf16_to_q16 = value[15] ? -$signed(magnitude) :
                                               $signed(magnitude);
        end
    endfunction

    function automatic logic [31:0] exp2_lut_q31(
        input logic [5:0] address
    );
        begin
            case (address)
                6'd0: exp2_lut_q31 = 32'h80000000;
                6'd1: exp2_lut_q31 = 32'h7D41D980;
                6'd2: exp2_lut_q31 = 32'h7A92BE80;
                6'd3: exp2_lut_q31 = 32'h77F25D00;
                6'd4: exp2_lut_q31 = 32'h75606380;
                6'd5: exp2_lut_q31 = 32'h72DC8380;
                6'd6: exp2_lut_q31 = 32'h70666F80;
                6'd7: exp2_lut_q31 = 32'h6DFDDC00;
                6'd8: exp2_lut_q31 = 32'h6BA27E80;
                6'd9: exp2_lut_q31 = 32'h69540F00;
                6'd10: exp2_lut_q31 = 32'h67124600;
                6'd11: exp2_lut_q31 = 32'h64DCDF00;
                6'd12: exp2_lut_q31 = 32'h62B39500;
                6'd13: exp2_lut_q31 = 32'h60962680;
                6'd14: exp2_lut_q31 = 32'h5E845200;
                6'd15: exp2_lut_q31 = 32'h5C7DD780;
                6'd16: exp2_lut_q31 = 32'h5A827980;
                6'd17: exp2_lut_q31 = 32'h5891FB00;
                6'd18: exp2_lut_q31 = 32'h56AC1F80;
                6'd19: exp2_lut_q31 = 32'h54D0AD80;
                6'd20: exp2_lut_q31 = 32'h52FF6B80;
                6'd21: exp2_lut_q31 = 32'h51382180;
                6'd22: exp2_lut_q31 = 32'h4F7A9900;
                6'd23: exp2_lut_q31 = 32'h4DC69D00;
                6'd24: exp2_lut_q31 = 32'h4C1BF800;
                6'd25: exp2_lut_q31 = 32'h4A7A7800;
                6'd26: exp2_lut_q31 = 32'h48E1E980;
                6'd27: exp2_lut_q31 = 32'h47521D00;
                6'd28: exp2_lut_q31 = 32'h45CAE100;
                6'd29: exp2_lut_q31 = 32'h444C0780;
                6'd30: exp2_lut_q31 = 32'h42D56180;
                6'd31: exp2_lut_q31 = 32'h4166C380;
                6'd32: exp2_lut_q31 = 32'h40000000;
                default: exp2_lut_q31 = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] q31_scaled_to_fp32(
        input logic [31:0] interpolated,
        input logic [7:0] exponent
    );
        integer msb_index;
        integer unbiased_exponent;
        integer shift_right;
        integer biased_exponent;
        logic [31:0] quotient;
        logic [31:0] remainder;
        logic [31:0] halfway;
        logic [32:0] rounded;
        begin
            q31_scaled_to_fp32 = 0;
            quotient = 0;
            remainder = 0;
            halfway = 0;
            rounded = 0;
            if (interpolated != 0) begin
                msb_index = interpolated[31] ? 31 : 30;
                unbiased_exponent = msb_index-31-exponent;
                if (unbiased_exponent >= -126) begin
                    shift_right = msb_index-23;
                    quotient = interpolated >> shift_right;
                    remainder = interpolated &
                                ((32'd1 << shift_right)-1'b1);
                    halfway = 32'd1 << (shift_right-1);
                    rounded = {1'b0,quotient};
                    if ((remainder > halfway) ||
                        ((remainder == halfway) && quotient[0]))
                        rounded = rounded + 1'b1;
                    if (rounded[24]) begin
                        rounded = rounded >> 1;
                        unbiased_exponent = unbiased_exponent + 1;
                    end
                    biased_exponent = unbiased_exponent + 127;
                    q31_scaled_to_fp32 = {
                        1'b0,biased_exponent[7:0],rounded[22:0]
                    };
                end else begin
                    shift_right = exponent-118;
                    quotient = interpolated >> shift_right;
                    remainder = interpolated &
                                ((32'd1 << shift_right)-1'b1);
                    halfway = 32'd1 << (shift_right-1);
                    rounded = {1'b0,quotient};
                    if ((remainder > halfway) ||
                        ((remainder == halfway) && quotient[0]))
                        rounded = rounded + 1'b1;
                    if (rounded >= 33'h000800000)
                        q31_scaled_to_fp32 = 32'h00800000;
                    else
                        q31_scaled_to_fp32 = {9'd0,rounded[22:0]};
                end
            end
        end
    endfunction

    always_comb begin
        max_exponent = stage0_max_bf16[14:7];
        score_exponent = stage0_score_bf16[14:7];
        both_zero = (stage0_max_bf16[14:0] == 0) &&
                    (stage0_score_bf16[14:0] == 0);
        score_greater = !both_zero &&
                         (bf16_ordered_key(stage0_score_bf16) >
                          bf16_ordered_key(stage0_max_bf16));
        maximum_q16 = bf16_to_q16(stage0_max_bf16);
        score_q16 = bf16_to_q16(stage0_score_bf16);
        decode_max_exponent_comb = max_exponent;
        decode_score_exponent_comb = score_exponent;
        decode_both_zero_comb = both_zero;
        decode_score_greater_comb = score_greater;
        decode_inputs_equal_comb = stage0_max_bf16 == stage0_score_bf16;
        decode_maximum_q16_comb = maximum_q16;
        decode_score_q16_comb = score_q16;
    end

    always_comb begin
        gap_wide = $signed(decode_maximum_q16)-$signed(decode_score_q16);
        stage1_error_comb = (decode_max_exponent == 8'hff) ||
                            (decode_score_exponent == 8'hff) ||
                            decode_score_greater;
        if (decode_inputs_equal || decode_both_zero)
            gap_q16 = 0;
        else if ((decode_max_exponent >= 141) || (decode_score_exponent >= 141) ||
                 (gap_wide >= $signed({1'b0,MAX_GAP_Q16})))
            gap_q16 = MAX_GAP_Q16;
        else if (gap_wide <= 0)
            gap_q16 = 0;
        else
            gap_q16 = gap_wide[22:0];

        scaled_product = gap_q16 * LOG2_E_Q16;
        scaled_quotient = scaled_product[39:16];
        scaled_round_up = (scaled_product[15:0] > 16'h8000) ||
                          ((scaled_product[15:0] == 16'h8000) &&
                           scaled_quotient[0]);
        scaled_q16 = scaled_quotient + scaled_round_up;
        binary_exponent = scaled_q16[23:16];
        binary_fraction = scaled_q16[15:0];
        stage1_binary_exponent_comb = binary_exponent;
        stage1_binary_fraction_comb = binary_fraction;
    end

    always_comb begin
        lut_index = stage1_binary_fraction[15:11];
        local_q11 = stage1_binary_fraction[10:0];
        lut_lower = exp2_lut_q31({1'b0,lut_index});
        lut_upper = exp2_lut_q31({1'b0,lut_index}+1'b1);
        lut_difference = lut_lower-lut_upper;
        interpolation_product = lut_difference*local_q11;
        interpolation_quotient = interpolation_product[42:11];
        interpolation_round_up =
            (interpolation_product[10:0] > 11'h400) ||
            ((interpolation_product[10:0] == 11'h400) &&
             interpolation_quotient[0]);
        interpolation_decrement = interpolation_quotient+
                                  interpolation_round_up;
        interpolated_q31 = lut_lower-interpolation_decrement;

        stage2_error_comb = stage1_error;
        stage2_binary_exponent_comb = stage1_binary_exponent;
        stage2_interpolated_q31_comb = interpolated_q31;
    end

    always_comb begin
        if (stage2_error || (stage2_binary_exponent >= 150))
            computed_weight = 0;
        else
            computed_weight = q31_scaled_to_fp32(
                stage2_interpolated_q31,stage2_binary_exponent
            );
    end

    assign stage2_ready = !out_valid_reg || out_ready;
    assign stage1_ready = !stage2_valid || stage2_ready;
    assign decode_ready = !stage1_valid || stage1_ready;
    assign stage0_ready = !decode_valid || decode_ready;
    assign in_ready = !clear && (!stage0_valid || stage0_ready);
    assign out_valid = out_valid_reg;
    assign out_weight_fp32 = out_weight_reg;
    assign out_numeric_error = out_error_reg;
    assign out_meta = out_meta_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage0_valid <= 1'b0;
            decode_valid <= 1'b0;
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;
            stage0_max_bf16 <= 0;
            stage0_score_bf16 <= 0;
            stage0_meta <= 0;
            decode_both_zero <= 1'b0;
            decode_score_greater <= 1'b0;
            decode_inputs_equal <= 1'b0;
            decode_max_exponent <= 0;
            decode_score_exponent <= 0;
            decode_maximum_q16 <= 0;
            decode_score_q16 <= 0;
            decode_meta <= 0;
            stage1_error <= 1'b0;
            stage1_binary_exponent <= 0;
            stage1_binary_fraction <= 0;
            stage1_meta <= 0;
            stage2_error <= 1'b0;
            stage2_binary_exponent <= 0;
            stage2_interpolated_q31 <= 0;
            stage2_meta <= 0;
            out_valid_reg <= 1'b0;
            out_weight_reg <= 0;
            out_error_reg <= 1'b0;
            out_meta_reg <= 0;
            exp_issue <= 0;
            exp_result <= 0;
            exp_commit <= 0;
            numeric_error_count <= 0;
            output_stall_cycles <= 0;
        end else begin
            if (clear) begin
                stage0_valid <= 1'b0;
                decode_valid <= 1'b0;
                stage1_valid <= 1'b0;
                stage2_valid <= 1'b0;
                out_valid_reg <= 1'b0;
                out_weight_reg <= 0;
                out_error_reg <= 1'b0;
                out_meta_reg <= 0;
            end else begin
                if (stage2_ready) begin
                    out_valid_reg <= stage2_valid;
                    if (stage2_valid) begin
                        out_weight_reg <= computed_weight;
                        out_error_reg <= stage2_error;
                        out_meta_reg <= stage2_meta;
                    end
                end
                if (stage1_ready) begin
                    stage2_valid <= stage1_valid;
                    if (stage1_valid) begin
                        stage2_error <= stage2_error_comb;
                        stage2_binary_exponent <= stage2_binary_exponent_comb;
                        stage2_interpolated_q31 <= stage2_interpolated_q31_comb;
                        stage2_meta <= stage1_meta;
                    end
                end
                if (decode_ready) begin
                    stage1_valid <= decode_valid;
                    if (decode_valid) begin
                        stage1_error <= stage1_error_comb;
                        stage1_binary_exponent <= stage1_binary_exponent_comb;
                        stage1_binary_fraction <= stage1_binary_fraction_comb;
                        stage1_meta <= decode_meta;
                    end
                end
                if (stage0_ready) begin
                    decode_valid <= stage0_valid;
                    if (stage0_valid) begin
                        decode_both_zero <= decode_both_zero_comb;
                        decode_score_greater <= decode_score_greater_comb;
                        decode_inputs_equal <= decode_inputs_equal_comb;
                        decode_max_exponent <= decode_max_exponent_comb;
                        decode_score_exponent <= decode_score_exponent_comb;
                        decode_maximum_q16 <= decode_maximum_q16_comb;
                        decode_score_q16 <= decode_score_q16_comb;
                        decode_meta <= stage0_meta;
                    end
                end
                if (in_ready) begin
                    stage0_valid <= in_valid;
                    if (in_valid) begin
                        stage0_max_bf16 <= in_row_max_bf16;
                        stage0_score_bf16 <= in_score_bf16;
                        stage0_meta <= in_meta;
                    end
                end
            end

            if (counter_clear) begin
                exp_issue <= 0;
                exp_result <= 0;
                exp_commit <= 0;
                numeric_error_count <= 0;
                output_stall_cycles <= 0;
            end else if (!clear) begin
                if (in_valid && in_ready)
                    exp_issue <= exp_issue + 1'b1;
                if (stage2_valid && stage2_ready) begin
                    exp_result <= exp_result + 1'b1;
                    if (stage2_error)
                        numeric_error_count <= numeric_error_count + 1'b1;
                end
                if (out_valid_reg && out_ready)
                    exp_commit <= exp_commit + 1'b1;
                if (out_valid_reg && !out_ready)
                    output_stall_cycles <= output_stall_cycles + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic [31:0] stalled_weight;
    logic stalled_error;
    logic [META_W-1:0] stalled_meta;
    logic was_stalled;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            stalled_weight <= 0;
            stalled_error <= 0;
            stalled_meta <= 0;
            was_stalled <= 1'b0;
        end else begin
            if (was_stalled && (!out_valid_reg ||
                out_weight_reg != stalled_weight ||
                out_error_reg != stalled_error || out_meta_reg != stalled_meta))
                $fatal(1, "Accuracy exp output changed while stalled");
            was_stalled <= out_valid_reg && !out_ready;
            stalled_weight <= out_weight_reg;
            stalled_error <= out_error_reg;
            stalled_meta <= out_meta_reg;
            if (stage2_valid && stage2_ready && !stage2_error &&
                stage2_interpolated_q31 < 32'h40000000)
                $fatal(1, "Accuracy exp interpolation escaped [0.5,1]");
        end
    end
`endif

    initial begin
        if (META_W <= 0)
            $error("cats_r4_accuracy_exp_fixed requires META_W>0");
    end
endmodule
