`timescale 1ns/1ps

// Buffered, locked round-robin join for cluster-local completion/error events.
// Each source owns one entry. Sources must retain valid/payload until accepted.
module cats_r4_a4_event_join #(
    parameter integer CLUSTERS = 2,
    parameter integer PAYLOAD_WIDTH = 48,
    parameter integer SOURCE_WIDTH = (CLUSTERS <= 1) ? 1 : $clog2(CLUSTERS)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic counter_clear,
    input  logic [CLUSTERS-1:0] source_valid,
    output logic [CLUSTERS-1:0] source_ready,
    input  logic [CLUSTERS*PAYLOAD_WIDTH-1:0] source_payload,
    output logic event_valid,
    input  logic event_ready,
    output logic [SOURCE_WIDTH-1:0] event_source,
    output logic [PAYLOAD_WIDTH-1:0] event_payload,
    output logic [CLUSTERS*64-1:0] source_events_accepted,
    output logic [63:0] events_emitted,
    output logic [63:0] event_stall_cycles,
    output logic [63:0] simultaneous_accept_cycles
);
    logic [CLUSTERS-1:0] pending;
    logic [PAYLOAD_WIDTH-1:0] pending_payload [0:CLUSTERS-1];
    logic [SOURCE_WIDTH-1:0] rr_start;
    logic locked;
    logic [SOURCE_WIDTH-1:0] locked_source;
    logic arb_valid;
    logic [SOURCE_WIDTH-1:0] arb_source;
    integer offset;
    integer candidate;
    integer accepted_count;
    integer accept_i;
    integer seq_i;

    assign source_ready = ~pending;

    // always @* avoids an Icarus always_comb constant-select limitation while
    // preserving the same combinational sensitivity and synthesis behavior.
    always @* begin
        arb_valid = 1'b0;
        arb_source = rr_start;
        for (offset = 0; offset < CLUSTERS; offset = offset + 1) begin
            candidate = (rr_start + offset) % CLUSTERS;
            if (!arb_valid && pending[candidate]) begin
                arb_valid = 1'b1;
                arb_source = candidate[SOURCE_WIDTH-1:0];
            end
        end
        event_valid = locked ? pending[locked_source] : arb_valid;
        event_source = locked ? locked_source : arb_source;
        event_payload = pending_payload[event_source];
        accepted_count = 0;
        for (accept_i = 0; accept_i < CLUSTERS; accept_i = accept_i + 1)
            if (source_valid[accept_i] && source_ready[accept_i])
                accepted_count = accepted_count + 1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= '0;
            rr_start <= '0;
            locked <= 1'b0;
            locked_source <= '0;
            source_events_accepted <= '0;
            events_emitted <= '0;
            event_stall_cycles <= '0;
            simultaneous_accept_cycles <= '0;
            for (seq_i = 0; seq_i < CLUSTERS; seq_i = seq_i + 1)
                pending_payload[seq_i] <= '0;
        end else if (clear) begin
            pending <= '0;
            rr_start <= '0;
            locked <= 1'b0;
            locked_source <= '0;
        end else begin
            if (counter_clear) begin
                source_events_accepted <= '0;
                events_emitted <= '0;
                event_stall_cycles <= '0;
                simultaneous_accept_cycles <= '0;
            end
            for (seq_i = 0; seq_i < CLUSTERS; seq_i = seq_i + 1) begin
                if (source_valid[seq_i] && source_ready[seq_i]) begin
                    pending[seq_i] <= 1'b1;
                    pending_payload[seq_i] <=
                        source_payload[seq_i*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
                    if (!counter_clear)
                        source_events_accepted[seq_i*64 +: 64] <=
                            source_events_accepted[seq_i*64 +: 64] + 1'b1;
                end
            end
            if (!counter_clear && accepted_count > 1)
                simultaneous_accept_cycles <= simultaneous_accept_cycles + 1'b1;
            if (event_valid && !event_ready) begin
                if (!locked) begin
                    locked <= 1'b1;
                    locked_source <= event_source;
                end
                if (!counter_clear)
                    event_stall_cycles <= event_stall_cycles + 1'b1;
            end
            if (event_valid && event_ready) begin
                pending[event_source] <= 1'b0;
                locked <= 1'b0;
                rr_start <= (event_source == CLUSTERS-1) ?
                            '0 : event_source + 1'b1;
                if (!counter_clear)
                    events_emitted <= events_emitted + 1'b1;
            end
        end
    end

    initial begin
        if (!(CLUSTERS == 1 || CLUSTERS == 2 || CLUSTERS == 4))
            $error("cats_r4_a4_event_join: CLUSTERS must be 1, 2, or 4");
    end
endmodule
