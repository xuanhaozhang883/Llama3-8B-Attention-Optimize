`timescale 1ns/1ps

// CATS-R4 system-counter closure gate.
//
// Owner domains must first produce coherent end-of-transaction snapshots;
// this module deliberately does not cross clock domains or add counters to
// the datapath.  It latches one snapshot when run_done and snapshot_valid
// coincide, compares the mandatory normal-workload totals, and requires all
// supplied error counters to be zero.  The result is sticky until the next
// run_start/counter_clear/reset so a GPIO/status reader can sample it later.
//
// This is an integration gate primitive, not a replacement for production
// wrapper wiring.  It becomes meaningful only when real C/A/B owner-domain
// snapshots are connected to its inputs.
module cats_r4_c_counter_gate #(
    parameter logic [63:0] EXPECTED_RD_BEATS  = 64'd196_608,
    parameter logic [63:0] EXPECTED_WR_BEATS  = 64'd131_072,
    parameter logic [63:0] EXPECTED_ROWS      = 64'd4_096
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_start,
    input  logic run_done,
    input  logic snapshot_valid,
    input  logic counter_clear,

    input  logic [63:0] rd_beats_snapshot,
    input  logic [63:0] wr_beats_snapshot,
    input  logic [63:0] rows_committed_snapshot,
    input  logic [63:0] protocol_errors_snapshot,
    input  logic [63:0] conflict_errors_snapshot,
    input  logic [63:0] underflow_snapshot,
    input  logic [63:0] overflow_snapshot,
    input  logic [63:0] seq_errors_snapshot,
    input  logic [63:0] epoch_drops_snapshot,
    input  logic [63:0] rresp_errors_snapshot,
    input  logic [63:0] bresp_errors_snapshot,

    output logic snapshot_ready,
    output logic snapshot_captured,
    output logic gate_pass,
    output logic gate_fail,
    output logic [63:0] rd_beats_latched,
    output logic [63:0] wr_beats_latched,
    output logic [63:0] rows_committed_latched,
    output logic [63:0] error_total_latched
);
    logic error_free;
    logic totals_match;

    assign snapshot_ready = run_done && snapshot_valid && !snapshot_captured;

    always_comb begin
        totals_match = (rd_beats_snapshot == EXPECTED_RD_BEATS) &&
                       (wr_beats_snapshot == EXPECTED_WR_BEATS) &&
                       (rows_committed_snapshot == EXPECTED_ROWS);
        error_free = (protocol_errors_snapshot == 0) &&
                     (conflict_errors_snapshot == 0) &&
                     (underflow_snapshot == 0) &&
                     (overflow_snapshot == 0) &&
                     (seq_errors_snapshot == 0) &&
                     (epoch_drops_snapshot == 0) &&
                     (rresp_errors_snapshot == 0) &&
                     (bresp_errors_snapshot == 0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snapshot_captured     <= 1'b0;
            gate_pass             <= 1'b0;
            gate_fail             <= 1'b0;
            rd_beats_latched      <= '0;
            wr_beats_latched      <= '0;
            rows_committed_latched<= '0;
            error_total_latched   <= '0;
        end else begin
            if (run_start || counter_clear) begin
                snapshot_captured      <= 1'b0;
                gate_pass              <= 1'b0;
                gate_fail              <= 1'b0;
                rd_beats_latched       <= '0;
                wr_beats_latched       <= '0;
                rows_committed_latched <= '0;
                error_total_latched    <= '0;
            end else if (snapshot_ready) begin
                snapshot_captured      <= 1'b1;
                gate_pass              <= totals_match && error_free;
                gate_fail              <= !(totals_match && error_free);
                rd_beats_latched       <= rd_beats_snapshot;
                wr_beats_latched       <= wr_beats_snapshot;
                rows_committed_latched <= rows_committed_snapshot;
                error_total_latched    <= protocol_errors_snapshot +
                                           conflict_errors_snapshot +
                                           underflow_snapshot +
                                           overflow_snapshot +
                                           seq_errors_snapshot +
                                           epoch_drops_snapshot +
                                           rresp_errors_snapshot +
                                           bresp_errors_snapshot;
            end
        end
    end
endmodule
