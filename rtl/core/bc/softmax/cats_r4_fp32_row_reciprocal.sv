`timescale 1ns/1ps

// B2 Accuracy reciprocal for the proven row-sum domain 1.0 <= sum <= 128.0.
// It divides 2^47 by the input significand, rounds the quotient to nearest
// even, and reconstructs binary32.  The iterative divider has fixed 48-cycle
// work and completes before the next 128-score row at exp/sum II=1.
module cats_r4_fp32_row_reciprocal #(
    parameter int META_W = 44
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              clear,
    input  logic              counter_clear,

    input  logic              in_valid,
    output logic              in_ready,
    input  logic [31:0]       in_sum_fp32,
    input  logic [META_W-1:0] in_meta,

    output logic              out_valid,
    input  logic              out_ready,
    output logic [31:0]       out_inv_sum_fp32,
    output logic              out_numeric_error,
    output logic [META_W-1:0] out_meta,

    output logic [63:0]       reciprocal_issue,
    output logic [63:0]       reciprocal_result,
    output logic [63:0]       reciprocal_commit,
    output logic [63:0]       numeric_error_count,
    output logic [63:0]       busy_stall_cycles,
    output logic [63:0]       output_stall_cycles
);
    logic input_legal;
    logic divider_start;
    logic divider_busy;
    logic divider_done;
    logic divider_by_zero;
    logic [47:0] divider_quotient;
    logic [23:0] divider_remainder;

    logic operation_pending;
    logic [7:0] pending_exponent;
    logic [23:0] pending_significand;
    logic [META_W-1:0] pending_meta;
    logic out_valid_reg;
    logic [31:0] out_inv_sum_reg;
    logic out_error_reg;
    logic [META_W-1:0] out_meta_reg;

    logic [48:0] rounded_quotient;
    logic quotient_round_up;
    logic [24:0] reciprocal_significand;
    logic [8:0] reciprocal_exponent;
    logic [31:0] divider_result_fp32;

    assign input_legal = !in_sum_fp32[31] &&
                         in_sum_fp32[30:23] != 8'h00 &&
                         in_sum_fp32[30:23] != 8'hff &&
                         in_sum_fp32 >= 32'h3f800000 &&
                         in_sum_fp32 <= 32'h43000000;
    assign in_ready = !clear && !divider_busy && !operation_pending &&
                      !out_valid_reg;
    assign divider_start = in_valid && in_ready && input_legal;

    unsigned_restoring_divider #(
        .NUM_W(48),
        .DEN_W(24)
    ) u_divider (
        .clk,
        .rst_n(rst_n && !clear),
        .start(divider_start),
        .numerator(48'h800000000000),
        .denominator({1'b1,in_sum_fp32[22:0]}),
        .busy(divider_busy),
        .done(divider_done),
        .divide_by_zero(divider_by_zero),
        .quotient(divider_quotient),
        .remainder(divider_remainder)
    );

    always_comb begin
        quotient_round_up =
            ({divider_remainder,1'b0} > {1'b0,pending_significand}) ||
            (({divider_remainder,1'b0} == {1'b0,pending_significand}) &&
             divider_quotient[0]);
        rounded_quotient = {1'b0,divider_quotient}+quotient_round_up;
        reciprocal_significand = rounded_quotient[24:0];
        reciprocal_exponent = 9'd253-{1'b0,pending_exponent};
        if (rounded_quotient[24]) begin
            reciprocal_significand = {1'b0,rounded_quotient[24:1]};
            reciprocal_exponent = reciprocal_exponent+1'b1;
        end
        divider_result_fp32 = {
            1'b0,reciprocal_exponent[7:0],reciprocal_significand[22:0]
        };
    end

    assign out_valid = out_valid_reg;
    assign out_inv_sum_fp32 = out_inv_sum_reg;
    assign out_numeric_error = out_error_reg;
    assign out_meta = out_meta_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            operation_pending <= 1'b0;
            pending_exponent <= 0;
            pending_significand <= 0;
            pending_meta <= 0;
            out_valid_reg <= 1'b0;
            out_inv_sum_reg <= 0;
            out_error_reg <= 1'b0;
            out_meta_reg <= 0;
            reciprocal_issue <= 0;
            reciprocal_result <= 0;
            reciprocal_commit <= 0;
            numeric_error_count <= 0;
            busy_stall_cycles <= 0;
            output_stall_cycles <= 0;
        end else begin
            if (clear) begin
                operation_pending <= 1'b0;
                pending_exponent <= 0;
                pending_significand <= 0;
                pending_meta <= 0;
                out_valid_reg <= 1'b0;
                out_inv_sum_reg <= 0;
                out_error_reg <= 1'b0;
                out_meta_reg <= 0;
            end else begin
                if (out_valid_reg && out_ready)
                    out_valid_reg <= 1'b0;

                if (in_valid && in_ready) begin
                    if (input_legal) begin
                        operation_pending <= 1'b1;
                        pending_exponent <= in_sum_fp32[30:23];
                        pending_significand <= {1'b1,in_sum_fp32[22:0]};
                        pending_meta <= in_meta;
                    end else begin
                        out_valid_reg <= 1'b1;
                        out_inv_sum_reg <= 0;
                        out_error_reg <= 1'b1;
                        out_meta_reg <= in_meta;
                    end
                end

                if (divider_done && operation_pending) begin
                    operation_pending <= 1'b0;
                    out_valid_reg <= 1'b1;
                    out_inv_sum_reg <=
                        divider_by_zero ? 32'd0 : divider_result_fp32;
                    out_error_reg <= divider_by_zero;
                    out_meta_reg <= pending_meta;
                end
            end

            if (counter_clear) begin
                reciprocal_issue <= 0;
                reciprocal_result <= 0;
                reciprocal_commit <= 0;
                numeric_error_count <= 0;
                busy_stall_cycles <= 0;
                output_stall_cycles <= 0;
            end else if (!clear) begin
                if (in_valid && in_ready) begin
                    reciprocal_issue <= reciprocal_issue+1'b1;
                    if (!input_legal) begin
                        reciprocal_result <= reciprocal_result+1'b1;
                        numeric_error_count <= numeric_error_count+1'b1;
                    end
                end
                if (divider_done && operation_pending) begin
                    reciprocal_result <= reciprocal_result+1'b1;
                    if (divider_by_zero)
                        numeric_error_count <= numeric_error_count+1'b1;
                end
                if (out_valid_reg && out_ready)
                    reciprocal_commit <= reciprocal_commit+1'b1;
                if (in_valid && !in_ready)
                    busy_stall_cycles <= busy_stall_cycles+1'b1;
                if (out_valid_reg && !out_ready)
                    output_stall_cycles <= output_stall_cycles+1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic [31:0] stalled_result;
    logic stalled_error;
    logic [META_W-1:0] stalled_meta;
    logic was_stalled;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            stalled_result <= 0;
            stalled_error <= 0;
            stalled_meta <= 0;
            was_stalled <= 1'b0;
        end else begin
            if (was_stalled && (!out_valid_reg ||
                out_inv_sum_reg != stalled_result ||
                out_error_reg != stalled_error || out_meta_reg != stalled_meta))
                $fatal(1, "FP32 reciprocal output changed while stalled");
            was_stalled <= out_valid_reg && !out_ready;
            stalled_result <= out_inv_sum_reg;
            stalled_error <= out_error_reg;
            stalled_meta <= out_meta_reg;
        end
    end
`endif

    initial begin
        if (META_W <= 0)
            $error("cats_r4_fp32_row_reciprocal requires META_W>0");
    end
endmodule
