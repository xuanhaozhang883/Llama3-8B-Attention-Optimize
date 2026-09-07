`timescale 1ns/1ps

// CATS-R4 reset release chain.  All domains assert immediately from arst_n.
// GPIO releases first, AXI only after GPIO is observed high, and core only
// after AXI is observed high.  Every output deasserts synchronously to its own
// clock.  sequence_error is sticky in the core domain.
module cats_r4_reset_sequencer (
    input  logic arst_n,
    input  logic gpio_clk,
    input  logic axi_clk,
    input  logic core_clk,
    output logic gpio_rst_n,
    output logic axi_rst_n,
    output logic core_rst_n,
    output logic sequence_error
);
    logic axi_async_release_n;
    logic core_async_release_n;

    cats_r4_reset_sync u_gpio_reset (
        .clk(gpio_clk), .arst_n(arst_n), .srst_n(gpio_rst_n)
    );

    // These AND terms are monotonic during release.  Each downstream module
    // still performs its own synchronous deassertion.
    assign axi_async_release_n = arst_n && gpio_rst_n;
    cats_r4_reset_sync u_axi_reset (
        .clk(axi_clk), .arst_n(axi_async_release_n), .srst_n(axi_rst_n)
    );

    assign core_async_release_n = arst_n && axi_rst_n;
    cats_r4_reset_sync u_core_reset (
        .clk(core_clk), .arst_n(core_async_release_n), .srst_n(core_rst_n)
    );

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] gpio_up_core;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] axi_up_core;

    always_ff @(posedge core_clk or negedge arst_n) begin
        if (!arst_n) begin
            gpio_up_core  <= '0;
            axi_up_core   <= '0;
            sequence_error <= 1'b0;
        end else begin
            gpio_up_core <= {gpio_up_core[0], gpio_rst_n};
            axi_up_core  <= {axi_up_core[0], axi_rst_n};
            if ((axi_up_core[1] && !gpio_up_core[1]) ||
                (core_rst_n && (!axi_up_core[1] || !gpio_up_core[1])))
                sequence_error <= 1'b1;
        end
    end
endmodule
