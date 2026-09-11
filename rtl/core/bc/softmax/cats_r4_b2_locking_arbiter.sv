`timescale 1ns/1ps

// Two-source ready/valid arbiter with round-robin choice and lock-on-stall.
// Source 0 is Compatibility and source 1 is Accuracy in the common B2
// wrapper.  Payload muxing remains in that wrapper; locking the source index
// guarantees the mux cannot switch while the downstream transfer is stalled.
module cats_r4_b2_locking_arbiter (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic source0_valid,
    output logic source0_ready,
    input  logic source1_valid,
    output logic source1_ready,

    output logic output_valid,
    input  logic output_ready,
    output logic selected_source,
    output logic conflict
);
    logic lock_valid;
    logic lock_source;
    logic round_robin_source;
    logic output_fire;

    always_comb begin
        if (lock_valid)
            selected_source = lock_source;
        else if (source0_valid && source1_valid)
            selected_source = round_robin_source;
        else
            selected_source = source1_valid;

        output_valid = selected_source ? source1_valid : source0_valid;
        source0_ready = output_ready && output_valid && !selected_source;
        source1_ready = output_ready && output_valid && selected_source;
        conflict = source0_valid && source1_valid;
        output_fire = output_valid && output_ready;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_valid <= 0;
            lock_source <= 0;
            round_robin_source <= 0;
        end else if (clear) begin
            lock_valid <= 0;
            lock_source <= 0;
            round_robin_source <= 0;
        end else if (lock_valid) begin
            if (output_fire) begin
                lock_valid <= 0;
                round_robin_source <= !selected_source;
            end
        end else if (output_valid) begin
            if (output_fire)
                round_robin_source <= !selected_source;
            else begin
                lock_valid <= 1;
                lock_source <= selected_source;
            end
        end
    end

`ifndef SYNTHESIS
    logic stalled;
    logic stalled_source;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            stalled <= 0;
            stalled_source <= 0;
        end else begin
            if (stalled &&
                (!output_valid || selected_source != stalled_source))
                $fatal(1, "locking arbiter changed source while stalled");
            if (source0_ready && source1_ready)
                $fatal(1, "locking arbiter granted both sources");
            stalled <= output_valid && !output_ready;
            if (output_valid && !output_ready)
                stalled_source <= selected_source;
        end
    end
`endif
endmodule
