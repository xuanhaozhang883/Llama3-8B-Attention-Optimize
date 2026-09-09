`timescale 1ns/1ps

// Formatter checkpoint uses SCALE_FP32=1.0 so the mock multiplier can verify
// transport, lane masking, RNE BF16 conversion, and output backpressure.
module fp32_mul_ip #(
    parameter IP_ID = 0
) (
    input logic clk, input logic rst_n,
    input logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result_data <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                if (b_data !== 32'h3f800000)
                    $fatal(1, "formatter mock expects identity scale");
                result_data <= a_data;
                result_valid <= 1'b1;
            end
        end
    end
endmodule

module tb_cats_r4_qk_score_formatter;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic in_valid, in_ready;
    logic [15:0] in_epoch;
    logic [2:0] in_group;
    logic [4:0] in_global_q_head;
    logic [6:0] in_row;
    logic [1:0] in_key_block;
    logic [3:0] in_context_tag;
    logic [3:0] in_lane_valid;
    logic [127:0] in_raw_fp32;
    logic out_valid, out_ready;
    logic [15:0] out_epoch;
    logic [2:0] out_group;
    logic [4:0] out_global_q_head;
    logic [6:0] out_row;
    logic [1:0] out_key_block;
    logic [3:0] out_context_tag;
    logic [3:0] out_lane_valid;
    logic [127:0] out_scaled_fp32;
    logic [63:0] out_score_bf16;
    logic [63:0] scale_requests_accepted, scale_products_completed;
    logic [63:0] score_format_transfers, protocol_errors;
    logic protocol_error_sticky;

    cats_r4_qk_score_formatter #(.LANES(4), .SCALE_FP32(32'h3f800000)) dut (.*);

    task automatic tick; @(posedge clk); #1; endtask

    initial begin
        in_valid = 0;
        in_epoch = 16'h1234;
        in_group = 3'd2;
        in_global_q_head = 5'd9;
        in_row = 7'd7;
        in_key_block = 2'd1;
        in_context_tag = 4'd5;
        in_lane_valid = 4'b1011;
        in_raw_fp32 = {32'h7fc00000, 32'h3f800000, 32'h40000000, 32'h41000000};
        out_ready = 0;
        repeat (3) tick();
        rst_n = 1;
        while (!in_ready) tick();
        @(negedge clk); in_valid = 1;
        @(negedge clk); in_valid = 0;
        if (scale_requests_accepted !== 1)
            $fatal(1, "request counter mismatch");
        while (!out_valid) tick();
        if (out_epoch !== in_epoch || out_group !== in_group ||
            out_global_q_head !== in_global_q_head || out_row !== in_row ||
            out_key_block !== in_key_block || out_context_tag !== in_context_tag)
            $fatal(1, "formatter tag mismatch");
        if (out_lane_valid !== 4'b1011)
            $fatal(1, "formatter lane mask mismatch");
        if (scale_products_completed !== 3 || protocol_errors !== 0 ||
            protocol_error_sticky)
            $fatal(1, "formatter counters/errors mismatch");
        if (out_scaled_fp32[31:0] !== 32'h41000000 ||
            out_scaled_fp32[63:32] !== 32'h40000000 ||
            out_scaled_fp32[95:64] !== 32'h00000000)
            $fatal(1, "scaled FP32 mismatch");
        // 64.0, 2.0, and 1.0 after identity scale; lane 2 is masked.
        if (out_score_bf16[15:0] !== 16'h4100 ||
            out_score_bf16[31:16] !== 16'h4000 ||
            out_score_bf16[47:32] !== 16'h0000 ||
            out_score_bf16[63:48] !== 16'h7fc0)
            $fatal(1, "BF16 conversion/mask mismatch: %h", out_score_bf16);
        tick();
        if (out_valid !== 1'b1)
            $fatal(1, "output did not remain stable under backpressure");
        out_ready = 1;
        tick();
        if (score_format_transfers !== 1 || out_valid)
            $fatal(1, "output transfer mismatch");
        counter_clear=1;tick();counter_clear=0;
        if(scale_requests_accepted!=0||scale_products_completed!=0||
           score_format_transfers!=0||protocol_errors!=0||protocol_error_sticky)
            $fatal(1,"counter_clear did not clear formatter observability state");
        $display("PASS: CATS-R4 score scale/BF16 formatter tags, mask, counters, and backpressure");
        $finish;
    end
endmodule
