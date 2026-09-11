`timescale 1ns/1ps

// Row-end 32-lane normalization: FP32 numerator * FP32 inv_sum, followed by
// one BF16 round-to-nearest-even conversion per lane.
module cats_r4_b3_pv_normalize_32lane #(
    parameter int LANES = 32,
    parameter int META_DEPTH = 16
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,
    input  logic          norm_valid,
    output logic          norm_ready,
    input  logic [3:0]    norm_context_tag,
    input  logic [1023:0] norm_numerator_fp32,
    input  logic [31:0]   norm_inv_sum_fp32,
    output logic          norm_rsp_valid,
    input  logic          norm_rsp_ready,
    output logic [3:0]    norm_rsp_context_tag,
    output logic [511:0]  norm_rsp_context_bf16,
    output logic [63:0]   normalize_issue_count,
    output logic [63:0]   normalize_result_count,
    output logic [63:0]   output_stall_cycles,
    output logic [63:0]   numeric_error_count,
    output logic          error_sticky
);
    localparam int PTR_W = $clog2(META_DEPTH);

    logic [3:0] meta_context [0:META_DEPTH-1];
    logic [PTR_W-1:0] meta_wr_ptr, meta_rd_ptr;
    logic [PTR_W:0] meta_count;
    logic [LANES-1:0] mul_a_ready, mul_b_ready;
    logic [LANES-1:0] mul_result_valid, mul_result_ready;
    logic [LANES*32-1:0] mul_result_data;
    logic [LANES*16-1:0] rounded_bf16;
    logic all_input_ready, all_result_valid;
    logic input_fire, result_fire, output_room;
    logic result_numeric_error;
    logic arithmetic_rst_n;
    integer seq_lane;

    assign all_input_ready = &mul_a_ready && &mul_b_ready;
    // Keep the FP pipeline and its metadata in the same clear/reset domain.
    // Otherwise a result launched before clear could be retagged afterward.
    assign arithmetic_rst_n = rst_n && !clear;
    assign norm_ready = all_input_ready && meta_count < META_DEPTH &&
                        !error_sticky;
    assign input_fire = norm_valid && norm_ready;
    assign all_result_valid = &mul_result_valid;
    assign output_room = !norm_rsp_valid || norm_rsp_ready;
    assign result_fire = meta_count != 0 && all_result_valid && output_room;

    always_comb begin
        result_numeric_error = 1'b0;
        for (seq_lane = 0; seq_lane < LANES; seq_lane = seq_lane + 1)
            if (mul_result_data[seq_lane*32 + 23 +: 8] == 8'hff)
                result_numeric_error = 1'b1;
    end

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : GEN_NORM_LANE
            fp32_mul_ip #(.IP_ID(2)) u_mul (
                .clk(clk), .rst_n(arithmetic_rst_n),
                .a_valid(norm_valid && norm_ready),
                .a_ready(mul_a_ready[lane]),
                .a_data(norm_numerator_fp32[lane*32 +: 32]),
                .b_valid(norm_valid && norm_ready),
                .b_ready(mul_b_ready[lane]),
                .b_data(norm_inv_sum_fp32),
                .result_valid(mul_result_valid[lane]),
                .result_ready(mul_result_ready[lane]),
                .result_data(mul_result_data[lane*32 +: 32])
            );
            assign mul_result_ready[lane] = meta_count == 0 ? 1'b1 :
                                            result_fire;
            fp32_to_bf16 u_round (
                .fp32_in(mul_result_data[lane*32 +: 32]),
                .bf16_out(rounded_bf16[lane*16 +: 16])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin : p_state
        if (!rst_n) begin
            meta_wr_ptr <= '0;
            meta_rd_ptr <= '0;
            meta_count <= '0;
            norm_rsp_valid <= 1'b0;
            norm_rsp_context_tag <= '0;
            norm_rsp_context_bf16 <= '0;
        end else if (clear) begin
            meta_wr_ptr <= '0;
            meta_rd_ptr <= '0;
            meta_count <= '0;
            norm_rsp_valid <= 1'b0;
        end else begin
            if (norm_rsp_valid && norm_rsp_ready)
                norm_rsp_valid <= 1'b0;
            if (input_fire) begin
                meta_wr_ptr <= meta_wr_ptr + 1'b1;
            end
            if (result_fire) begin
                norm_rsp_valid <= 1'b1;
                norm_rsp_context_tag <= meta_context[meta_rd_ptr];
                norm_rsp_context_bf16 <= rounded_bf16;
                meta_rd_ptr <= meta_rd_ptr + 1'b1;
            end
            case ({input_fire,result_fire})
                2'b10: meta_count <= meta_count + 1'b1;
                2'b01: meta_count <= meta_count - 1'b1;
                default: meta_count <= meta_count;
            endcase
        end
    end

    // Pointer validity, not payload reset values, owns this FIFO.
    always_ff @(posedge clk) begin : p_metadata_storage
        if (rst_n && !clear && input_fire)
            meta_context[meta_wr_ptr] <= norm_context_tag;
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_counters
        if (!rst_n) begin
            normalize_issue_count <= '0;
            normalize_result_count <= '0;
            output_stall_cycles <= '0;
            numeric_error_count <= '0;
            error_sticky <= 1'b0;
        end else if (clear || counter_clear) begin
            normalize_issue_count <= '0;
            normalize_result_count <= '0;
            output_stall_cycles <= '0;
            numeric_error_count <= '0;
            error_sticky <= 1'b0;
        end else begin
            if (input_fire)
                normalize_issue_count <= normalize_issue_count + 1'b1;
            if (result_fire) begin
                normalize_result_count <= normalize_result_count + 1'b1;
                if (result_numeric_error) begin
                    numeric_error_count <= numeric_error_count + 1'b1;
                    error_sticky <= 1'b1;
                end
            end
            if (norm_rsp_valid && !norm_rsp_ready)
                output_stall_cycles <= output_stall_cycles + 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !clear) begin
            if (meta_count > META_DEPTH)
                $fatal(1, "B3 normalize metadata FIFO overflow");
            if (result_fire && !all_result_valid)
                $fatal(1, "B3 normalize lanes lost alignment");
        end
    end
`endif

    initial begin
        if (LANES != 32 || META_DEPTH < 4)
            $error("B3 normalize requires 32 lanes and metadata depth >=4");
    end
endmodule
