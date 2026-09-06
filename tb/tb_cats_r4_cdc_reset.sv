`timescale 1ns/1ps

module tb_cats_r4_cdc_reset;
    logic core_clk=0, axi_clk=0, gpio_clk=0;
    always #3.5 core_clk = ~core_clk;
    always #5.5 axi_clk  = ~axi_clk;
    always #8.5 gpio_clk = ~gpio_clk;

    logic arst_n=0;
    logic gpio_rst_n, axi_rst_n, core_rst_n, sequence_error;
    cats_r4_reset_sequencer u_sequence (.*);

    logic [31:0] src_counter='0;
    logic src_snapshot_valid=0, src_snapshot_ready, src_protocol_error;
    logic dst_snapshot_valid, dst_snapshot_ready=0;
    logic [31:0] dst_snapshot_data;
    logic dst_protocol_error;
    cats_r4_gray_counter_snapshot u_snapshot (
        .arst_n, .src_clk(core_clk), .src_counter,
        .src_snapshot_valid, .src_snapshot_ready, .src_protocol_error,
        .dst_clk(axi_clk), .dst_snapshot_valid, .dst_snapshot_ready,
        .dst_snapshot_data, .dst_protocol_error
    );

    integer accepted=0, delivered=0;
    logic [31:0] expected_snapshot='0;
    logic expected_valid=0;
    logic [15:0] lfsr=16'h1ace;

    always_ff @(posedge core_clk or negedge arst_n) begin
        if (!arst_n)
            src_counter <= '0;
        else if (core_rst_n)
            src_counter <= src_counter + 1'b1;
    end

    // Deterministic pseudo-random output backpressure.
    always_ff @(posedge axi_clk or negedge arst_n) begin
        if (!arst_n) begin
            lfsr <= 16'h1ace;
            dst_snapshot_ready <= 1'b0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            dst_snapshot_ready <= lfsr[0] | lfsr[3];
        end
    end

    always @(posedge axi_clk) begin
        #1;
        if (dst_snapshot_valid && dst_snapshot_ready) begin
            if (!expected_valid)
                $fatal(1,"destination produced an unrequested snapshot");
            if (dst_snapshot_data !== expected_snapshot)
                $fatal(1,"torn snapshot got=%h expected=%h",
                       dst_snapshot_data, expected_snapshot);
            expected_valid = 1'b0;
            delivered = delivered + 1;
        end
    end

    task automatic wait_all_released;
        integer guard;
        begin
            guard=0;
            while (!core_rst_n) begin
                @(posedge core_clk); #1;
                guard=guard+1;
                if (guard>50) $fatal(1,"reset release sequencing timeout");
            end
            if (!axi_rst_n || !gpio_rst_n)
                $fatal(1,"reset release order violated");
        end
    endtask

    task automatic request_snapshot;
        logic [31:0] captured;
        begin
            while (!src_snapshot_ready || !core_rst_n)
                @(negedge core_clk);
            captured=src_counter;
            src_snapshot_valid=1'b1;
            @(posedge core_clk); #1;
            src_snapshot_valid=1'b0;
            expected_snapshot=captured;
            expected_valid=1'b1;
            accepted=accepted+1;
            while (expected_valid) @(posedge axi_clk);
        end
    endtask

    initial begin
        // Simulation-time watchdog; normal run finishes far below 5 ms.
        #5_000_000;
        $fatal(1,"5 ms simulation watchdog expired");
    end

    initial begin
        #13 arst_n=1'b1; // deliberately asynchronous to all clocks
        wait_all_released();
        repeat (3) request_snapshot();

        // Assert reset between unrelated edges; every reset must fall without
        // waiting for a domain clock and the release chain must repeat safely.
        #19 arst_n=1'b0;
        #1;
        if (gpio_rst_n || axi_rst_n || core_rst_n)
            $fatal(1,"reset did not assert asynchronously");
        #23 arst_n=1'b1;
        expected_valid=1'b0;
        wait_all_released();
        repeat (12) begin
            repeat ((lfsr[2:0] % 5)+1) @(posedge core_clk);
            request_snapshot();
        end

        // Deliberately violate source ready once to prove sticky error logic.
        while (!src_snapshot_ready) @(negedge core_clk);
        expected_snapshot=src_counter;
        expected_valid=1'b1;
        src_snapshot_valid=1'b1;
        @(posedge core_clk); #1;
        accepted=accepted+1;
        // Keep valid asserted for a second source edge while busy.
        @(posedge core_clk); #1;
        src_snapshot_valid=1'b0;
        while (expected_valid) @(posedge axi_clk);
        if (!src_protocol_error)
            $fatal(1,"source protocol sticky error was not raised");
        if (dst_protocol_error || sequence_error)
            $fatal(1,"unexpected destination/reset error dst=%0d seq=%0d",
                   dst_protocol_error, sequence_error);
        if (accepted != delivered)
            $fatal(1,"snapshot count mismatch accepted=%0d delivered=%0d",
                   accepted, delivered);

        $display("PASS cats_r4_cdc_reset async-reset/ordered-release/gray-snapshot/backpressure accepted=%0d",
                 accepted);
        $finish;
    end
endmodule
