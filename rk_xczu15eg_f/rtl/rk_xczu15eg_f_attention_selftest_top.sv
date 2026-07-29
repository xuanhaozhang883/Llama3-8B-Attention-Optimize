`timescale 1ns/1ps

// RK-XCZU15EG-F V1.0 Stage 1 top:
// 200 MHz differential board clock -> 100 MHz PL test clock.
// All control and observation are through VIO/ILA; no PS or DDR is present.
module rk_xczu15eg_f_attention_selftest_top (
    input logic pl_clk0_p,
    input logic pl_clk0_n
);
    logic clk_100mhz;
    logic clk_locked;
    logic [3:0] reset_release;
    logic rst_n;

    logic restart_vio;
    logic restart_meta;
    logic restart_sync;
    logic restart_sync_d;
    logic restart_pulse;

    logic [63:0] status;
    logic busy;
    logic done;
    logic pass;
    logic fail;
    logic [16:0] error_count;
    logic [16:0] first_error_index;
    logic [63:0] cycle_count;
    logic start_debug;
    logic raw_req_valid_debug;
    logic raw_req_ready_debug;
    logic compare_valid_debug;

    rk_pl_clk_wiz u_clk_wiz (
        .clk_out1(clk_100mhz),
        .reset(1'b0),
        .locked(clk_locked),
        .clk_in1_p(pl_clk0_p),
        .clk_in1_n(pl_clk0_n)
    );

    // Asynchronous assertion when the MMCM is unlocked, synchronous release.
    always_ff @(posedge clk_100mhz or negedge clk_locked) begin
        if (!clk_locked)
            reset_release <= '0;
        else
            reset_release <= {reset_release[2:0], 1'b1};
    end
    assign rst_n = reset_release[3];

    // VIO restart is a level; convert it to a one-cycle pulse in this domain.
    always_ff @(posedge clk_100mhz) begin
        if (!rst_n) begin
            restart_meta <= 1'b0;
            restart_sync <= 1'b0;
            restart_sync_d <= 1'b0;
        end else begin
            restart_meta <= restart_vio;
            restart_sync <= restart_meta;
            restart_sync_d <= restart_sync;
        end
    end
    assign restart_pulse = restart_sync && !restart_sync_d;

    attention_pl_selftest_core u_selftest (
        .clk(clk_100mhz),
        .rst_n(rst_n),
        .restart(restart_pulse),
        .status(status),
        .busy_o(busy),
        .done_o(done),
        .pass_o(pass),
        .fail_o(fail),
        .error_count_o(error_count),
        .first_error_index_o(first_error_index),
        .cycle_count_o(cycle_count),
        .start_debug_o(start_debug),
        .raw_req_valid_debug_o(raw_req_valid_debug),
        .raw_req_ready_debug_o(raw_req_ready_debug),
        .compare_valid_debug_o(compare_valid_debug)
    );

    rk_selftest_vio u_vio (
        .clk(clk_100mhz),
        .probe_in0(busy),
        .probe_in1(done),
        .probe_in2(pass),
        .probe_in3(fail),
        .probe_in4(cycle_count),
        .probe_in5(error_count),
        .probe_in6(first_error_index),
        .probe_out0(restart_vio)
    );

    rk_selftest_ila u_ila (
        .clk(clk_100mhz),
        .probe0(restart_pulse),
        .probe1(start_debug),
        .probe2(busy),
        .probe3(done),
        .probe4(pass),
        .probe5(fail),
        .probe6(raw_req_valid_debug),
        .probe7(raw_req_ready_debug),
        .probe8(compare_valid_debug)
    );
endmodule
