`timescale 1ns/1ps

module tb_cats_r4_qk_row_assembler;
    localparam int LANES = 4;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    logic clear = 0;
    logic counter_clear = 0;

    logic txn_start_valid;
    logic txn_start_ready;
    logic [15:0] txn_epoch;
    logic [1:0] txn_numeric_mode;

    logic row_open_valid;
    logic row_open_ready;
    logic [15:0] row_open_epoch;
    logic [2:0] row_open_group;
    logic [4:0] row_open_global_q_head;
    logic [6:0] row_open_row;
    logic [1:0] row_open_slot_id;
    logic [1:0] row_open_numeric_mode;

    logic block_valid;
    logic block_ready;
    logic [15:0] block_epoch;
    logic [2:0] block_group;
    logic [4:0] block_global_q_head;
    logic [6:0] block_row;
    logic [1:0] block_slot_id;
    logic [1:0] block_numeric_mode;
    logic [1:0] block_key_block;
    logic [LANES-1:0] block_lane_valid;
    logic [LANES*16-1:0] block_score_bf16;

    logic store_wr_valid;
    logic store_wr_ready;
    logic [1:0] store_wr_slot_id;
    logic [6:0] store_wr_key_base;
    logic [LANES-1:0] store_wr_lane_valid;
    logic [LANES*16-1:0] store_wr_score_bf16;

    logic row_valid;
    logic row_ready;
    logic [15:0] row_epoch;
    logic [2:0] row_group;
    logic [4:0] row_global_q_head;
    logic [6:0] row_index;
    logic [1:0] row_slot_id;
    logic [1:0] row_numeric_mode;
    logic [15:0] row_max_bf16;

    logic abort_valid;
    logic abort_ready;
    logic [15:0] abort_epoch;
    logic [2:0] abort_group;
    logic [4:0] abort_global_q_head;
    logic [6:0] abort_row;
    logic [1:0] abort_slot_id;
    logic [1:0] abort_numeric_mode;
    logic [2:0] abort_error_code;
    logic [6:0] abort_error_key;

    logic [63:0] rows_opened;
    logic [63:0] blocks_accepted;
    logic [63:0] scores_accepted;
    logic [63:0] rows_completed;
    logic [63:0] protocol_errors;
    logic [63:0] numeric_errors;
    logic [63:0] mode_errors;
    logic protocol_error_sticky;

    integer watchdog_cycles = 0;

    cats_r4_qk_row_assembler #(
        .SEQ_LEN(8),
        .LANES(LANES),
        .SLOTS(3)
    ) dut (.*);

    always @(posedge clk) begin
        watchdog_cycles <= watchdog_cycles + 1;
        if (watchdog_cycles > 200)
            $fatal(1, "watchdog: txn_active=%b row_open=%b/%b block=%b/%b row=%b/%b",
                   dut.txn_active, row_open_valid, row_open_ready,
                   block_valid, block_ready, row_valid, row_ready);
    end

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic open_row(
        input logic [6:0] r,
        input logic [1:0] slot
    );
        begin
            @(negedge clk);
            row_open_valid = 1;
            row_open_epoch = 16'h1201;
            row_open_group = 0;
            row_open_global_q_head = 0;
            row_open_row = r;
            row_open_slot_id = slot;
            row_open_numeric_mode = 1;
            #1;
            if (!row_open_ready)
                $fatal(1, "legal row open was not accepted row=%0d slot=%0d", r, slot);
            tick();
            @(negedge clk);
            row_open_valid = 0;
        end
    endtask

    task automatic send_block(
        input logic [6:0] r,
        input logic [1:0] slot,
        input logic [1:0] key_block,
        input logic [3:0] lane_valid,
        input logic [63:0] scores
    );
        begin
            @(negedge clk);
            block_valid = 1;
            block_epoch = 16'h1201;
            block_group = 0;
            block_global_q_head = 0;
            block_row = r;
            block_slot_id = slot;
            block_numeric_mode = 1;
            block_key_block = key_block;
            block_lane_valid = lane_valid;
            block_score_bf16 = scores;
            #1;
            while (!block_ready || !store_wr_ready)
                tick();
            tick();
            @(negedge clk);
            block_valid = 0;
        end
    endtask

    initial begin
        txn_start_valid = 0;
        txn_epoch = 16'h1201;
        txn_numeric_mode = 1;
        row_open_valid = 0;
        block_valid = 0;
        store_wr_ready = 1;
        row_ready = 0;
        abort_ready = 1;

        repeat (3) tick();
        rst_n = 1;

        @(negedge clk);
        txn_start_valid = 1;
        tick();
        @(negedge clk);
        txn_start_valid = 0;

        // Mutation caught: ignoring lane_valid would include 2.0/3.0/4.0
        // and produce a max other than the sole legal score 1.0.
        open_row(0, 0);
        send_block(0, 0, 0, 4'b0001,
                   {16'h4080, 16'h4040, 16'h4000, 16'h3f80});

        while (!row_valid) tick();
        if (row_epoch !== 16'h1201 || row_group !== 0 ||
            row_global_q_head !== 0 || row_index !== 0 ||
            row_slot_id !== 0 || row_numeric_mode !== 1 ||
            row_max_bf16 !== 16'h3f80)
            $fatal(1, "row0 descriptor/max mismatch max=%h", row_max_bf16);

        // Mutation caught: a combinational output that follows another slot
        // would change while row_valid is stalled.
        repeat (3) begin
            tick();
            if (!row_valid || row_index !== 0 || row_max_bf16 !== 16'h3f80)
                $fatal(1, "row descriptor changed under backpressure");
        end
        row_ready = 1;
        tick();
        row_ready = 0;

        // All-negative values catch raw-unsigned BF16 max comparisons.
        // The correct numeric maximum is -0.5 (BF00).
        open_row(7, 1);
        send_block(7, 1, 0, 4'b1111,
                   {16'hc040, 16'hbf00, 16'hc000, 16'hbf80});
        send_block(7, 1, 1, 4'b1111,
                   {16'hc100, 16'hc0e0, 16'hc0c0, 16'hc080});

        while (!row_valid) tick();
        if (row_index !== 7 || row_slot_id !== 1 ||
            row_max_bf16 !== 16'hbf00)
            $fatal(1, "negative row max mismatch got=%h", row_max_bf16);
        row_ready = 1;
        tick();

        if (rows_opened !== 2 || blocks_accepted !== 3 ||
            scores_accepted !== 9 || rows_completed !== 2 ||
            protocol_errors !== 0 || numeric_errors !== 0 ||
            mode_errors !== 0 || protocol_error_sticky || abort_valid)
            $fatal(1, "counter/error mismatch open=%0d block=%0d score=%0d row=%0d",
                   rows_opened, blocks_accepted, scores_accepted, rows_completed);

        $display("PASS: CATS-R4 row assembler causal masks, BF16 max, and row backpressure");
        $finish;
    end
endmodule
