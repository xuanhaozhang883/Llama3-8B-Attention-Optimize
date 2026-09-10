`timescale 1ns/1ps

module tb_cats_r4_abort_drain_controller;
    logic arst_n = 1'b0;
    logic gpio_clk = 1'b0;
    logic core_clk = 1'b0;
    logic axi_clk = 1'b0;
    always #5.5 gpio_clk = ~gpio_clk;
    always #3.5 core_clk = ~core_clk;
    always #4.5 axi_clk = ~axi_clk;

    logic abort_valid = 1'b0, abort_ready;
    logic abort_done_valid, abort_done_ready = 1'b0;
    logic [15:0] abort_done_epoch, current_epoch;
    logic core_outstanding_zero = 1'b1;
    logic axi_outstanding_zero = 1'b1;
    logic core_accept_enable, axi_accept_enable;
    logic core_clear, axi_clear, drain_active;
    logic [63:0] abort_count, drain_cycles, epoch_wrap_count;

    integer core_clear_count = 0;
    integer axi_clear_count = 0;
    logic [15:0] held_done_epoch;

    cats_r4_abort_drain_controller dut (.*);

    task automatic fail(input string message);
        begin
            $display("FAIL: %s", message);
            $fatal(1);
        end
    endtask

    task automatic issue_abort;
        begin
            while (!abort_ready) @(negedge gpio_clk);
            abort_valid = 1'b1;
            @(posedge gpio_clk);
            @(negedge gpio_clk);
            abort_valid = 1'b0;
        end
    endtask

    always @(posedge core_clk) begin
        #1;
        if (core_clear) begin
            core_clear_count = core_clear_count + 1;
            if (!core_outstanding_zero || core_accept_enable)
                fail("core clear occurred before isolation/drain");
        end
    end

    always @(posedge axi_clk) begin
        #1;
        if (axi_clear) begin
            axi_clear_count = axi_clear_count + 1;
            if (!axi_outstanding_zero || axi_accept_enable)
                fail("AXI clear occurred before isolation/drain");
        end
    end

    initial begin
        #2_000_000 fail("watchdog timeout");
    end

    initial begin
        #17.3 arst_n = 1'b1;
        wait (core_accept_enable && axi_accept_enable && abort_ready);

        // First abort must isolate both domains and wait for independently
        // draining outstanding work before either local clear pulse.
        core_outstanding_zero = 1'b0;
        axi_outstanding_zero = 1'b0;
        issue_abort();
        if (!drain_active) fail("drain did not start after abort transfer");
        wait (!core_accept_enable && !axi_accept_enable);
        repeat (5) @(posedge gpio_clk);
        if (core_clear_count || axi_clear_count)
            fail("clear occurred while both domains were outstanding");

        core_outstanding_zero = 1'b1;
        repeat (5) @(posedge gpio_clk);
        if (core_clear_count || axi_clear_count)
            fail("clear occurred before AXI drained");
        axi_outstanding_zero = 1'b1;
        wait (abort_done_valid);
        if ((core_clear_count != 1) || (axi_clear_count != 1))
            fail("first abort did not clear each domain exactly once");
        if ((abort_done_epoch != 16'd1) || (current_epoch != 16'd1))
            fail("first abort did not advance epoch exactly once");

        held_done_epoch = abort_done_epoch;
        repeat (4) begin
            @(posedge gpio_clk); #1;
            if (!abort_done_valid || abort_done_epoch != held_done_epoch)
                fail("abort completion changed under backpressure");
        end
        abort_done_ready = 1'b1;
        @(posedge gpio_clk);
        @(negedge gpio_clk);
        abort_done_ready = 1'b0;
        wait (core_accept_enable && axi_accept_enable && abort_ready);

        // Already-idle domains still receive one clear pulse apiece.
        issue_abort();
        wait (abort_done_valid);
        if ((core_clear_count != 2) || (axi_clear_count != 2))
            fail("second abort clear pulse count mismatch");
        if ((abort_done_epoch != 16'd2) || (current_epoch != 16'd2))
            fail("second abort epoch mismatch");
        abort_done_ready = 1'b1;
        @(posedge gpio_clk);
        @(negedge gpio_clk);
        abort_done_ready = 1'b0;
        wait (core_accept_enable && axi_accept_enable && abort_ready);

        if ((abort_count != 2) || (drain_cycles == 0) ||
            (epoch_wrap_count != 0))
            fail("abort/drain counters mismatch");

        // A hard reset in an active drain safely returns every domain to the
        // initial epoch and disabled state before normal synchronized startup.
        core_outstanding_zero = 1'b0;
        issue_abort();
        wait (!core_accept_enable);
        #1.7 arst_n = 1'b0;
        #1;
        if (core_accept_enable || axi_accept_enable || drain_active ||
            abort_done_valid || current_epoch != 0)
            fail("hard reset did not atomically cancel active abort");
        core_outstanding_zero = 1'b1;
        #19.1 arst_n = 1'b1;
        wait (core_accept_enable && axi_accept_enable && abort_ready);

        $display("PASS cats_r4_abort_drain_controller isolate/drain/clear/epoch/restart");
        $finish;
    end
endmodule
