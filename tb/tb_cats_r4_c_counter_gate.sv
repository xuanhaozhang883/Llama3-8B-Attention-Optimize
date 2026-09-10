`timescale 1ns/1ps

module tb_cats_r4_c_counter_gate;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic run_start = 1'b0, run_done = 1'b0;
    logic snapshot_valid = 1'b0, counter_clear = 1'b0;
    logic [63:0] rd_beats_snapshot = 0, wr_beats_snapshot = 0;
    logic [63:0] rows_committed_snapshot = 0;
    logic [63:0] protocol_errors_snapshot = 0, conflict_errors_snapshot = 0;
    logic [63:0] underflow_snapshot = 0, overflow_snapshot = 0;
    logic [63:0] seq_errors_snapshot = 0, epoch_drops_snapshot = 0;
    logic [63:0] rresp_errors_snapshot = 0, bresp_errors_snapshot = 0;
    logic snapshot_ready, snapshot_captured, gate_pass, gate_fail;
    logic [63:0] rd_beats_latched, wr_beats_latched, rows_committed_latched;
    logic [63:0] error_total_latched;

    cats_r4_c_counter_gate dut (.*);

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask
    task automatic fail(input string msg);
        begin $display("FAIL: %s", msg); $fatal(1); end
    endtask
    task automatic clear_run;
        begin
            run_start = 1'b1; tick(); run_start = 1'b0;
            if (snapshot_captured || gate_pass || gate_fail)
                fail("run_start did not clear previous result");
        end
    endtask
    task automatic capture;
        begin
            run_done = 1'b1; snapshot_valid = 1'b1;
            #1;
            if (!snapshot_ready) fail("snapshot was not ready at run_done");
            tick();
            run_done = 1'b0; snapshot_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (2) tick(); rst_n = 1'b1; tick();

        // Normal full-workload closure.
        clear_run();
        rd_beats_snapshot = 64'd196_608;
        wr_beats_snapshot = 64'd131_072;
        rows_committed_snapshot = 64'd4_096;
        capture();
        if (!snapshot_captured || !gate_pass || gate_fail ||
            rd_beats_latched != 64'd196_608 ||
            wr_beats_latched != 64'd131_072 ||
            rows_committed_latched != 64'd4_096 || error_total_latched != 0)
            fail("normal counter closure did not pass");

        // A wrong aggregate total must fail even when all error counters are 0.
        clear_run();
        rd_beats_snapshot = 64'd196_607;
        capture();
        if (!snapshot_captured || gate_pass || !gate_fail)
            fail("wrong beat total was accepted");

        // A normal total with an error counter must fail and expose the sum.
        clear_run();
        rd_beats_snapshot = 64'd196_608;
        protocol_errors_snapshot = 64'd2;
        underflow_snapshot = 64'd3;
        capture();
        if (gate_pass || !gate_fail || error_total_latched != 64'd5)
            fail("nonzero error counters were not rejected/summed");

        // Clear returns the gate to an unlatched state for the next run.
        counter_clear = 1'b1; tick(); counter_clear = 1'b0;
        if (snapshot_captured || gate_pass || gate_fail || error_total_latched != 0)
            fail("counter_clear did not clear snapshot state");
        $display("PASS cats_r4_c_counter_gate normal/mismatch/error/clear");
        $finish;
    end
endmodule
