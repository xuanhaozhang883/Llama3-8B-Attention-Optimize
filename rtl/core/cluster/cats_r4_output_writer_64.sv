`timescale 1ns/1ps

// CATS-R4 64-bit output writer candidate.
// Consumes the canonical serializer stream and exposes a simple write-data
// channel.  A beat is committed only after out_ready, so payload and all
// ordering metadata remain stable under backpressure.  The board DMA wrapper
// can replace this channel without changing PV/serializer ownership rules.
// Verification/integration candidate; not in scripts/source_manifest.tcl.
module cats_r4_output_writer_64 #(
    parameter int TOTAL_BEATS = 32*128*4*8
) (
    input logic clk, input logic rst_n, input logic clear,
    input logic start, input logic [31:0] base_addr,
    input logic in_valid, output logic in_ready,
    input logic [15:0] in_epoch, input logic [11:0] in_seq,
    input logic [4:0] in_global_q_head, input logic [6:0] in_row,
    input logic [1:0] in_feature_block, input logic [2:0] in_beat_in_chunk,
    input logic [63:0] in_data, input logic in_row_last, input logic in_tensor_last,
    output logic out_valid, input logic out_ready,
    output logic [31:0] out_addr, output logic [63:0] out_data,
    output logic out_row_last, output logic out_tensor_last,
    output logic busy, output logic done, output logic error,
    output logic [63:0] beats_accepted, output logic [63:0] rows_written,
    output logic [63:0] protocol_error_count
);
    localparam int COUNT_W = (TOTAL_BEATS <= 1) ? 1 : $clog2(TOTAL_BEATS+1);
    logic [COUNT_W-1:0] beat_count;
    logic [31:0] base_reg;
    logic [15:0] epoch_reg; logic [11:0] seq_reg;
    logic [4:0] head_reg; logic [6:0] row_reg; logic [1:0] block_reg;
    logic [2:0] beat_reg; logic row_last_reg, tensor_last_reg;
    logic [63:0] data_reg;
    logic out_fire, in_fire;

    assign in_ready = busy && !out_valid;
    assign in_fire = in_valid && in_ready;
    assign out_fire = out_valid && out_ready;
    assign out_addr = base_reg + (beat_count * 8);
    assign out_data = data_reg;
    assign out_row_last = row_last_reg;
    assign out_tensor_last = tensor_last_reg;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            busy<=0; done<=0; error<=0; beat_count<='0; base_reg<='0;
            out_valid<=0; data_reg<='0; epoch_reg<='0; seq_reg<='0;
            head_reg<='0; row_reg<='0; block_reg<='0; beat_reg<='0;
            row_last_reg<=0; tensor_last_reg<=0; beats_accepted<='0;
            rows_written<='0; protocol_error_count<='0;
        end else begin
            done<=0;
            if (start) begin
                busy<=1; done<=0; error<=0; beat_count<='0; base_reg<=base_addr;
                out_valid<=0; beats_accepted<='0; rows_written<='0;
                protocol_error_count<='0;
            end
            if (in_fire) begin
                epoch_reg<=in_epoch; seq_reg<=in_seq; head_reg<=in_global_q_head;
                row_reg<=in_row; block_reg<=in_feature_block; beat_reg<=in_beat_in_chunk;
                data_reg<=in_data; row_last_reg<=in_row_last; tensor_last_reg<=in_tensor_last;
                out_valid<=1; beats_accepted<=beats_accepted+1'b1;
                if (in_seq != (beat_count >> 5) || {in_global_q_head,in_row} != in_seq ||
                    in_feature_block != beat_count[4:3] || in_beat_in_chunk != beat_count[2:0] ||
                    in_row_last != ((in_feature_block==2'd3)&&(in_beat_in_chunk==3'd7)) ||
                    in_tensor_last != (beat_count == TOTAL_BEATS-1)) begin
                    error<=1; protocol_error_count<=protocol_error_count+1'b1;
                end
            end
            if (out_fire) begin
                out_valid<=0; beat_count<=beat_count+1'b1;
                if (beat_reg==3'd7 && block_reg==2'd3)
                    rows_written<=rows_written+1'b1;
                if (tensor_last_reg) begin
                    if (beat_count != TOTAL_BEATS-1) begin error<=1; protocol_error_count<=protocol_error_count+1'b1; end
                    busy<=0; done<=1;
                end
            end
        end
    end
endmodule