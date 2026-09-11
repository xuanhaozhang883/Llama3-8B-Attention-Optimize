`timescale 1ns/1ps

// B2/B3 positive-finite binary32 adder with one elastic output stage.
// The reduced domain is intentional: Accuracy weights and row/PV sums are
// non-negative finite values.  Any negative or non-finite operand is reported
// before a result can be committed.
module cats_r4_fp32_positive_add #(
    parameter int META_W = 44
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              clear,
    input  logic              counter_clear,

    input  logic              in_valid,
    output logic              in_ready,
    input  logic [31:0]       in_a_fp32,
    input  logic [31:0]       in_b_fp32,
    input  logic [META_W-1:0] in_meta,

    output logic              out_valid,
    input  logic              out_ready,
    output logic [31:0]       out_sum_fp32,
    output logic              out_numeric_error,
    output logic [META_W-1:0] out_meta,

    output logic [63:0]       add_issue,
    output logic [63:0]       add_result,
    output logic [63:0]       add_commit,
    output logic [63:0]       numeric_error_count,
    output logic [63:0]       output_stall_cycles
);
    logic computed_error;
    logic [31:0] computed_sum;
    logic out_valid_reg;
    logic [31:0] out_sum_reg;
    logic out_error_reg;
    logic [META_W-1:0] out_meta_reg;

    logic [7:0] exponent_a;
    logic [7:0] exponent_b;
    logic [7:0] effective_exponent_a;
    logic [7:0] effective_exponent_b;
    logic [23:0] significand_a;
    logic [23:0] significand_b;
    logic [7:0] larger_exponent;
    logic [7:0] smaller_exponent;
    logic [23:0] larger_significand;
    logic [23:0] smaller_significand;
    logic [7:0] exponent_difference;
    logic [26:0] aligned_larger;
    logic [26:0] aligned_smaller;
    logic [27:0] significand_sum;
    logic [26:0] normalized;
    logic [8:0] result_exponent;
    logic [24:0] rounded_significand;
    logic round_up;
    logic [7:0] encoded_exponent;

    function automatic logic [26:0] shift_right_jam(
        input logic [26:0] value,
        input logic [7:0] distance
    );
        logic [26:0] shifted;
        logic [26:0] discarded_mask;
        begin
            if (distance == 0) begin
                shift_right_jam = value;
            end else if (distance >= 27) begin
                shift_right_jam = {26'd0,|value};
            end else begin
                shifted = value >> distance;
                discarded_mask = (27'd1 << distance)-1'b1;
                shift_right_jam = shifted | {26'd0,|(value & discarded_mask)};
            end
        end
    endfunction

    always_comb begin
        exponent_a = in_a_fp32[30:23];
        exponent_b = in_b_fp32[30:23];
        effective_exponent_a = exponent_a == 0 ? 8'd1 : exponent_a;
        effective_exponent_b = exponent_b == 0 ? 8'd1 : exponent_b;
        significand_a = {exponent_a != 0,in_a_fp32[22:0]};
        significand_b = {exponent_b != 0,in_b_fp32[22:0]};

        if (effective_exponent_a >= effective_exponent_b) begin
            larger_exponent = effective_exponent_a;
            smaller_exponent = effective_exponent_b;
            larger_significand = significand_a;
            smaller_significand = significand_b;
        end else begin
            larger_exponent = effective_exponent_b;
            smaller_exponent = effective_exponent_a;
            larger_significand = significand_b;
            smaller_significand = significand_a;
        end

        exponent_difference = larger_exponent-smaller_exponent;
        aligned_larger = {larger_significand,3'b000};
        aligned_smaller = shift_right_jam(
            {smaller_significand,3'b000},exponent_difference
        );
        significand_sum = {1'b0,aligned_larger}+{1'b0,aligned_smaller};
        result_exponent = {1'b0,larger_exponent};
        if (significand_sum[27]) begin
            normalized = {significand_sum[27:2],
                          significand_sum[1] | significand_sum[0]};
            result_exponent = result_exponent+1'b1;
        end else begin
            normalized = significand_sum[26:0];
        end

        rounded_significand = {1'b0,normalized[26:3]};
        round_up = normalized[2] &&
                   (normalized[1] || normalized[0] || normalized[3]);
        if (round_up)
            rounded_significand = rounded_significand+1'b1;
        if (rounded_significand[24]) begin
            rounded_significand = rounded_significand >> 1;
            result_exponent = result_exponent+1'b1;
        end

        if ((result_exponent == 1) && !rounded_significand[23])
            encoded_exponent = 0;
        else
            encoded_exponent = result_exponent[7:0];

        computed_error = in_a_fp32[31] || in_b_fp32[31] ||
                         (exponent_a == 8'hff) ||
                         (exponent_b == 8'hff) ||
                         (result_exponent >= 255);
        if (computed_error)
            computed_sum = 0;
        else
            computed_sum = {1'b0,encoded_exponent,
                            rounded_significand[22:0]};
    end

    assign in_ready = !clear && (!out_valid_reg || out_ready);
    assign out_valid = out_valid_reg;
    assign out_sum_fp32 = out_sum_reg;
    assign out_numeric_error = out_error_reg;
    assign out_meta = out_meta_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_reg <= 1'b0;
            out_sum_reg <= 0;
            out_error_reg <= 1'b0;
            out_meta_reg <= 0;
            add_issue <= 0;
            add_result <= 0;
            add_commit <= 0;
            numeric_error_count <= 0;
            output_stall_cycles <= 0;
        end else begin
            if (clear) begin
                out_valid_reg <= 1'b0;
                out_sum_reg <= 0;
                out_error_reg <= 1'b0;
                out_meta_reg <= 0;
            end else if (in_ready) begin
                out_valid_reg <= in_valid;
                if (in_valid) begin
                    out_sum_reg <= computed_sum;
                    out_error_reg <= computed_error;
                    out_meta_reg <= in_meta;
                end
            end

            if (counter_clear) begin
                add_issue <= 0;
                add_result <= 0;
                add_commit <= 0;
                numeric_error_count <= 0;
                output_stall_cycles <= 0;
            end else if (!clear) begin
                if (in_valid && in_ready) begin
                    add_issue <= add_issue+1'b1;
                    add_result <= add_result+1'b1;
                end
                if (out_valid_reg && out_ready) begin
                    add_commit <= add_commit+1'b1;
                    // Count the registered error token at commit, rather
                    // than feeding the wide combinational FP32 classifier
                    // into a counter CE in the input cycle.
                    if (out_error_reg)
                        numeric_error_count <= numeric_error_count+1'b1;
                end
                if (out_valid_reg && !out_ready)
                    output_stall_cycles <= output_stall_cycles+1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic [31:0] stalled_sum;
    logic stalled_error;
    logic [META_W-1:0] stalled_meta;
    logic was_stalled;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            stalled_sum <= 0;
            stalled_error <= 0;
            stalled_meta <= 0;
            was_stalled <= 1'b0;
        end else begin
            if (was_stalled && (!out_valid_reg || out_sum_reg != stalled_sum ||
                out_error_reg != stalled_error || out_meta_reg != stalled_meta))
                $fatal(1, "positive FP32 add output changed while stalled");
            was_stalled <= out_valid_reg && !out_ready;
            stalled_sum <= out_sum_reg;
            stalled_error <= out_error_reg;
            stalled_meta <= out_meta_reg;
        end
    end
`endif

    initial begin
        if (META_W <= 0)
            $error("cats_r4_fp32_positive_add requires META_W>0");
    end
endmodule
