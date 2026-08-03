`timescale 1ns/1ps

module tb_v31_flash_score_tile_fifo;
    localparam int TILE        = 4;
    localparam int ITEMS       = TILE*TILE;
    localparam int FIFO_DEPTH  = 3;
    localparam int HEAD_W      = 3;
    localparam int POS_W       = 6;
    localparam int TOTAL_TILES = 40;
    localparam int TOTAL_ITEMS = TOTAL_TILES*ITEMS;

    logic clk;
    logic rst_n;
    logic status_clear;
    logic in_valid;
    logic in_ready;
    logic [15:0] in_score_bf16;
    logic [HEAD_W-1:0] in_score_head;
    logic [POS_W-1:0] in_score_row;
    logic [POS_W-1:0] in_score_col;
    logic in_score_last;
    logic out_valid;
    logic out_ready;
    logic [15:0] out_score_bf16;
    logic [HEAD_W-1:0] out_score_head;
    logic [POS_W-1:0] out_score_row;
    logic [POS_W-1:0] out_score_col;
    logic out_score_last;
    logic busy;
    logic [31:0] tiles_enqueued;
    logic [31:0] tiles_dequeued;
    logic [31:0] input_backpressure_cycles;
    logic [7:0] occupancy;
    logic [7:0] max_occupancy;
    logic protocol_error;

    integer failures;
    integer output_index;
    integer random_seed;
    integer random_value;
    integer timeout_cycles;
    logic random_consumer;
    logic held_valid;
    logic [15:0] held_bf16;
    logic [HEAD_W-1:0] held_head;
    logic [POS_W-1:0] held_row;
    logic [POS_W-1:0] held_col;
    logic held_last;
    logic expect_no_bubble;

    flash_score_tile_fifo #(
        .TILE(TILE),
        .FIFO_DEPTH(FIFO_DEPTH),
        .HEAD_W(HEAD_W),
        .POS_W(POS_W)
    ) dut (
        .clk,
        .rst_n,
        .status_clear,
        .in_valid,
        .in_ready,
        .in_score_bf16,
        .in_score_head,
        .in_score_row,
        .in_score_col,
        .in_score_last,
        .out_valid,
        .out_ready,
        .out_score_bf16,
        .out_score_head,
        .out_score_row,
        .out_score_col,
        .out_score_last,
        .busy,
        .tiles_enqueued,
        .tiles_dequeued,
        .input_backpressure_cycles,
        .occupancy,
        .max_occupancy,
        .protocol_error
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic [15:0] expected_bf16(input integer item_index);
        expected_bf16 = 16'h2000 + item_index[15:0];
    endfunction

    function automatic [HEAD_W-1:0] expected_head(
        input integer item_index
    );
        integer tile_index;
        begin
            tile_index = item_index / ITEMS;
            expected_head = tile_index / 16;
        end
    endfunction

    function automatic [POS_W-1:0] expected_row(
        input integer item_index
    );
        integer tile_index;
        integer local_index;
        integer row_base;
        begin
            tile_index = item_index / ITEMS;
            local_index = item_index % ITEMS;
            row_base = ((tile_index / 4) % 4)*TILE;
            expected_row = row_base + (local_index / TILE);
        end
    endfunction

    function automatic [POS_W-1:0] expected_col(
        input integer item_index
    );
        integer tile_index;
        integer local_index;
        integer col_base;
        begin
            tile_index = item_index / ITEMS;
            local_index = item_index % ITEMS;
            col_base = (tile_index % 4)*TILE;
            expected_col = col_base + (local_index % TILE);
        end
    endfunction

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            status_clear = 1'b0;
            in_valid = 1'b0;
            out_ready = 1'b0;
            random_consumer = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task automatic send_item(input integer item_index);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_score_bf16 = expected_bf16(item_index);
            in_score_head = expected_head(item_index);
            in_score_row = expected_row(item_index);
            in_score_col = expected_col(item_index);
            in_score_last = (item_index == TOTAL_ITEMS-1);

            do begin
                @(posedge clk);
            end while (!in_ready);

            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && random_consumer) begin
            random_value = $urandom(random_seed);
            out_ready = ((random_value % 4) != 0);
        end
    end

    always @(posedge clk) begin
        integer expected_local;
        if (!rst_n) begin
            output_index = 0;
            held_valid = 1'b0;
            expect_no_bubble = 1'b0;
        end else begin
            if (expect_no_bubble) begin
                if (!out_valid) begin
                    $error("FIFO inserted a bubble between committed tiles");
                    failures = failures + 1;
                end
                expect_no_bubble = 1'b0;
            end

            if (held_valid) begin
                if (!out_valid ||
                    (out_score_bf16 !== held_bf16) ||
                    (out_score_head !== held_head) ||
                    (out_score_row !== held_row) ||
                    (out_score_col !== held_col) ||
                    (out_score_last !== held_last)) begin
                    $error("Output payload changed during backpressure");
                    failures = failures + 1;
                end
            end

            held_valid = out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                held_bf16 = out_score_bf16;
                held_head = out_score_head;
                held_row = out_score_row;
                held_col = out_score_col;
                held_last = out_score_last;
            end

            if (out_valid && out_ready) begin
                if (out_score_bf16 !== expected_bf16(output_index) ||
                    out_score_head !== expected_head(output_index) ||
                    out_score_row !== expected_row(output_index) ||
                    out_score_col !== expected_col(output_index) ||
                    out_score_last !== (output_index == TOTAL_ITEMS-1)) begin
                    $error("Output mismatch at scalar %0d", output_index);
                    failures = failures + 1;
                end

                expected_local = output_index % ITEMS;
                if ((expected_local == ITEMS-1) && (occupancy > 1))
                    expect_no_bubble = 1'b1;
                output_index = output_index + 1;
            end

            if (occupancy > FIFO_DEPTH) begin
                $error("FIFO occupancy exceeded depth");
                failures = failures + 1;
            end
        end
    end

    initial begin : TEST_SEQUENCE
        integer item;
        integer pass_fd;

        rst_n = 1'b0;
        status_clear = 1'b0;
        in_valid = 1'b0;
        in_score_bf16 = '0;
        in_score_head = '0;
        in_score_row = '0;
        in_score_col = '0;
        in_score_last = 1'b0;
        out_ready = 1'b0;
        random_consumer = 1'b0;
        random_seed = 32'h31F1_0001;
        failures = 0;

        // Phase 1: a half-filled tile must remain invisible downstream.
        reset_dut();
        for (item = 0; item < ITEMS/2; item = item + 1)
            send_item(item);
        repeat (4) begin
            @(posedge clk);
            if (out_valid) begin
                $error("Partial tile became visible downstream");
                failures = failures + 1;
            end
        end
        for (item = ITEMS/2; item < ITEMS; item = item + 1)
            send_item(item);
        wait (out_valid);
        @(negedge clk);
        out_ready = 1'b1;
        timeout_cycles = 0;
        while ((output_index < ITEMS) && (timeout_cycles < 200)) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        // Sample counters after the final transfer's nonblocking assignments
        // have committed. This avoids simulator-dependent active/NBA ordering.
        @(negedge clk);
        if (output_index != ITEMS || tiles_enqueued != 1 ||
            tiles_dequeued != 1 || busy) begin
            $error("Partial-tile phase did not drain exactly one tile");
            failures = failures + 1;
        end

        // Per-group status can be cleared without resetting FIFO pointers.
        @(negedge clk);
        status_clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        status_clear = 1'b0;
        if (tiles_enqueued != 0 || tiles_dequeued != 0 ||
            max_occupancy != 0 || protocol_error) begin
            $error("status_clear did not reset idle per-group status");
            failures = failures + 1;
        end

        // Phase 2: fill a non-power-of-two FIFO, force input backpressure,
        // then run producer and consumer concurrently with random stalls.
        reset_dut();
        for (item = 0; item < FIFO_DEPTH*ITEMS; item = item + 1)
            send_item(item);
        @(posedge clk);
        if (occupancy != FIFO_DEPTH || in_ready) begin
            $error("FIFO did not report full after %0d tiles", FIFO_DEPTH);
            failures = failures + 1;
        end

        fork
            begin
                repeat (6) @(posedge clk);
                random_consumer = 1'b1;
            end
            begin
                for (item = FIFO_DEPTH*ITEMS;
                     item < TOTAL_ITEMS; item = item + 1)
                    send_item(item);
            end
        join
        in_valid = 1'b0;

        timeout_cycles = 0;
        while ((output_index < TOTAL_ITEMS) &&
               (timeout_cycles < 20000)) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        random_consumer = 1'b0;
        @(negedge clk);
        out_ready = 1'b1;
        repeat (3) @(posedge clk);

        if (output_index != TOTAL_ITEMS) begin
            $error("Timeout: output=%0d expected=%0d",
                   output_index, TOTAL_ITEMS);
            failures = failures + 1;
        end
        if (tiles_enqueued != TOTAL_TILES ||
            tiles_dequeued != TOTAL_TILES) begin
            $error("Tile counters mismatch: enq=%0d deq=%0d",
                   tiles_enqueued, tiles_dequeued);
            failures = failures + 1;
        end
        if (occupancy != 0 || busy || max_occupancy != FIFO_DEPTH) begin
            $error("Occupancy metrics mismatch: now=%0d max=%0d busy=%0b",
                   occupancy, max_occupancy, busy);
            failures = failures + 1;
        end
        if (input_backpressure_cycles < 4) begin
            $error("Input backpressure path was not exercised");
            failures = failures + 1;
        end
        if (protocol_error) begin
            $error("FIFO raised protocol_error on a legal stream");
            failures = failures + 1;
        end

        // Phase 3: prove the sticky coordinate checker catches a malformed
        // tile before it can be mistaken for a legal integration stream.
        reset_dut();
        @(negedge clk);
        in_valid = 1'b1;
        in_score_bf16 = 16'h3F80;
        in_score_head = '0;
        in_score_row = 1;
        in_score_col = 0;
        in_score_last = 1'b0;
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
        if (!protocol_error) begin
            $error("Malformed tile origin did not raise protocol_error");
            failures = failures + 1;
        end

        if (failures == 0) begin
            $display("V31_FLASH_SCORE_TILE_FIFO_TEST: PASS");
            pass_fd = $fopen("v31_flash_score_fifo_pass.txt", "w");
            if (pass_fd != 0) begin
                $fdisplay(pass_fd,
                    "V3.1 Score Tile FIFO: PASS tiles=%0d depth=%0d",
                    TOTAL_TILES, FIFO_DEPTH);
                $fclose(pass_fd);
            end
        end else begin
            $fatal(1, "V31_FLASH_SCORE_TILE_FIFO_TEST: FAIL count=%0d",
                   failures);
        end
        $finish;
    end
endmodule
