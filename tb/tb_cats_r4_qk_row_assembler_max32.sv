`timescale 1ns/1ps

module tb_cats_r4_qk_row_assembler_max32;
    localparam int LANES = 32;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic txn_start_valid; logic txn_start_ready;
    logic [15:0] txn_epoch; logic [1:0] txn_numeric_mode;
    logic row_open_valid; logic row_open_ready;
    logic [15:0] row_open_epoch; logic [2:0] row_open_group;
    logic [4:0] row_open_global_q_head; logic [6:0] row_open_row;
    logic [1:0] row_open_slot_id, row_open_numeric_mode;
    logic block_valid; logic block_ready;
    logic [15:0] block_epoch; logic [2:0] block_group;
    logic [4:0] block_global_q_head; logic [6:0] block_row;
    logic [1:0] block_slot_id, block_numeric_mode, block_key_block;
    logic [LANES-1:0] block_lane_valid;
    logic [LANES*16-1:0] block_score_bf16;
    logic store_wr_valid, store_wr_ready;
    logic [1:0] store_wr_slot_id; logic [6:0] store_wr_key_base;
    logic [LANES-1:0] store_wr_lane_valid;
    logic [LANES*16-1:0] store_wr_score_bf16;
    logic row_valid, row_ready; logic [15:0] row_epoch;
    logic [2:0] row_group; logic [4:0] row_global_q_head;
    logic [6:0] row_index; logic [1:0] row_slot_id, row_numeric_mode;
    logic [15:0] row_max_bf16;
    logic abort_valid, abort_ready; logic [15:0] abort_epoch;
    logic [2:0] abort_group; logic [4:0] abort_global_q_head;
    logic [6:0] abort_row; logic [1:0] abort_slot_id, abort_numeric_mode;
    logic [2:0] abort_error_code; logic [6:0] abort_error_key;

    cats_r4_qk_row_assembler #(.SEQ_LEN(128), .LANES(LANES), .SLOTS(3)) dut (
        .clk, .rst_n, .clear, .counter_clear,
        .txn_start_valid, .txn_start_ready, .txn_epoch, .txn_numeric_mode,
        .row_open_valid, .row_open_ready, .row_open_epoch, .row_open_group,
        .row_open_global_q_head, .row_open_row, .row_open_slot_id,
        .row_open_numeric_mode, .block_valid, .block_ready, .block_epoch,
        .block_group, .block_global_q_head, .block_row, .block_slot_id,
        .block_numeric_mode, .block_key_block, .block_lane_valid,
        .block_score_bf16, .store_wr_valid, .store_wr_ready,
        .store_wr_slot_id, .store_wr_key_base, .store_wr_lane_valid,
        .store_wr_score_bf16, .row_valid, .row_ready, .row_epoch,
        .row_group, .row_global_q_head, .row_index, .row_slot_id,
        .row_numeric_mode, .row_max_bf16, .abort_valid, .abort_ready,
        .abort_epoch, .abort_group, .abort_global_q_head, .abort_row,
        .abort_slot_id, .abort_numeric_mode, .abort_error_code,
        .abort_error_key, .rows_opened(), .blocks_accepted(),
        .scores_accepted(), .rows_completed(), .protocol_errors(),
        .numeric_errors(), .mode_errors(), .protocol_error_sticky()
    );

    function automatic logic finite(input logic [15:0] v);
        finite = v[14:7] != 8'hff;
    endfunction
    function automatic logic gt(input logic [15:0] a, input logic [15:0] b);
        logic az, bz;
        begin
            az = a[14:0] == 0; bz = b[14:0] == 0;
            if (az && bz) gt = 0;
            else if (a[15] != b[15]) gt = b[15];
            else if (!a[15]) gt = a[14:0] > b[14:0];
            else gt = a[14:0] < b[14:0];
        end
    endfunction

    task automatic check_reference(input logic [LANES-1:0] mask,
                                   input logic [LANES*16-1:0] scores,
                                   input string label);
        logic have, nonfinite; logic [15:0] maximum, value; integer n;
        begin
            have = 0; nonfinite = 0; maximum = 0;
            for (n = 0; n < LANES; n = n + 1) begin
                value = scores[n*16 +: 16];
                if (mask[n]) begin
                    if (!finite(value)) nonfinite = 1;
                    else if (!have || gt(value, maximum)) begin
                        have = 1; maximum = value;
                    end
                end
            end
            block_lane_valid = mask; block_score_bf16 = scores; #1;
            if (dut.max_tree_l5[16] !== have ||
                (|dut.nonfinite_leaves) !== nonfinite ||
                dut.max_tree_l5[15:0] !== maximum)
                $fatal(1, "%s mismatch have=%b/%b nonfinite=%b/%b max=%h/%h",
                       label, dut.max_tree_l5[16], have,
                       |dut.nonfinite_leaves, nonfinite,
                       dut.max_tree_l5[15:0], maximum);
        end
    endtask

    task automatic tick; @(posedge clk); #1; endtask
    task automatic open_row(input [6:0] r, input [1:0] slot);
        begin
            @(negedge clk); row_open_valid=1; row_open_row=r;
            row_open_slot_id=slot; #1;
            if (!row_open_ready) $fatal(1, "row open rejected");
            tick(); @(negedge clk); row_open_valid=0;
        end
    endtask

    logic [LANES*16-1:0] v;
    logic [LANES*16-1:0] held_store;
    initial begin
        txn_start_valid=0; txn_epoch=16'h3301; txn_numeric_mode=1;
        row_open_valid=0; row_open_epoch=16'h3301; row_open_group=2;
        row_open_global_q_head=7; row_open_row=0; row_open_slot_id=0;
        row_open_numeric_mode=1; block_valid=0; block_epoch=16'h3301;
        block_group=2; block_global_q_head=7; block_row=0; block_slot_id=0;
        block_numeric_mode=1; block_key_block=0; block_lane_valid=0;
        block_score_bf16=0; store_wr_ready=1; row_ready=0; abort_ready=1;

        // Pure combinational equivalence vectors define the legacy serial
        // scan as the reference, including its first/left winner on ties.
        v='0; check_reference('0, v, "all-invalid");
        v='0; v[0*16 +:16]=16'h3f80; check_reference(32'h1,v,"lane0");
        v='0; v[31*16+:16]=16'h4120; check_reference(32'h80000000,v,"lane31");
        v='0; v[2*16+:16]=16'hbf80; v[17*16+:16]=16'h4020;
        v[29*16+:16]=16'h4000; check_reference((32'h1<<2)|(32'h1<<17)|(32'h1<<29),v,"mixed-position");
        v='0; v[1*16+:16]=16'hc040; v[11*16+:16]=16'hbf00;
        v[30*16+:16]=16'hc000; check_reference((32'h1<<1)|(32'h1<<11)|(32'h1<<30),v,"all-negative");
        v='0; v[3*16+:16]=16'h4040; v[27*16+:16]=16'h4040;
        check_reference((32'h1<<3)|(32'h1<<27),v,"equal-values");
        v='0; v[2*16+:16]=16'h8000; v[9*16+:16]=16'h0000;
        check_reference((32'h1<<2)|(32'h1<<9),v,"minus-zero-left");
        v='0; v[2*16+:16]=16'h0000; v[9*16+:16]=16'h8000;
        check_reference((32'h1<<2)|(32'h1<<9),v,"plus-zero-left");
        v='0; v[5*16+:16]=16'h7f80; v[18*16+:16]=16'h3fc0;
        v[23*16+:16]=16'h7fc1;
        check_reference((32'h1<<5)|(32'h1<<18)|(32'h1<<23),v,"finite-and-nonfinite");
        v='0; v[4*16+:16]=16'hff80; v[28*16+:16]=16'h7fc0;
        check_reference((32'h1<<4)|(32'h1<<28),v,"all-nonfinite");

        repeat(3) tick(); rst_n=1;
        @(negedge clk); txn_start_valid=1; tick();
        @(negedge clk); txn_start_valid=0;

        // A legal final block must obey store backpressure, then publish a
        // stable row descriptor with the max selected above.
        open_row(31,0);
        v='0; v[0*16+:16]=16'hbf80; v[15*16+:16]=16'h4100;
        v[31*16+:16]=16'h4000;
        @(negedge clk); block_valid=1; block_row=31; block_slot_id=0;
        block_lane_valid='1; block_score_bf16=v; store_wr_ready=1; #1;
        if (block_ready || store_wr_valid)
            $fatal(1,"block committed before max pipeline stage 1");
        tick();
        if (block_ready || store_wr_valid)
            $fatal(1,"block committed before max pipeline stage 2");
        tick();
        if (!block_ready || !store_wr_valid)
            $fatal(1,"block was not ready after two max pipeline stages");
        @(negedge clk); store_wr_ready=0; #1;
        if (block_ready || !store_wr_valid || store_wr_key_base!==0)
            $fatal(1,"last block ignored store stall");
        held_store=store_wr_score_bf16;
        repeat(2) begin tick(); if(block_ready || !store_wr_valid ||
            store_wr_score_bf16!==held_store) $fatal(1,"store payload changed while stalled"); end
        @(negedge clk); store_wr_ready=1; #1;
        if(!block_ready) $fatal(1,"last block did not resume");
        tick(); @(negedge clk); block_valid=0;
        while(!row_valid) tick();
        if(row_index!==31 || row_slot_id!==0 || row_max_bf16!==16'h4100)
            $fatal(1,"last row/max mismatch");
        repeat(2) begin tick(); if(!row_valid || row_max_bf16!==16'h4100)
            $fatal(1,"row payload changed while stalled"); end
        @(negedge clk); row_ready=1; tick(); @(negedge clk); row_ready=0;

        // Non-finite input is consumed only by the abort path and its payload
        // remains stable until ready.
        open_row(31,1); abort_ready=0; v='0; v[12*16+:16]=16'h7f80;
        @(negedge clk); block_valid=1; block_row=31; block_slot_id=1;
        block_lane_valid='1; block_score_bf16=v; #1;
        if(block_ready || store_wr_valid) $fatal(1,"nonfinite bypassed max pipeline");
        tick();
        if(block_ready || store_wr_valid) $fatal(1,"nonfinite bypassed max pipeline stage 2");
        tick();
        if(!block_ready || store_wr_valid) $fatal(1,"nonfinite was not aborted");
        tick(); @(negedge clk); block_valid=0;
        while(!abort_valid) tick();
        if(abort_error_code!==2 || abort_error_key!==0 || abort_row!==31)
            $fatal(1,"abort payload mismatch");
        repeat(2) begin tick(); if(!abort_valid || abort_error_code!==2 || abort_row!==31)
            $fatal(1,"abort changed while stalled"); end
        @(negedge clk); abort_ready=1; tick();

        $display("PASS: CATS-R4 32-lane max serial-reference equivalence, stalls, last, and abort");
        $finish;
    end
endmodule
