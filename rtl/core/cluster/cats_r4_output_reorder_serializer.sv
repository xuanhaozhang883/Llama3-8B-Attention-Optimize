`timescale 1ns/1ps

// CATS-R4 cluster-output reorder queue and 512b-to-64b serializer.
// Contract-only C2 infrastructure; not connected to the production manifest.
module cats_r4_output_reorder_serializer #(
    parameter int CLUSTERS = 1,
    parameter int DEPTH = 16,
    parameter logic [13:0] FINAL_CHUNK = 14'h3fff
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         counter_clear,

    input  logic         in_valid,
    output logic         in_ready,
    input  logic [1:0]   in_cluster_id,
    input  logic [15:0]  in_epoch,
    input  logic [4:0]   in_global_q_head,
    input  logic [6:0]   in_row,
    input  logic [1:0]   in_feature_block,
    input  logic [511:0] in_data_bf16,
    input  logic         in_row_last,
    input  logic         in_tensor_last,

    output logic         out_valid,
    input  logic         out_ready,
    output logic [1:0]   out_cluster_id,
    output logic [15:0]  out_epoch,
    output logic [11:0]  out_seq,
    output logic [4:0]   out_global_q_head,
    output logic [6:0]   out_row,
    output logic [1:0]   out_feature_block,
    output logic [2:0]   out_beat_in_chunk,
    output logic [63:0]  out_data,
    output logic         out_row_last,
    output logic         out_tensor_last,

    output logic [$clog2(DEPTH+1)-1:0] occupancy,
    output logic [63:0]  chunks_accepted,
    output logic [63:0]  chunks_committed,
    output logic [63:0]  beats_committed,
    output logic [63:0]  duplicate_count,
    output logic [63:0]  out_of_order_count,
    output logic [63:0]  late_count,
    output logic [63:0]  gap_count,
    output logic [63:0]  epoch_mismatch_count,
    output logic [63:0]  last_mismatch_count,
    output logic [63:0]  cluster_mismatch_count,
    output logic         protocol_error_sticky
);
    localparam int PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int OCC_W = $clog2(DEPTH+1);


    logic [DEPTH-1:0] slot_valid;
    logic [13:0] slot_chunk [0:DEPTH-1];
    logic [1:0] slot_cluster [0:DEPTH-1];
    logic [15:0] slot_epoch [0:DEPTH-1];
    logic [511:0] slot_data [0:DEPTH-1];

    logic epoch_valid;
    logic [15:0] epoch_reg;
    logic [13:0] expected_chunk;
    logic [2:0] beat_index;
    logic gap_episode;

    logic [13:0] input_chunk;
    logic input_duplicate, input_epoch_bad, input_late;
    logic input_cluster_bad, input_last_bad, input_is_expected;
    logic input_drop, free_found, expected_found;
    logic [PTR_W-1:0] free_index, expected_index;
    logic store_fire, beat_fire, chunk_fire;
    logic gap_now;
    integer scan;

    assign input_chunk = {in_global_q_head, in_row, in_feature_block};
    assign input_epoch_bad = epoch_valid && (in_epoch != epoch_reg);
    assign input_late = epoch_valid && (input_chunk < expected_chunk);
    assign input_cluster_bad = ($unsigned(in_cluster_id) >= CLUSTERS);
    assign input_last_bad =
        (in_row_last != (in_feature_block == 2'd3)) ||
        (in_tensor_last != (input_chunk == FINAL_CHUNK));
    assign input_is_expected = !epoch_valid || (input_chunk == expected_chunk);

    always_comb begin
        input_duplicate = 1'b0;
        free_found = 1'b0;
        free_index = '0;
        expected_found = 1'b0;
        expected_index = '0;
        for (scan = 0; scan < DEPTH; scan = scan + 1) begin
            if (slot_valid[scan] && (slot_chunk[scan] == input_chunk) &&
                (!epoch_valid || (slot_epoch[scan] == in_epoch)))
                input_duplicate = 1'b1;
            if (!free_found && !slot_valid[scan]) begin
                free_found = 1'b1;
                free_index = scan[PTR_W-1:0];
            end
            if (!expected_found && slot_valid[scan] && epoch_valid &&
                (slot_epoch[scan] == epoch_reg) &&
                (slot_chunk[scan] == expected_chunk)) begin
                expected_found = 1'b1;
                expected_index = scan[PTR_W-1:0];
            end
        end
    end

    assign input_drop = input_epoch_bad || input_late ||
                        input_duplicate || input_cluster_bad;

    // One slot is reserved for the missing expected chunk.  This prevents a
    // queue filled with future chunks from deadlocking canonical commit.
    always_comb begin
        if (input_drop)
            in_ready = 1'b1;
        else if (input_is_expected)
            in_ready = free_found;
        else
            in_ready = free_found && (occupancy < DEPTH-1);
    end

    assign store_fire = in_valid && in_ready && !input_drop;

    assign out_valid = expected_found;
    assign out_cluster_id = expected_found ? slot_cluster[expected_index] : '0;
    assign out_epoch = expected_found ? slot_epoch[expected_index] : epoch_reg;
    assign out_global_q_head = expected_chunk[13:9];
    assign out_row = expected_chunk[8:2];
    assign out_feature_block = expected_chunk[1:0];
    assign out_seq = expected_chunk[13:2];
    assign out_beat_in_chunk = beat_index;
    assign out_data = expected_found ?
                      slot_data[expected_index][beat_index*64 +: 64] : '0;
    assign out_row_last = expected_found &&
                          (expected_chunk[1:0] == 2'd3) &&
                          (beat_index == 3'd7);
    assign out_tensor_last = expected_found &&
                             (expected_chunk == FINAL_CHUNK) &&
                             (beat_index == 3'd7);
    assign beat_fire = out_valid && out_ready;
    assign chunk_fire = beat_fire && (beat_index == 3'd7);
    assign gap_now = epoch_valid && (occupancy != 0) && !expected_found;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slot_valid <= '0;
            epoch_valid <= 1'b0;
            epoch_reg <= '0;
            expected_chunk <= '0;
            beat_index <= '0;
            occupancy <= '0;
            gap_episode <= 1'b0;
            chunks_accepted <= '0;
            chunks_committed <= '0;
            beats_committed <= '0;
            duplicate_count <= '0;
            out_of_order_count <= '0;
            late_count <= '0;
            gap_count <= '0;
            epoch_mismatch_count <= '0;
            last_mismatch_count <= '0;
            cluster_mismatch_count <= '0;
            protocol_error_sticky <= 1'b0;
        end else begin
            if (store_fire) begin
                slot_valid[free_index] <= 1'b1;
                slot_chunk[free_index] <= input_chunk;
                slot_cluster[free_index] <= in_cluster_id;
                slot_epoch[free_index] <= in_epoch;
                slot_data[free_index] <= in_data_bf16;
                chunks_accepted <= chunks_accepted + 1'b1;
                if (!epoch_valid) begin
                    epoch_valid <= 1'b1;
                    epoch_reg <= in_epoch;
                    expected_chunk <= '0;
                end
                if (input_chunk != expected_chunk)
                    out_of_order_count <= out_of_order_count + 1'b1;
                if (input_last_bad) begin
                    last_mismatch_count <= last_mismatch_count + 1'b1;
                    protocol_error_sticky <= 1'b1;
                end
            end

            if (in_valid && in_ready && input_drop) begin
                protocol_error_sticky <= 1'b1;
                if (input_duplicate)
                    duplicate_count <= duplicate_count + 1'b1;
                if (input_late)
                    late_count <= late_count + 1'b1;
                if (input_epoch_bad)
                    epoch_mismatch_count <= epoch_mismatch_count + 1'b1;
                if (input_cluster_bad)
                    cluster_mismatch_count <= cluster_mismatch_count + 1'b1;
            end

            if (beat_fire) begin
                beats_committed <= beats_committed + 1'b1;
                if (beat_index == 3'd7) begin
                    beat_index <= '0;
                    slot_valid[expected_index] <= 1'b0;
                    chunks_committed <= chunks_committed + 1'b1;
                    if (expected_chunk == FINAL_CHUNK) begin
                        expected_chunk <= '0;
                        epoch_valid <= 1'b0;
                    end else begin
                        expected_chunk <= expected_chunk + 1'b1;
                    end
                end else begin
                    beat_index <= beat_index + 1'b1;
                end
            end

            case ({store_fire, chunk_fire})
                2'b10: occupancy <= occupancy + 1'b1;
                2'b01: occupancy <= occupancy - 1'b1;
                default: occupancy <= occupancy;
            endcase

            if (gap_now && !gap_episode) begin
                gap_episode <= 1'b1;
                gap_count <= gap_count + 1'b1;
            end else if (!gap_now) begin
                gap_episode <= 1'b0;
            end

            if (counter_clear) begin
                chunks_accepted <= '0;
                chunks_committed <= '0;
                beats_committed <= '0;
                duplicate_count <= '0;
                out_of_order_count <= '0;
                late_count <= '0;
                gap_count <= '0;
                epoch_mismatch_count <= '0;
                last_mismatch_count <= '0;
                cluster_mismatch_count <= '0;
                protocol_error_sticky <= 1'b0;
            end
        end
    end

    initial begin
        if ((DEPTH < 2) || (CLUSTERS < 1) || (CLUSTERS > 4))
            $error("cats_r4_output_reorder_serializer: invalid DEPTH/CLUSTERS");
    end
endmodule
