`timescale 1ns/1ps

module tb_rk_xczu15eg_f_attention_selftest;
    localparam logic [16:0] NO_ERROR_INDEX = 17'h1ffff;
    localparam int EXPECTED_CONTEXT_WORDS = 65536;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic restart = 1'b0;
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
    logic [63:0] first_run_cycles;

    always #5 clk = ~clk;

    attention_pl_selftest_core dut (
        .clk(clk),
        .rst_n(rst_n),
        .restart(restart),
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

    always @(posedge clk) begin
        if (rst_n && !restart &&
            $isunknown({status, busy, done, pass, fail, error_count,
                        first_error_index, cycle_count, start_debug,
                        raw_req_valid_debug, raw_req_ready_debug,
                        compare_valid_debug}))
            $fatal(1, "[FAIL] X/Z detected on observable self-test signals");
    end

    task automatic check_completed_run(input int run_number);
        begin
            wait (done);
            @(posedge clk);
            $display("SELFTEST_RUN=%0d", run_number);
            $display("SELFTEST_STATUS=%016h", status);
            $display("SELFTEST_CONTEXT_COUNT=%0d", status[37:21]);
            $display("SELFTEST_RAW_REQUEST_COUNT=%0d", status[53:38]);
            $display("SELFTEST_MISMATCH_COUNT=%0d", error_count);
            $display("SELFTEST_FIRST_ERROR_INDEX=%0d", first_error_index);
            $display("SELFTEST_CYCLES=%0d", cycle_count);

            if (!pass || fail)
                $fatal(1, "[FAIL] run %0d did not assert PASS", run_number);
            if (error_count != 0)
                $fatal(1, "[FAIL] run %0d mismatch count=%0d",
                       run_number, error_count);
            if (first_error_index != NO_ERROR_INDEX)
                $fatal(1, "[FAIL] run %0d unexpected first error index=%0d",
                       run_number, first_error_index);
            if (status[37:21] != EXPECTED_CONTEXT_WORDS)
                $fatal(1, "[FAIL] run %0d context count=%0d",
                       run_number, status[37:21]);
            if (cycle_count == 0)
                $fatal(1, "[FAIL] run %0d cycle counter did not run",
                       run_number);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        check_completed_run(1);
        first_run_cycles = cycle_count;

        @(negedge clk);
        restart = 1'b1;
        repeat (2) @(negedge clk);
        restart = 1'b0;
        wait (!done);

        check_completed_run(2);
        if (cycle_count != first_run_cycles)
            $fatal(1, "[FAIL] restart run cycles changed: first=%0d second=%0d",
                   first_run_cycles, cycle_count);

        $display("[PASS] RK-XCZU15EG-F single-GQA golden self-test passed twice");
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "[FAIL] RK-XCZU15EG-F golden self-test timed out");
    end
endmodule
