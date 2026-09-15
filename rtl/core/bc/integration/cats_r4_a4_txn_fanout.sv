`timescale 1ns/1ps

// Captures one global transaction and delivers exactly one start handshake to
// each cluster. Payload is registered before any child sees valid.
module cats_r4_a4_txn_fanout #(
    parameter integer CLUSTERS = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic txn_start_valid,
    output logic txn_start_ready,
    input  logic [15:0] txn_epoch,
    input  logic [1:0] txn_numeric_mode,
    output logic [CLUSTERS-1:0] cluster_start_valid,
    input  logic [CLUSTERS-1:0] cluster_start_ready,
    output logic [15:0] cluster_start_epoch,
    output logic [1:0] cluster_start_numeric_mode,
    output logic txn_active,
    output logic [15:0] txn_epoch_locked,
    output logic [1:0] txn_numeric_mode_locked,
    output logic [CLUSTERS-1:0] cluster_started,
    output logic all_clusters_started,
    input  logic txn_drain_complete,
    input  logic [CLUSTERS-1:0] cluster_quiescent,
    output logic protocol_error_valid,
    input  logic protocol_error_ready,
    output logic [3:0] protocol_error_code,
    output logic [15:0] protocol_error_epoch,
    output logic [1:0] protocol_error_numeric_mode
);
    localparam logic [3:0] ERROR_ILLEGAL_MODE = 4'h1;
    localparam logic [3:0] ERROR_BUSY_START   = 4'h2;
    localparam logic [3:0] ERROR_EPOCH_REUSE  = 4'h3;

    logic [CLUSTERS-1:0] start_pending;
    logic last_epoch_valid;
    logic [15:0] last_epoch;
    logic busy_violation_seen;
    integer cluster_i;

    assign txn_start_ready = !txn_active && !protocol_error_valid;
    assign cluster_start_valid = start_pending;
    assign cluster_start_epoch = txn_epoch_locked;
    assign cluster_start_numeric_mode = txn_numeric_mode_locked;
    assign cluster_started = {CLUSTERS{txn_active}} & ~start_pending;
    assign all_clusters_started = txn_active && !(|start_pending);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txn_active <= 1'b0;
            txn_epoch_locked <= '0;
            txn_numeric_mode_locked <= '0;
            start_pending <= '0;
            last_epoch_valid <= 1'b0;
            last_epoch <= '0;
            busy_violation_seen <= 1'b0;
            protocol_error_valid <= 1'b0;
            protocol_error_code <= '0;
            protocol_error_epoch <= '0;
            protocol_error_numeric_mode <= '0;
        end else if (clear) begin
            txn_active <= 1'b0;
            txn_epoch_locked <= '0;
            txn_numeric_mode_locked <= '0;
            start_pending <= '0;
            busy_violation_seen <= 1'b0;
            protocol_error_valid <= 1'b0;
        end else begin
            if (protocol_error_valid && protocol_error_ready)
                protocol_error_valid <= 1'b0;
            if (!txn_start_valid)
                busy_violation_seen <= 1'b0;

            for (cluster_i = 0; cluster_i < CLUSTERS;
                 cluster_i = cluster_i + 1)
                if (start_pending[cluster_i] && cluster_start_ready[cluster_i])
                    start_pending[cluster_i] <= 1'b0;

            if (txn_start_valid && txn_start_ready) begin
                if (txn_numeric_mode >= 2) begin
                    protocol_error_valid <= 1'b1;
                    protocol_error_code <= ERROR_ILLEGAL_MODE;
                    protocol_error_epoch <= txn_epoch;
                    protocol_error_numeric_mode <= txn_numeric_mode;
                end else if (last_epoch_valid && txn_epoch == last_epoch) begin
                    protocol_error_valid <= 1'b1;
                    protocol_error_code <= ERROR_EPOCH_REUSE;
                    protocol_error_epoch <= txn_epoch;
                    protocol_error_numeric_mode <= txn_numeric_mode;
                end else begin
                    txn_active <= 1'b1;
                    txn_epoch_locked <= txn_epoch;
                    txn_numeric_mode_locked <= txn_numeric_mode;
                    start_pending <= {CLUSTERS{1'b1}};
                    last_epoch_valid <= 1'b1;
                    last_epoch <= txn_epoch;
                end
            end else if (txn_active && txn_start_valid &&
                         !busy_violation_seen && !protocol_error_valid) begin
                busy_violation_seen <= 1'b1;
                protocol_error_valid <= 1'b1;
                protocol_error_code <= ERROR_BUSY_START;
                protocol_error_epoch <= txn_epoch;
                protocol_error_numeric_mode <= txn_numeric_mode;
            end

            // The wrapper supplies drain_complete only after all assigned group
            // completions. Quiescence is checked again here before unlocking.
            if (txn_active && all_clusters_started && txn_drain_complete &&
                (&cluster_quiescent))
                txn_active <= 1'b0;
        end
    end

    initial if (!(CLUSTERS == 1 || CLUSTERS == 2 || CLUSTERS == 4))
        $error("cats_r4_a4_txn_fanout: CLUSTERS must be 1, 2, or 4");
endmodule
