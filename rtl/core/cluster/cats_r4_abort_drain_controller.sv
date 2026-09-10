`timescale 1ns/1ps

// Three-domain soft-reset/abort coordinator.
//
// The GPIO domain owns the transaction.  A level request is synchronized to
// core and AXI, where it first blocks new work.  Each domain acknowledges only
// after its local outstanding count reaches zero.  Clear is then pulsed once
// in both domains; traffic is reopened only after both clear acknowledgements
// return and the quiesce level has been removed.  Multi-bit outstanding counts
// never cross a clock boundary.
module cats_r4_abort_drain_controller #(
    parameter logic [15:0] INITIAL_EPOCH = 16'd0
) (
    input  logic        arst_n,
    input  logic        gpio_clk,
    input  logic        core_clk,
    input  logic        axi_clk,

    input  logic        abort_valid,
    output logic        abort_ready,
    output logic        abort_done_valid,
    input  logic        abort_done_ready,
    output logic [15:0] abort_done_epoch,
    output logic [15:0] current_epoch,

    // These inputs are generated and consumed only in their named domains.
    input  logic        core_outstanding_zero,
    input  logic        axi_outstanding_zero,
    output logic        core_accept_enable,
    output logic        axi_accept_enable,
    output logic        core_clear,
    output logic        axi_clear,

    output logic        drain_active,
    output logic [63:0] abort_count,
    output logic [63:0] drain_cycles,
    output logic [63:0] epoch_wrap_count
);
    typedef enum logic [1:0] {
        ST_IDLE, ST_DRAIN, ST_CLEAR, ST_RELEASE
    } state_t;
    state_t state;

    logic quiesce_req_gpio;
    logic clear_req_gpio;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] quiesce_core_sync, clear_core_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] quiesce_axi_sync, clear_axi_sync;
    logic core_drain_ack, core_clear_ack, core_clear_seen;
    logic axi_drain_ack, axi_clear_ack, axi_clear_seen;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] core_drain_ack_sync, core_clear_ack_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] axi_drain_ack_sync, axi_clear_ack_sync;

    assign abort_ready = (state == ST_IDLE) && !abort_done_valid;
    assign drain_active = (state != ST_IDLE);

    always_ff @(posedge core_clk or negedge arst_n) begin
        if (!arst_n) begin
            quiesce_core_sync <= '0;
            clear_core_sync <= '0;
            core_accept_enable <= 1'b0;
            core_clear <= 1'b0;
            core_drain_ack <= 1'b0;
            core_clear_ack <= 1'b0;
            core_clear_seen <= 1'b0;
        end else begin
            quiesce_core_sync <= {quiesce_core_sync[0], quiesce_req_gpio};
            clear_core_sync <= {clear_core_sync[0], clear_req_gpio};
            core_clear <= 1'b0;
            if (quiesce_core_sync[1]) begin
                core_accept_enable <= 1'b0;
                core_drain_ack <= core_outstanding_zero;
                if (clear_core_sync[1] && core_outstanding_zero &&
                    !core_clear_seen) begin
                    core_clear <= 1'b1;
                    core_clear_seen <= 1'b1;
                    core_clear_ack <= 1'b1;
                end
            end else begin
                core_accept_enable <= 1'b1;
                core_drain_ack <= 1'b0;
                core_clear_ack <= 1'b0;
                core_clear_seen <= 1'b0;
            end
        end
    end

    always_ff @(posedge axi_clk or negedge arst_n) begin
        if (!arst_n) begin
            quiesce_axi_sync <= '0;
            clear_axi_sync <= '0;
            axi_accept_enable <= 1'b0;
            axi_clear <= 1'b0;
            axi_drain_ack <= 1'b0;
            axi_clear_ack <= 1'b0;
            axi_clear_seen <= 1'b0;
        end else begin
            quiesce_axi_sync <= {quiesce_axi_sync[0], quiesce_req_gpio};
            clear_axi_sync <= {clear_axi_sync[0], clear_req_gpio};
            axi_clear <= 1'b0;
            if (quiesce_axi_sync[1]) begin
                axi_accept_enable <= 1'b0;
                axi_drain_ack <= axi_outstanding_zero;
                if (clear_axi_sync[1] && axi_outstanding_zero &&
                    !axi_clear_seen) begin
                    axi_clear <= 1'b1;
                    axi_clear_seen <= 1'b1;
                    axi_clear_ack <= 1'b1;
                end
            end else begin
                axi_accept_enable <= 1'b1;
                axi_drain_ack <= 1'b0;
                axi_clear_ack <= 1'b0;
                axi_clear_seen <= 1'b0;
            end
        end
    end

    always_ff @(posedge gpio_clk or negedge arst_n) begin
        if (!arst_n) begin
            core_drain_ack_sync <= '0;
            core_clear_ack_sync <= '0;
            axi_drain_ack_sync <= '0;
            axi_clear_ack_sync <= '0;
            state <= ST_IDLE;
            quiesce_req_gpio <= 1'b0;
            clear_req_gpio <= 1'b0;
            abort_done_valid <= 1'b0;
            abort_done_epoch <= INITIAL_EPOCH;
            current_epoch <= INITIAL_EPOCH;
            abort_count <= '0;
            drain_cycles <= '0;
            epoch_wrap_count <= '0;
        end else begin
            core_drain_ack_sync <= {core_drain_ack_sync[0], core_drain_ack};
            core_clear_ack_sync <= {core_clear_ack_sync[0], core_clear_ack};
            axi_drain_ack_sync <= {axi_drain_ack_sync[0], axi_drain_ack};
            axi_clear_ack_sync <= {axi_clear_ack_sync[0], axi_clear_ack};

            if (abort_done_valid && abort_done_ready)
                abort_done_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (abort_valid && abort_ready) begin
                        quiesce_req_gpio <= 1'b1;
                        abort_count <= abort_count + 1'b1;
                        state <= ST_DRAIN;
                    end
                end
                ST_DRAIN: begin
                    drain_cycles <= drain_cycles + 1'b1;
                    if (core_drain_ack_sync[1] && axi_drain_ack_sync[1]) begin
                        clear_req_gpio <= 1'b1;
                        state <= ST_CLEAR;
                    end
                end
                ST_CLEAR: begin
                    if (core_clear_ack_sync[1] && axi_clear_ack_sync[1]) begin
                        clear_req_gpio <= 1'b0;
                        quiesce_req_gpio <= 1'b0;
                        current_epoch <= current_epoch + 1'b1;
                        abort_done_epoch <= current_epoch + 1'b1;
                        abort_done_valid <= 1'b1;
                        if (current_epoch == 16'hffff)
                            epoch_wrap_count <= epoch_wrap_count + 1'b1;
                        state <= ST_RELEASE;
                    end
                end
                ST_RELEASE: begin
                    if (!core_drain_ack_sync[1] && !axi_drain_ack_sync[1] &&
                        !core_clear_ack_sync[1] && !axi_clear_ack_sync[1])
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
