`timescale 1ns/1ps

module tb_gqa_overlap_scheduler;

    localparam int NUM_GROUPS = 8;
    localparam int GROUP_W    = $clog2(NUM_GROUPS);
    localparam int CLK_PERIOD = 10;
    localparam int TIMEOUT_CYCLES = 5000;

    logic clk;
    logic rst_n;
    logic start;
    logic start_ready;
    logic busy;
    logic done;

    logic bc_group_start;
    logic bc_group_start_ready;
    logic [GROUP_W-1:0] bc_group_id;
    logic bc_write_bank;
    logic bc_group_done;

    logic fill_start;
    logic fill_bank;
    logic [GROUP_W-1:0] fill_group_id;
    logic fill_complete;

    logic pv_start;
    logic pv_start_ready;
    logic [GROUP_W-1:0] pv_group_id;
    logic pv_read_bank;
    logic pv_feed_enable;
    logic pv_done;

    logic child_protocol_error;
    logic group_complete;
    logic [GROUP_W-1:0] completed_group_id;

    logic [63:0] total_cycles;
    logic [63:0] bc_active_cycles;
    logic [63:0] pv_active_cycles;
    logic [63:0] overlap_cycles;
    logic [63:0] bc_wait_bank_cycles;
    logic [63:0] pv_wait_ready_cycles;

    logic [1:0] bank0_state;
    logic [1:0] bank1_state;
    logic [GROUP_W-1:0] bank0_group_id;
    logic [GROUP_W-1:0] bank1_group_id;
    logic bc_active;
    logic pv_active;
    logic [7:0] error_bitmap;
    logic protocol_error;

    logic [31:0] lfsr;

    logic bc_model_busy;
    integer bc_compute_countdown;
    integer fill_countdown;
    integer bc_launch_count;

    logic pv_model_busy;
    integer pv_countdown;
    integer pv_launch_count;

    integer complete_count;
    integer done_count;
    integer timeout_count;
    logic overlap_seen;

    gqa_overlap_scheduler #(
        .NUM_GROUPS(NUM_GROUPS),
        .GROUP_W(GROUP_W),
        .PERF_W(64)
    ) dut (
        .clk,
        .rst_n,
        .start,
        .start_ready,
        .busy,
        .done,
        .bc_group_start,
        .bc_group_start_ready,
        .bc_group_id,
        .bc_write_bank,
        .bc_group_done,
        .fill_start,
        .fill_bank,
        .fill_group_id,
        .fill_complete,
        .pv_start,
        .pv_start_ready,
        .pv_group_id,
        .pv_read_bank,
        .pv_feed_enable,
        .pv_done,
        .child_protocol_error,
        .group_complete,
        .completed_group_id,
        .total_cycles,
        .bc_active_cycles,
        .pv_active_cycles,
        .overlap_cycles,
        .bc_wait_bank_cycles,
        .pv_wait_ready_cycles,
        .bank0_state,
        .bank1_state,
        .bank0_group_id,
        .bank1_group_id,
        .bc_active,
        .pv_active,
        .error_bitmap,
        .protocol_error
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Deterministic pseudo-random ready throttling.
    always_ff @(posedge clk) begin
        if (!rst_n)
            lfsr <= 32'h1ACE_B00C;
        else
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    assign bc_group_start_ready = !bc_model_busy && (lfsr[2:0] != 3'b000);
    assign pv_start_ready       = !pv_model_busy && (lfsr[5:3] != 3'b000);

    // Synthetic B+C and buffer-fill model. The two completion events use
    // different latencies and therefore may arrive in either order.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bc_model_busy        <= 1'b0;
            bc_compute_countdown <= 0;
            fill_countdown       <= 0;
            bc_group_done        <= 1'b0;
            fill_complete        <= 1'b0;
            bc_launch_count      <= 0;
        end else begin
            bc_group_done <= 1'b0;
            fill_complete <= 1'b0;

            if (bc_group_start && bc_group_start_ready) begin
                if (bc_model_busy)
                    $fatal(1, "TB: B+C launched while model busy");

                if ($unsigned(bc_group_id) != bc_launch_count)
                    $fatal(1,
                        "TB: B+C Group order error, expected=%0d got=%0d",
                        bc_launch_count, bc_group_id);

                if (!fill_start ||
                    (fill_bank != bc_write_bank) ||
                    (fill_group_id != bc_group_id))
                    $fatal(1, "TB: fill launch metadata mismatch");

                bc_model_busy        <= 1'b1;
                bc_compute_countdown <= 8 + $unsigned(bc_group_id);
                fill_countdown       <= 10 +
                    (NUM_GROUPS-1-$unsigned(bc_group_id));
                bc_launch_count      <= bc_launch_count + 1;
            end

            if (bc_model_busy) begin
                if (bc_compute_countdown > 1)
                    bc_compute_countdown <=
                        bc_compute_countdown - 1;
                else if (bc_compute_countdown == 1) begin
                    bc_compute_countdown <= 0;
                    bc_group_done        <= 1'b1;
                end

                if (fill_countdown > 1)
                    fill_countdown <= fill_countdown - 1;
                else if (fill_countdown == 1) begin
                    fill_countdown <= 0;
                    fill_complete  <= 1'b1;
                end

                if (((bc_compute_countdown == 0) ||
                     (bc_compute_countdown == 1)) &&
                    ((fill_countdown == 0) ||
                     (fill_countdown == 1)))
                    bc_model_busy <= 1'b0;
            end
        end
    end

    // Synthetic real-PV model.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pv_model_busy   <= 1'b0;
            pv_countdown    <= 0;
            pv_done         <= 1'b0;
            pv_launch_count <= 0;
        end else begin
            pv_done <= 1'b0;

            if (pv_start && pv_start_ready) begin
                if (pv_model_busy)
                    $fatal(1, "TB: PV launched while model busy");

                if ($unsigned(pv_group_id) != pv_launch_count)
                    $fatal(1,
                        "TB: PV Group order error, expected=%0d got=%0d",
                        pv_launch_count, pv_group_id);

                if (!pv_feed_enable)
                    $fatal(1, "TB: pv_feed_enable low on launch");

                pv_model_busy   <= 1'b1;
                pv_countdown    <= 7 +
                    ($unsigned(pv_group_id) % 3);
                pv_launch_count <= pv_launch_count + 1;
            end

            if (pv_model_busy) begin
                if (!pv_feed_enable)
                    $fatal(1, "TB: pv_feed_enable dropped while PV active");

                if (pv_countdown > 1)
                    pv_countdown <= pv_countdown - 1;
                else if (pv_countdown == 1) begin
                    pv_countdown  <= 0;
                    pv_done       <= 1'b1;
                    pv_model_busy <= 1'b0;
                end
            end
        end
    end

    // Scoreboard and timeout.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            complete_count <= 0;
            done_count     <= 0;
            timeout_count  <= 0;
            overlap_seen   <= 1'b0;
        end else begin
            if (busy)
                timeout_count <= timeout_count + 1;

            if (timeout_count > TIMEOUT_CYCLES)
                $fatal(1, "TB: timeout");

            if (bc_active && pv_active)
                overlap_seen <= 1'b1;

            if (group_complete) begin
                if ($unsigned(completed_group_id) != complete_count)
                    $fatal(1,
                        "TB: completion order error, expected=%0d got=%0d",
                        complete_count, completed_group_id);

                complete_count <= complete_count + 1;
            end

            if (done)
                done_count <= done_count + 1;
        end
    end

    initial begin
        rst_n                = 1'b0;
        start                = 1'b0;
        child_protocol_error = 1'b0;

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        if (!start_ready)
            $fatal(1, "TB: scheduler not ready after reset");

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (done);
        @(posedge clk);
        repeat (3) @(posedge clk);

        if (bc_launch_count != NUM_GROUPS)
            $fatal(1, "TB: B+C launches %0d/%0d",
                   bc_launch_count, NUM_GROUPS);

        if (pv_launch_count != NUM_GROUPS)
            $fatal(1, "TB: PV launches %0d/%0d",
                   pv_launch_count, NUM_GROUPS);

        if (complete_count != NUM_GROUPS)
            $fatal(1, "TB: completions %0d/%0d",
                   complete_count, NUM_GROUPS);

        if (done_count != 1)
            $fatal(1, "TB: done pulses %0d/1", done_count);

        if (!overlap_seen || (overlap_cycles == 0))
            $fatal(1, "TB: no B+C/PV overlap observed");

        if (protocol_error || (error_bitmap != 8'h00))
            $fatal(1, "TB: error_bitmap=%02h", error_bitmap);

        if (!start_ready || busy)
            $fatal(1, "TB: scheduler did not return to idle");

        $display("================================================");
        $display("[PASS] GQA overlap scheduler self-check");
        $display("B+C launches          = %0d / %0d",
                 bc_launch_count, NUM_GROUPS);
        $display("PV launches           = %0d / %0d",
                 pv_launch_count, NUM_GROUPS);
        $display("Group completions     = %0d / %0d",
                 complete_count, NUM_GROUPS);
        $display("Total cycles          = %0d", total_cycles);
        $display("B+C active cycles     = %0d", bc_active_cycles);
        $display("PV active cycles      = %0d", pv_active_cycles);
        $display("Overlap cycles        = %0d", overlap_cycles);
        $display("B+C bank-wait cycles  = %0d", bc_wait_bank_cycles);
        $display("PV ready-wait cycles  = %0d", pv_wait_ready_cycles);
        $display("Error bitmap          = %02h", error_bitmap);
        $display("================================================");
        $finish;
    end

endmodule
