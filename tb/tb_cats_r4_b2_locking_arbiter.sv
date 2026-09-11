`timescale 1ns/1ps

module tb_cats_r4_b2_locking_arbiter;
    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic source0_valid = 0;
    logic source0_ready;
    logic source1_valid = 0;
    logic source1_ready;
    logic output_valid;
    logic output_ready = 0;
    logic selected_source;
    logic conflict;

    integer source0_accept = 0;
    integer source1_accept = 0;
    logic first_selected;

    always #5 clk = ~clk;

    cats_r4_b2_locking_arbiter dut (.*);

    always @(posedge clk) begin
        if (rst_n && !clear) begin
            if (source0_ready)
                source0_accept = source0_accept + 1;
            if (source1_ready)
                source1_accept = source1_accept + 1;
            if (source0_ready && source1_ready)
                $fatal(1, "both sources accepted in one cycle");
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        source0_valid = 1;
        source1_valid = 1;

        // Both sources request while the sink stalls.  Selection must remain
        // locked for the entire stall.
        @(posedge clk);
        first_selected = selected_source;
        if (!output_valid || !conflict)
            $fatal(1, "simultaneous request was not exposed");
        repeat (5) begin
            @(posedge clk);
            if (!output_valid || selected_source != first_selected ||
                source0_ready || source1_ready)
                $fatal(1, "stalled arbitration was not stable");
        end

        @(negedge clk);
        output_ready = 1;
        @(posedge clk);
        if (first_selected ? !source1_ready : !source0_ready)
            $fatal(1, "locked source did not receive the first grant");
        @(negedge clk);
        if (first_selected)
            source1_valid = 0;
        else
            source0_valid = 0;
        @(posedge clk);
        if (first_selected ? !source0_ready : !source1_ready)
            $fatal(1, "waiting source did not receive the second grant");
        @(negedge clk);
        source0_valid = 0;
        source1_valid = 0;

        if (source0_accept != 1 || source1_accept != 1)
            $fatal(1, "first collision lost or duplicated a grant");

        // Reassert a collision after clear and repeat with a three-cycle
        // output stall, covering source lock reset and conflict recovery.
        clear = 1;
        output_ready = 0;
        @(posedge clk);
        @(negedge clk);
        clear = 0;
        source0_valid = 1;
        source1_valid = 1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        output_ready = 1;
        @(posedge clk);
        if (!(source0_ready ^ source1_ready))
            $fatal(1, "post-clear collision did not grant exactly one source");

        $display(
            "PASS locking_arbiter grants=%0d/%0d first_source=%0d",
            source0_accept, source1_accept, first_selected);
        $finish;
    end
endmodule
