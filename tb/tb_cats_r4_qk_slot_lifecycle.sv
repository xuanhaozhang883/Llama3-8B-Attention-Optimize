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
    logic abort_valid, abort_accept, abort_ready;
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

    task automatic reserve_slot(input [1:0] slot, input [6:0] row_id);
        begin
            @(negedge clk);
            reserve_slot_id = slot;
            reserve_row = row_id;
            reserve_valid = 1;
            #1;
            if (!reserve_ready) $fatal(1, "slot %0d was not reservable", slot);
            tick();
            @(negedge clk); reserve_valid = 0;
        end
    endtask

    task automatic abort_slot(input [1:0] slot, input [6:0] row_id);
        begin
            @(negedge clk);
            abort_slot_id = slot;
            abort_row = row_id;
            abort_valid = 1;
            abort_accept = 1;
            #1;
            if (!abort_ready) $fatal(1, "slot %0d matching abort rejected", slot);
            tick();
            @(negedge clk);
            abort_valid = 0;
            abort_accept = 0;
        end
    endtask

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
        abort_accept = 0;
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

        reserve_slot(0, 12);
        if (slot_owner[1:0] !== 2'd1)
            $fatal(1, "slot did not enter A ownership");

        // A matching pending abort blocks the same-token final handoff while
        // downstream is stalled, without changing ownership or counters.
        @(negedge clk);
        abort_valid = 1;
        abort_accept = 0;
        handoff_valid = 1;
        #1;
        if (!abort_ready || handoff_ready)
            $fatal(1, "pending abort did not win over matching handoff");
        tick();
        tick();
        if (slot_owner[1:0] !== 2'd1 || aborts !== 0 || handoffs !== 0)
            $fatal(1, "stalled abort changed ownership or counters");
        @(negedge clk); abort_accept = 1; #1;
        if (!abort_ready || handoff_ready)
            $fatal(1, "accepted abort lost priority to matching handoff");
        tick();
        @(negedge clk);
        abort_valid = 0;
        abort_accept = 0;
        handoff_valid = 0;
        #1;
        if (slot_owner[1:0] !== 2'd0 || aborts !== 1 || !reserve_ready)
            $fatal(1, "accepted abort did not free the A-owned slot");

        // Reuse after abort, then preserve the normal A-to-B-to-FREE path.
        reserve_slot(0, 12);
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

        if (reserves !== 2 || handoffs !== 1 || aborts !== 1 || releases !== 1 ||
            owner_errors !== 1 || !owner_error_sticky)
            $fatal(1, "slot lifecycle counters mismatch");

        // A stale abort and an invalid release accepted in the same cycle
        // must retain ownership and increment owner_errors by two.
        reserve_slot(0, 12);
        @(negedge clk);
        abort_row = 13;
        abort_valid = 1;
        abort_accept = 1;
        release_row = 12;
        release_valid = 1;
        #1;
        if (abort_ready || release_ready)
            $fatal(1, "mismatched abort or A-owned release was accepted");
        tick();
        @(negedge clk);
        abort_valid = 0;
        abort_accept = 0;
        release_valid = 0;
        #1;
        if (slot_owner[1:0] !== 2'd1 || aborts !== 1 ||
            owner_errors !== 3 || !owner_error_sticky)
            $fatal(1, "reject aggregation or fail-stop ownership mismatch");

        // counter_clear is observational only: it clears counters/sticky but
        // does not release the currently A-owned slot.
        @(negedge clk); counter_clear = 1;
        tick();
        @(negedge clk); counter_clear = 0; #1;
        if (slot_owner[1:0] !== 2'd1 || reserves !== 0 || handoffs !== 0 ||
            aborts !== 0 || releases !== 0 || owner_errors !== 0 ||
            owner_error_sticky)
            $fatal(1, "counter_clear changed ownership or left counters set");

        abort_row = 12;
        abort_slot(0, 12);
        if (slot_owner[1:0] !== 2'd0 || aborts !== 1)
            $fatal(1, "post-counter-clear abort failed");

        // Reserve all three production slots, abort all three, then prove all
        // three can be reserved again without a global clear.
        reserve_slot(0, 20);
        reserve_slot(1, 21);
        reserve_slot(2, 22);
        if (slot_owner !== 6'b01_01_01)
            $fatal(1, "three-slot A ownership mismatch");
        abort_slot(0, 20);
        abort_slot(1, 21);
        abort_slot(2, 22);
        if (slot_owner !== 0 || aborts !== 4)
            $fatal(1, "three-slot abort did not release every slot");
        reserve_slot(0, 20);
        reserve_slot(1, 21);
        reserve_slot(2, 22);
        if (slot_owner !== 6'b01_01_01 || reserves !== 6 || aborts !== 4)
            $fatal(1, "three-slot reuse counters or ownership mismatch");

        // clear releases ownership but preserves diagnostic counters.
        @(negedge clk); clear = 1;
        tick();
        @(negedge clk); clear = 0; #1;
        if (slot_owner !== 0 || reserves !== 6 || aborts !== 4)
            $fatal(1, "clear ownership/counter semantics mismatch");

        // Reset clears both ownership and all counters.
        @(negedge clk); rst_n = 0;
        tick();
        @(negedge clk); #1;
        if (slot_owner !== 0 || reserves !== 0 || handoffs !== 0 ||
            aborts !== 0 || releases !== 0 || owner_errors !== 0 ||
            owner_error_sticky)
            $fatal(1, "reset did not clear lifecycle state");

        $display("PASS: CATS-R4 abort/cancel priority, counters, and three-slot reuse");
        $finish;
    end
endmodule
