`timescale 1ns/1ps

module tb_cats_r4_qk_slot_lifecycle;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic reserve_valid, reserve_ready;
    logic [15:0] reserve_epoch;
    logic [2:0] reserve_group;
    logic [4:0] reserve_global_q_head;
    logic [6:0] reserve_row;
    logic [1:0] reserve_slot_id, reserve_numeric_mode;
    logic handoff_valid, handoff_ready;
    logic [15:0] handoff_epoch;
    logic [2:0] handoff_group;
    logic [4:0] handoff_global_q_head;
    logic [6:0] handoff_row;
    logic [1:0] handoff_slot_id, handoff_numeric_mode;
    logic abort_valid, abort_ready;
    logic [15:0] abort_epoch;
    logic [2:0] abort_group;
    logic [4:0] abort_global_q_head;
    logic [6:0] abort_row;
    logic [1:0] abort_slot_id, abort_numeric_mode;
    logic release_valid, release_ready;
    logic [15:0] release_epoch;
    logic [2:0] release_group;
    logic [4:0] release_global_q_head;
    logic [6:0] release_row;
    logic [1:0] release_slot_id, release_numeric_mode;
    logic [5:0] slot_owner;
    logic [63:0] reserves, handoffs, aborts, releases, owner_errors;
    logic owner_error_sticky;

    cats_r4_qk_slot_lifecycle dut (.*);
    task automatic tick; @(posedge clk); #1; endtask

    initial begin
        reserve_valid = 0;
        reserve_epoch = 16'h4404;
        reserve_group = 1;
        reserve_global_q_head = 6;
        reserve_row = 12;
        reserve_slot_id = 0;
        reserve_numeric_mode = 1;
        handoff_valid = 0;
        handoff_epoch = reserve_epoch;
        handoff_group = reserve_group;
        handoff_global_q_head = reserve_global_q_head;
        handoff_row = reserve_row;
        handoff_slot_id = reserve_slot_id;
        handoff_numeric_mode = reserve_numeric_mode;
        abort_valid = 0;
        abort_epoch = reserve_epoch;
        abort_group = reserve_group;
        abort_global_q_head = reserve_global_q_head;
        abort_row = reserve_row;
        abort_slot_id = reserve_slot_id;
        abort_numeric_mode = reserve_numeric_mode;
        release_valid = 0;
        release_epoch = reserve_epoch;
        release_group = reserve_group;
        release_global_q_head = reserve_global_q_head;
        release_row = reserve_row;
        release_slot_id = reserve_slot_id;
        release_numeric_mode = reserve_numeric_mode;
        repeat (3) tick();
        rst_n = 1;

        @(negedge clk); reserve_valid = 1; #1;
        if (!reserve_ready) $fatal(1, "free slot was not reservable");
        tick();
        @(negedge clk); reserve_valid = 0;
        if (slot_owner[1:0] !== 2'd1)
            $fatal(1, "slot did not enter A ownership");

        @(negedge clk); handoff_valid = 1; #1;
        if (!handoff_ready) $fatal(1, "matching A-to-B handoff rejected");
        tick();
        @(negedge clk); handoff_valid = 0;
        if (slot_owner[1:0] !== 2'd2)
            $fatal(1, "last score did not transfer ownership to B");

        // B ownership is deliberately not FREE.  A cannot reuse the slot
        // until the final V3 release for the exact token has transferred.
        @(negedge clk); reserve_valid = 1; #1;
        if (reserve_ready)
            $fatal(1, "slot was reused before final release");
        @(negedge clk); reserve_valid = 0;

        release_row = 13;
        @(negedge clk); release_valid = 1; #1;
        if (release_ready)
            $fatal(1, "wrong-token release was accepted");
        tick();
        @(negedge clk); release_valid = 0;
        if (slot_owner[1:0] !== 2'd2 || owner_errors !== 1 ||
            !owner_error_sticky)
            $fatal(1, "wrong-token release was not rejected and counted");
        release_row = reserve_row;

        @(negedge clk); release_valid = 1; #1;
        if (!release_ready) $fatal(1, "matching final release rejected");
        tick();
        @(negedge clk); release_valid = 0;
        if (slot_owner[1:0] !== 2'd0 || !reserve_ready)
            $fatal(1, "slot did not become FREE after final release");

        // A-side abort cancels a reservation without handing the slot to B.
        @(negedge clk); reserve_valid = 1; #1;
        if (!reserve_ready) $fatal(1, "slot was not reservable for abort test");
        tick();
        @(negedge clk); reserve_valid = 0; abort_valid = 1; #1;
        if (!abort_ready) $fatal(1, "matching A-owner abort rejected");
        tick();
        @(negedge clk); abort_valid = 0; #1;
        if (slot_owner[1:0] !== 2'd0 || !reserve_ready)
            $fatal(1, "abort did not return slot to FREE");

        // Abort wins if it competes with final-score handoff for one slot.
        @(negedge clk); reserve_valid = 1; #1;
        if (!reserve_ready) $fatal(1, "slot was not reservable for priority test");
        tick();
        @(negedge clk); reserve_valid = 0; abort_valid = 1;
        handoff_valid = 1; #1;
        if (!abort_ready || handoff_ready)
            $fatal(1, "abort did not win same-slot handoff competition");
        tick();
        @(negedge clk); abort_valid = 0; handoff_valid = 0; #1;
        if (slot_owner[1:0] !== 2'd0)
            $fatal(1, "priority abort left slot owned");

        if (reserves !== 3 || handoffs !== 1 || aborts !== 2 || releases !== 1 ||
            owner_errors !== 1 || !owner_error_sticky)
            $fatal(1, "slot lifecycle counters mismatch");
        $display("PASS: CATS-R4 slot A-to-B ownership and final-release-only reuse; A-owner abort cancellation");
        $finish;
    end
endmodule
