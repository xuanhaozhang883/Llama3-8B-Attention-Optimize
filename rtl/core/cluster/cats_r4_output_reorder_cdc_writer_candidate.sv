`timescale 1ns/1ps

// Production-candidate output path:
// context chunk -> reorder serializer -> 8-beat chunk packer -> CDC -> DDR writer.
// The packer restores the 512-bit chunk contract required by the CDC boundary;
// reorder ownership and ordering checks remain in the core clock domain.
module cats_r4_output_reorder_cdc_writer_candidate #(
    parameter int DEPTH = 16,
    parameter int TOTAL_BEATS = 32*128*4*8,
    parameter logic [13:0] FINAL_CHUNK = (TOTAL_BEATS/8)-1
) (
    input logic core_clk, input logic core_rst_n, input logic core_counter_clear,
    input logic in_valid, output logic in_ready,
    input logic [1:0] in_cluster_id, input logic [15:0] in_epoch,
    input logic [4:0] in_global_q_head, input logic [6:0] in_row,
    input logic [1:0] in_feature_block, input logic [511:0] in_data_bf16,
    input logic in_row_last, input logic in_tensor_last,
    input logic axi_clk, input logic axi_rst_n, input logic axi_counter_clear,
    input logic start, input logic [31:0] base_addr,
    output logic wr_valid, input logic wr_ready, output logic [31:0] wr_addr,
    output logic [63:0] wr_data, output logic wr_row_last, output logic wr_tensor_last,
    output logic busy, output logic done, output logic error,
    output logic [63:0] chunks_accepted, output logic [63:0] beats_committed,
    output logic [63:0] protocol_error_count
);
    logic r_valid, r_ready;
    logic [1:0] r_cluster;
    logic [15:0] r_epoch;
    logic [11:0] r_seq;
    logic [4:0] r_head;
    logic [6:0] r_row;
    logic [1:0] r_block;
    logic [2:0] r_beat;
    logic [63:0] r_data;
    logic r_row_last, r_tensor_last;
    logic [$clog2(DEPTH+1)-1:0] r_occupancy;
    logic [63:0] r_chunks, r_committed, r_beats;
    logic r_sticky;
    logic [63:0] r_dup, r_ooo, r_late, r_gap, r_epoch_err, r_last, r_cluster_err;

    logic pack_valid, pack_active;
    logic [2:0] pack_count;
    logic [511:0] pack_data;
    logic [15:0] pack_epoch;
    logic [4:0] pack_head;
    logic [6:0] pack_row;
    logic [1:0] pack_block;
    logic pack_row_last, pack_tensor_last;
    logic chunk_ready;
    logic [63:0] cdc_errors;

    cats_r4_output_reorder_serializer #(.CLUSTERS(1), .DEPTH(DEPTH), .FINAL_CHUNK(FINAL_CHUNK)) u_reorder (
        .clk(core_clk), .rst_n(core_rst_n), .counter_clear(core_counter_clear),
        .in_valid, .in_ready, .in_cluster_id, .in_epoch, .in_global_q_head,
        .in_row, .in_feature_block, .in_data_bf16, .in_row_last, .in_tensor_last,
        .out_valid(r_valid), .out_ready(r_ready), .out_cluster_id(r_cluster),
        .out_epoch(r_epoch), .out_seq(r_seq), .out_global_q_head(r_head),
        .out_row(r_row), .out_feature_block(r_block), .out_beat_in_chunk(r_beat),
        .out_data(r_data), .out_row_last(r_row_last), .out_tensor_last(r_tensor_last),
        .occupancy(r_occupancy), .chunks_accepted(r_chunks),
        .chunks_committed(r_committed), .beats_committed(r_beats),
        .duplicate_count(r_dup), .out_of_order_count(r_ooo), .late_count(r_late),
        .gap_count(r_gap), .epoch_mismatch_count(r_epoch_err),
        .last_mismatch_count(r_last), .cluster_mismatch_count(r_cluster_err),
        .protocol_error_sticky(r_sticky)
    );

    assign r_ready = !pack_valid && (!pack_active || (pack_count != 3'd7));
    assign chunk_ready = pack_valid && chunk_in_ready;
    assign chunk_in_valid = pack_valid;

    logic chunk_in_valid, chunk_in_ready;
    logic [15:0] chunk_epoch;
    logic [4:0] chunk_head;
    logic [6:0] chunk_row;
    logic [1:0] chunk_block;
    logic [511:0] chunk_data;
    logic chunk_row_last, chunk_tensor_last;

    always_ff @(posedge core_clk) begin
        if (!core_rst_n || core_counter_clear) begin
            pack_valid <= 1'b0;
            pack_active <= 1'b0;
            pack_count <= '0;
            pack_data <= '0;
            pack_epoch <= '0;
            pack_head <= '0;
            pack_row <= '0;
            pack_block <= '0;
            pack_row_last <= 1'b0;
            pack_tensor_last <= 1'b0;
        end else begin
            if (r_valid && r_ready) begin
                pack_data[r_beat*64 +: 64] <= r_data;
                if (!pack_active) begin
                    pack_active <= 1'b1;
                    pack_count <= 3'd0;
                    pack_epoch <= r_epoch;
                    pack_head <= r_head;
                    pack_row <= r_row;
                    pack_block <= r_block;
                end else begin
                    pack_count <= pack_count + 1'b1;
                end
                if (r_beat == 3'd7) begin
                    pack_valid <= 1'b1;
                    pack_active <= 1'b1;
                    pack_count <= 3'd0;
                    pack_row_last <= r_row_last;
                    pack_tensor_last <= r_tensor_last;
                end
            end
            if (chunk_in_valid && chunk_in_ready) begin
                pack_valid <= 1'b0;
                pack_active <= 1'b0;
                pack_count <= '0;
            end
        end
    end

    assign chunk_epoch = pack_epoch;
    assign chunk_head = pack_head;
    assign chunk_row = pack_row;
    assign chunk_block = pack_block;
    assign chunk_data = pack_data;

    cats_r4_output_cdc_writer_candidate #(
        .TOTAL_BEATS(TOTAL_BEATS), .FINAL_CHUNK(FINAL_CHUNK)
    ) u_cdc_writer (
        .core_clk, .core_rst_n, .core_counter_clear,
        .in_valid(chunk_in_valid), .in_ready(chunk_in_ready),
        .in_epoch(chunk_epoch), .in_global_q_head(chunk_head), .in_row(chunk_row),
        .in_feature_block(chunk_block), .in_data_bf16(chunk_data),
        .in_row_last(pack_row_last), .in_tensor_last(pack_tensor_last),
        .axi_clk, .axi_rst_n, .axi_counter_clear, .start, .base_addr,
        .wr_valid, .wr_ready, .wr_addr, .wr_data, .wr_row_last, .wr_tensor_last,
        .busy, .done, .error, .protocol_error_count(cdc_errors)
    );

    assign chunks_accepted = r_chunks;
    assign beats_committed = u_cdc_writer.w.beats_accepted;
    assign protocol_error_count = cdc_errors | {63'd0, r_sticky} |
        r_dup | r_late | r_epoch_err | r_last | r_cluster_err;
endmodule