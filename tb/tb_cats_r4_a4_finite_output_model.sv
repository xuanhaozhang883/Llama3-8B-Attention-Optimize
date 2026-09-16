`timescale 1ns/1ps

// Protocol-only model for the temporary C canonical-output decision.  It
// deliberately stores occupancy rather than Context payload: data integrity
// remains the responsibility of the full-protocol scoreboard.
module tb_cats_r4_a4_finite_output_model #(
    parameter integer CLUSTERS = 2,
    parameter integer ROWS_PER_CLUSTER = 512,
    parameter integer CHUNKS_PER_ROW = 4,
    parameter integer BEATS_PER_CHUNK = 8
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic global_halt,
    input  logic [CLUSTERS-1:0] context_valid,
    output logic [CLUSTERS-1:0] context_ready,
    input  logic sink_ready,
    output logic sink_valid,
    output logic [$clog2(CLUSTERS)-1:0] sink_source,
    output logic [$clog2(BEATS_PER_CHUNK)-1:0] sink_beat,
    output logic [CLUSTERS-1:0][$clog2(ROWS_PER_CLUSTER*CHUNKS_PER_ROW+1)-1:0] occupancy,
    output logic [CLUSTERS-1:0][63:0] chunks_accepted,
    output logic [CLUSTERS-1:0][63:0] chunks_drained,
    output logic [63:0] sink_beats_accepted,
    output logic sink_idle
);
    localparam integer DEPTH = ROWS_PER_CLUSTER * CHUNKS_PER_ROW;
    localparam integer OCC_W = $clog2(DEPTH + 1);
    localparam integer SRC_W = $clog2(CLUSTERS);
    localparam integer BEAT_W = $clog2(BEATS_PER_CHUNK);

    logic sink_busy;
    logic [SRC_W-1:0] selected_source;
    logic [BEAT_W-1:0] beat_index;
    logic [SRC_W-1:0] rr_next;
    logic [CLUSTERS-1:0] push;
    logic [CLUSTERS-1:0] pop_chunk;
    integer i;

    always_comb begin
        for(i=0;i<CLUSTERS;i=i+1)
            context_ready[i] = !global_halt && occupancy[i] < DEPTH;
        push = context_valid & context_ready;
        pop_chunk = '0;
        if(sink_busy && sink_ready && beat_index == BEATS_PER_CHUNK-1)
            pop_chunk[selected_source] = 1'b1;
    end

    assign sink_valid = sink_busy;
    assign sink_source = selected_source;
    assign sink_beat = beat_index;
    assign sink_idle = !sink_busy && (occupancy == '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            occupancy <= '0;
            chunks_accepted <= '0;
            chunks_drained <= '0;
            sink_beats_accepted <= '0;
            sink_busy <= 1'b0;
            selected_source <= '0;
            beat_index <= '0;
            rr_next <= '0;
        end else if(clear) begin
            occupancy <= '0;
            chunks_accepted <= '0;
            chunks_drained <= '0;
            sink_beats_accepted <= '0;
            sink_busy <= 1'b0;
            selected_source <= '0;
            beat_index <= '0;
            rr_next <= '0;
        end else begin
            for(i=0;i<CLUSTERS;i=i+1) begin
                case({push[i],pop_chunk[i]})
                    2'b10: occupancy[i] <= occupancy[i] + 1'b1;
                    2'b01: occupancy[i] <= occupancy[i] - 1'b1;
                    default: occupancy[i] <= occupancy[i];
                endcase
                if(push[i]) chunks_accepted[i] <= chunks_accepted[i] + 1'b1;
                if(pop_chunk[i]) chunks_drained[i] <= chunks_drained[i] + 1'b1;
            end

            if(!sink_busy) begin
                if(occupancy[rr_next] != 0) begin
                    selected_source <= rr_next;
                    beat_index <= '0;
                    sink_busy <= 1'b1;
                end else if(occupancy[rr_next ^ 1'b1] != 0) begin
                    selected_source <= rr_next ^ 1'b1;
                    beat_index <= '0;
                    sink_busy <= 1'b1;
                end
            end else if(sink_ready) begin
                sink_beats_accepted <= sink_beats_accepted + 1'b1;
                if(beat_index == BEATS_PER_CHUNK-1) begin
                    sink_busy <= 1'b0;
                    beat_index <= '0;
                    rr_next <= selected_source ^ 1'b1;
                end else begin
                    beat_index <= beat_index + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) if(rst_n && !clear) begin
        for(i=0;i<CLUSTERS;i=i+1)
            assert(occupancy[i] <= DEPTH);
        assert($onehot0(pop_chunk));
    end
`endif
endmodule
