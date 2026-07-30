`timescale 1ns/1ps

module tb_gqa_overlap_scheduler;

    localparam int NUM_GROUPS = 8;
    localparam int GROUP_W    = 3;

    localparam logic [1:0] BANK_EMPTY    = 2'd0;
    localparam logic [1:0] BANK_FILLING  = 2'd1;
    localparam logic [1:0] BANK_READY    = 2'd2;
    localparam logic [1:0] BANK_DRAINING = 2'd3;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic start;
    logic start_ready;
    logic busy;
    logic done;

    logic bc_group_start;
    logic [GROUP_W-1:0] bc_group_id;
    logic bc_group_start_ready;
    logic bc_group_done;
    logic fill_start;
    logic fill_bank;
    logic [GROUP_W-1:0] fill_group_id;
    logic fill_ready;
    logic fill_done;
    logic fill_done_bank;
    logic [GROUP_W-1:0] fill_done_group_id;

    logic pv_start;
    logic [GROUP_W-1:0] pv_group_id;
    logic pv_start_ready;
    logic pv_done;
    logic drain_start;
    logic drain_bank;
    logic [GROUP_W-1:0] drain_group_id;
    logic drain_ready;
    logic release_valid;
    logic release_bank;
    logic [GROUP_W-1:0] release_group_id;

    logic [1:0] bank0_state;
    logic [1:0] bank1_state;
    logic [GROUP_W-1:0] bank0_group_id;
    logic [GROUP_W-1:0] bank1_group_id;
    logic child_protocol_error;

    logic bc_active;
    logic pv_active;
    logic [GROUP_W-1:0] bc_active_group_id;
    logic [GROUP_W-1:0] pv_active_group_id;
    logic bc_wait_for_empty_bank;
    logic pv_wait_for_ready_bank;
    logic group_complete;
    logic [GROUP_W-1:0] completed_group_id;
    logic start_while_busy_error;
    logic protocol_error;

    integer bc_countdown;
    integer fill_countdown;
    integer pv_countdown;
    integer bc_launches;
    integer pv_launches;
    integer completions;
    integer overlap_cycles;
    integer total_cycles;
    integer timeout_cycles;

    logic model_bc_bank;
    logic [GROUP_W-1:0] model_bc_group;
    logic model_pv_bank;
    logic [GROUP_W-1:0] model_pv_group;

    assign fill_ready =
        (fill_bank ? bank1_state : bank0_state) == BANK_EMPTY;

    assign drain_ready =
        ((drain_bank ? bank1_state : bank0_state) == BANK_READY) &&
        ((drain_bank ? bank1_group_id : bank0_group_id) ==
         drain_group_id);

    gqa_overlap_scheduler #(
        .NUM_GROUPS(NUM_GROUPS),
        .GROUP_W(GROUP_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .start_ready(start_ready),
        .busy(busy),
        .done(done),
        .bc_group_start(bc_group_start),
        .bc_group_id(bc_group_id),
        .bc_group_start_ready(bc_group_start_ready),
        .bc_group_done(bc_group_done),
        .fill_start(fill_start),
        .fill_bank(fill_bank),
        .fill_group_id(fill_group_id),
        .fill_ready(fill_ready),
        .fill_done(fill_done),
        .fill_done_bank(fill_done_bank),
        .fill_done_group_id(fill_done_group_id),
        .pv_start(pv_start),
        .pv_group_id(pv_group_id),
        .pv_start_ready(pv_start_ready),
        .pv_done(pv_done),
        .drain_start(drain_start),
        .drain_bank(drain_bank),
        .drain_group_id(drain_group_id),
        .drain_ready(drain_ready),
        .release_valid(release_valid),
        .release_bank(release_bank),
        .release_group_id(release_group_id),
        .bank0_state(bank0_state),
        .bank1_state(bank1_state),
        .bank0_group_id(bank0_group_id),
        .bank1_group_id(bank1_group_id),
        .child_protocol_error(child_protocol_error),
        .bc_active(bc_active),
        .pv_active(pv_active),
        .bc_active_group_id(bc_active_group_id),
        .pv_active_group_id(pv_active_group_id),
        .bc_wait_for_empty_bank(bc_wait_for_empty_bank),
        .pv_wait_for_ready_bank(pv_wait_for_ready_bank),
        .group_complete(group_complete),
        .completed_group_id(completed_group_id),
        .start_while_busy_error(start_while_busy_error),
        .protocol_error(protocol_error)
    );

    // A deliberately asymmetric environment:
    // B+C takes 17/20 cycles; Buffer fill takes 20/17 cycles by Group parity.
    // PV takes 13 cycles. Ready is periodically stalled to verify that each
    // paired launch remains atomic.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank0_state       <= BANK_EMPTY;
            bank1_state       <= BANK_EMPTY;
            bank0_group_id    <= '0;
            bank1_group_id    <= '0;
            bc_group_done     <= 1'b0;
            fill_done         <= 1'b0;
            fill_done_bank    <= 1'b0;
            fill_done_group_id<= '0;
            pv_done           <= 1'b0;
            bc_countdown      <= -1;
            fill_countdown    <= -1;
            pv_countdown      <= -1;
            bc_launches       <= 0;
            pv_launches       <= 0;
            completions       <= 0;
            overlap_cycles    <= 0;
            total_cycles      <= 0;
            model_bc_bank     <= 1'b0;
            model_bc_group    <= '0;
            model_pv_bank     <= 1'b0;
            model_pv_group    <= '0;
        end else begin
            bc_group_done <= 1'b0;
            fill_done     <= 1'b0;
            pv_done       <= 1'b0;

            if (busy)
                total_cycles <= total_cycles + 1;

            if (bc_active && pv_active)
                overlap_cycles <= overlap_cycles + 1;

            if (bc_group_start || fill_start) begin
                assert (bc_group_start && fill_start)
                    else $fatal(1, "B+C/fill half launch");
                assert (bc_group_id == fill_group_id)
                    else $fatal(1, "B+C/fill Group mismatch");
                assert (bc_group_id == bc_launches[GROUP_W-1:0])
                    else $fatal(1, "B+C Group order mismatch");

                bc_launches    <= bc_launches + 1;
                model_bc_bank  <= fill_bank;
                model_bc_group <= fill_group_id;
                bc_countdown   <= fill_group_id[0] ? 20 : 17;
                fill_countdown <= fill_group_id[0] ? 17 : 20;

                if (fill_bank) begin
                    assert (bank1_state == BANK_EMPTY)
                        else $fatal(1, "Bank 1 filled while non-empty");
                    bank1_state    <= BANK_FILLING;
                    bank1_group_id <= fill_group_id;
                end else begin
                    assert (bank0_state == BANK_EMPTY)
                        else $fatal(1, "Bank 0 filled while non-empty");
                    bank0_state    <= BANK_FILLING;
                    bank0_group_id <= fill_group_id;
                end
            end

            if (bc_countdown > 0)
                bc_countdown <= bc_countdown - 1;
            else if (bc_countdown == 0) begin
                bc_group_done <= 1'b1;
                bc_countdown  <= -1;
            end

            if (fill_countdown > 0)
                fill_countdown <= fill_countdown - 1;
            else if (fill_countdown == 0) begin
                fill_done          <= 1'b1;
                fill_done_bank     <= model_bc_bank;
                fill_done_group_id <= model_bc_group;
                fill_countdown     <= -1;

                if (model_bc_bank)
                    bank1_state <= BANK_READY;
                else
                    bank0_state <= BANK_READY;
            end

            if (pv_start || drain_start) begin
                assert (pv_start && drain_start)
                    else $fatal(1, "PV/drain half launch");
                assert (pv_group_id == drain_group_id)
                    else $fatal(1, "PV/drain Group mismatch");
                assert (pv_group_id == pv_launches[GROUP_W-1:0])
                    else $fatal(1, "PV Group order mismatch");

                pv_launches    <= pv_launches + 1;
                model_pv_bank  <= drain_bank;
                model_pv_group <= drain_group_id;
                pv_countdown   <= 13;

                if (drain_bank) begin
                    assert (bank1_state == BANK_READY)
                        else $fatal(1, "Bank 1 drained while not READY");
                    bank1_state <= BANK_DRAINING;
                end else begin
                    assert (bank0_state == BANK_READY)
                        else $fatal(1, "Bank 0 drained while not READY");
                    bank0_state <= BANK_DRAINING;
                end
            end

            if (pv_countdown > 0)
                pv_countdown <= pv_countdown - 1;
            else if (pv_countdown == 0) begin
                pv_done      <= 1'b1;
                pv_countdown <= -1;
            end

            if (release_valid) begin
                assert (release_bank == model_pv_bank)
                    else $fatal(1, "Released wrong Bank");
                assert (release_group_id == model_pv_group)
                    else $fatal(1, "Released wrong Group");
                assert (release_group_id == completions[GROUP_W-1:0])
                    else $fatal(1, "Completion order mismatch");
                completions <= completions + 1;

                if (release_bank)
                    bank1_state <= BANK_EMPTY;
                else
                    bank0_state <= BANK_EMPTY;
            end
        end
    end

    // Periodic downstream stalls. Selection metadata must remain stable until
    // both endpoints become ready; no starts may be lost during these stalls.
    always_comb begin
        bc_group_start_ready = (total_cycles[2:0] != 3'd3);
        pv_start_ready       = (total_cycles[1:0] != 2'd2);
    end

    initial begin
        start                = 1'b0;
        child_protocol_error = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        wait (start_ready);
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        timeout_cycles = 0;
        while (!done && timeout_cycles < 5000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end

        if (!done)
            $fatal(1, "Scheduler timeout");

        // Allow registered monitors to settle.
        repeat (2) @(posedge clk);

        assert (bc_launches == NUM_GROUPS)
            else $fatal(1, "B+C launches %0d/%0d",
                        bc_launches, NUM_GROUPS);
        assert (pv_launches == NUM_GROUPS)
            else $fatal(1, "PV launches %0d/%0d",
                        pv_launches, NUM_GROUPS);
        assert (completions == NUM_GROUPS)
            else $fatal(1, "Completions %0d/%0d",
                        completions, NUM_GROUPS);
        assert (overlap_cycles > 0)
            else $fatal(1, "No B+C/PV overlap observed");
        assert (!protocol_error)
            else $fatal(1, "Scheduler protocol_error asserted");
        assert (!start_while_busy_error)
            else $fatal(1, "Unexpected start_while_busy_error");
        assert (bank0_state == BANK_EMPTY &&
                bank1_state == BANK_EMPTY)
            else $fatal(1, "Banks were not released");

        $display("================================================");
        $display("[PASS] corrected GQA overlap scheduler");
        $display("B+C launches      = %0d / %0d",
                 bc_launches, NUM_GROUPS);
        $display("PV launches       = %0d / %0d",
                 pv_launches, NUM_GROUPS);
        $display("Group completions = %0d / %0d",
                 completions, NUM_GROUPS);
        $display("Total cycles      = %0d", total_cycles);
        $display("Overlap cycles    = %0d", overlap_cycles);
        $display("================================================");
        $finish;
    end

endmodule
