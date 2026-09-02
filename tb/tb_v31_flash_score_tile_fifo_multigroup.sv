`timescale 1ns/1ps

module tb_v31_flash_score_tile_fifo_multigroup;
    localparam int TILE = 4;
    localparam int ITEMS = TILE*TILE;
    localparam int SEQ_LEN = 8;
    localparam int Q_HEADS = 2;
    localparam int GQA_GROUPS = 8;
    localparam int TILES_PER_HEAD = (SEQ_LEN/TILE)*(SEQ_LEN/TILE);
    localparam int TILES_PER_GROUP = Q_HEADS*TILES_PER_HEAD;
    localparam int TOTAL_TILES = GQA_GROUPS*TILES_PER_GROUP;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [15:0] in_score;
    logic in_mask;
    logic [2:0] in_group;
    logic in_head;
    logic [2:0] in_row;
    logic [2:0] in_col;
    logic in_last;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [ITEMS*16-1:0] out_scores;
    logic [ITEMS-1:0] out_masks;
    logic [2:0] out_group;
    logic out_head;
    logic [2:0] out_row_base;
    logic [2:0] out_col_base;
    logic out_all_masked;
    logic out_group_last;
    logic busy;
    logic order_error;
    logic [31:0] tiles_enqueued;
    logic [31:0] tiles_dequeued;

    integer seed = 32'h31FA_8008;
    integer output_tile = 0;
    integer timeout_cycles = 0;
    logic producer_done = 1'b0;
    logic stalled = 1'b0;
    logic [ITEMS*16-1:0] stalled_scores;
    logic [ITEMS-1:0] stalled_masks;
    logic [2:0] stalled_group;
    logic stalled_head;
    logic [2:0] stalled_row;
    logic [2:0] stalled_col;
    logic stalled_all_masked;
    logic stalled_group_last;

    always #5 clk = ~clk;

    flash_score_tile_fifo #(
        .TILE(TILE), .DEPTH_TILES(3), .SEQ_LEN(SEQ_LEN),
        .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS)
    ) dut (
        .clk, .rst_n, .clear,
        .in_valid, .in_ready, .in_score, .in_mask,
        .in_group, .in_head, .in_row, .in_col, .in_last,
        .out_valid, .out_ready, .out_scores, .out_masks,
        .out_group, .out_head, .out_row_base, .out_col_base,
        .out_all_masked, .out_group_last,
        .busy, .order_error, .tiles_enqueued, .tiles_dequeued
    );

    function automatic logic [15:0] score_word(
        input integer group_number,
        input integer head_number,
        input integer row_number,
        input integer col_number
    );
        score_word = {group_number[2:0], head_number[0],
                      row_number[2:0], col_number[2:0], 6'h15};
    endfunction

    task automatic send_scalar(
        input integer group_number,
        input integer head_number,
        input integer row_number,
        input integer col_number,
        input logic last_value
    );
        integer gap;
        begin
            gap = $urandom(seed) % 3;
            repeat (gap) @(negedge clk);
            in_score = score_word(group_number, head_number,
                                  row_number, col_number);
            in_mask = (col_number > row_number);
            in_group = group_number[2:0];
            in_head = head_number[0];
            in_row = row_number[2:0];
            in_col = col_number[2:0];
            in_last = last_value;
            in_valid = 1'b1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n)
            out_ready = 1'b0;
        else
            out_ready = (($urandom(seed) % 100) < 61);
    end

    always_ff @(posedge clk) begin : p_monitor
        integer group_number;
        integer group_tile;
        integer head_number;
        integer row_tile;
        integer col_tile;
        integer element;
        integer local_row;
        integer local_col;
        integer absolute_row;
        integer absolute_col;
        logic [15:0] expected_score;
        logic expected_mask;
        logic expected_all_masked;

        if (!rst_n) begin
            output_tile <= 0;
            timeout_cycles <= 0;
            stalled <= 1'b0;
        end else begin
            timeout_cycles <= timeout_cycles + 1;
            if (timeout_cycles > 200000)
                $fatal(1, "multi-group FIFO timeout: output=%0d", output_tile);

            if (stalled) begin
                if (!out_valid || out_scores !== stalled_scores ||
                    out_masks !== stalled_masks || out_group !== stalled_group ||
                    out_head !== stalled_head || out_row_base !== stalled_row ||
                    out_col_base !== stalled_col ||
                    out_all_masked !== stalled_all_masked ||
                    out_group_last !== stalled_group_last)
                    $fatal(1, "FIFO payload changed under backpressure");
            end
            stalled <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                stalled_scores <= out_scores;
                stalled_masks <= out_masks;
                stalled_group <= out_group;
                stalled_head <= out_head;
                stalled_row <= out_row_base;
                stalled_col <= out_col_base;
                stalled_all_masked <= out_all_masked;
                stalled_group_last <= out_group_last;
            end

            if (out_valid && out_ready) begin
                group_number = output_tile / TILES_PER_GROUP;
                group_tile = output_tile % TILES_PER_GROUP;
                head_number = group_tile / TILES_PER_HEAD;
                row_tile = (group_tile % TILES_PER_HEAD) / (SEQ_LEN/TILE);
                col_tile = group_tile % (SEQ_LEN/TILE);
                if (($unsigned(out_group) != group_number) ||
                    ($unsigned(out_head) != head_number) ||
                    ($unsigned(out_row_base) != row_tile*TILE) ||
                    ($unsigned(out_col_base) != col_tile*TILE))
                    $fatal(1, "metadata mismatch at output tile %0d", output_tile);

                expected_all_masked = 1'b1;
                for (element = 0; element < ITEMS; element = element + 1) begin
                    local_row = element / TILE;
                    local_col = element % TILE;
                    absolute_row = row_tile*TILE + local_row;
                    absolute_col = col_tile*TILE + local_col;
                    expected_score = score_word(group_number, head_number,
                                                absolute_row, absolute_col);
                    expected_mask = (absolute_col > absolute_row);
                    if (out_scores[element*16 +: 16] !== expected_score ||
                        out_masks[element] !== expected_mask)
                        $fatal(1, "payload mismatch at tile %0d element %0d",
                               output_tile, element);
                    expected_all_masked = expected_all_masked && expected_mask;
                end
                if (out_all_masked !== expected_all_masked)
                    $fatal(1, "all-masked mismatch at tile %0d", output_tile);
                if (out_group_last !==
                    (group_tile == TILES_PER_GROUP-1))
                    $fatal(1, "group-last mismatch at tile %0d", output_tile);
                output_tile <= output_tile + 1;
            end
        end
    end

    initial begin : p_driver
        integer group_number;
        integer head_number;
        integer row_base;
        integer col_base;
        integer local_row;
        integer local_col;
        logic last_value;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        for (group_number = 0; group_number < GQA_GROUPS;
             group_number = group_number + 1)
            for (head_number = 0; head_number < Q_HEADS;
                 head_number = head_number + 1)
                for (row_base = 0; row_base < SEQ_LEN;
                     row_base = row_base + TILE)
                    for (col_base = 0; col_base < SEQ_LEN;
                         col_base = col_base + TILE)
                        for (local_row = 0; local_row < TILE;
                             local_row = local_row + 1)
                            for (local_col = 0; local_col < TILE;
                                 local_col = local_col + 1) begin
                                last_value =
                                    (head_number == Q_HEADS-1) &&
                                    (row_base+local_row == SEQ_LEN-1) &&
                                    (col_base+local_col == SEQ_LEN-1);
                                send_scalar(group_number, head_number,
                                            row_base+local_row,
                                            col_base+local_col, last_value);
                            end
        producer_done = 1'b1;
    end

    initial begin : p_finish
        wait (producer_done && (output_tile == TOTAL_TILES));
        repeat (5) @(posedge clk);
        if (order_error)
            $fatal(1, "legal per-group score_last raised order_error");
        if (tiles_enqueued != TOTAL_TILES ||
            tiles_dequeued != TOTAL_TILES || busy)
            $fatal(1, "counter/busy mismatch: enq=%0d deq=%0d busy=%0b",
                   tiles_enqueued, tiles_dequeued, busy);
        $display("FLASH_SCORE_TILE_FIFO_MULTIGROUP_TEST: PASS groups=%0d tiles=%0d",
                 GQA_GROUPS, TOTAL_TILES);
        $finish;
    end
endmodule
