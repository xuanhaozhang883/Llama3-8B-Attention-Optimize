`timescale 1ns/1ps

module tb_v31_flash_score_tile_fifo;
    localparam int TILE = 2;
    localparam int ITEMS = TILE*TILE;
    localparam int TILE_COUNT = 8;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    always #5 clk = ~clk;

    logic in_valid;
    logic in_ready;
    logic [15:0] in_score;
    logic in_mask;
    logic [0:0] in_group;
    logic [0:0] in_head;
    logic [2:0] in_row;
    logic [2:0] in_col;
    logic in_last;

    logic out_valid;
    logic out_ready;
    logic [ITEMS*16-1:0] out_scores;
    logic [ITEMS-1:0] out_masks;
    logic [0:0] out_group;
    logic [0:0] out_head;
    logic [2:0] out_row_base;
    logic [2:0] out_col_base;
    logic out_all_masked;
    logic out_group_last;
    logic busy;
    logic order_error;
    logic [31:0] tiles_enqueued;
    logic [31:0] tiles_dequeued;

    integer cycle_count = 0;
    integer output_count = 0;
    integer seed = 32'h31415926;
    logic stalled_last_cycle = 1'b0;
    logic [ITEMS*16-1:0] stalled_scores;
    logic [ITEMS-1:0] stalled_masks;
    logic [0:0] stalled_group;
    logic [0:0] stalled_head;
    logic [2:0] stalled_row;
    logic [2:0] stalled_col;
    logic stalled_all_masked;
    logic stalled_group_last;

    flash_score_tile_fifo #(
        .TILE(TILE),
        .DEPTH_TILES(3),
        .SEQ_LEN(8),
        .Q_HEADS(2),
        .GQA_GROUPS(2),
        .HEAD_W(1),
        .GROUP_W(1),
        .POS_W(3)
    ) dut (
        .clk, .rst_n, .clear,
        .in_valid, .in_ready, .in_score, .in_mask,
        .in_group, .in_head, .in_row, .in_col, .in_last,
        .out_valid, .out_ready, .out_scores, .out_masks,
        .out_group, .out_head, .out_row_base, .out_col_base,
        .out_all_masked, .out_group_last,
        .busy, .order_error, .tiles_enqueued, .tiles_dequeued
    );

    function automatic integer tile_group(input integer index);
        begin
            case (index)
                0,1,2: tile_group = 0;
                default: tile_group = 1;
            endcase
        end
    endfunction

    function automatic integer tile_head(input integer index);
        begin
            case (index)
                0,1,3: tile_head = 0;
                default: tile_head = 1;
            endcase
        end
    endfunction

    function automatic integer tile_row(input integer index);
        begin
            case (index)
                0,1: tile_row = 0;
                2: tile_row = 2;
                3: tile_row = 4;
                default: tile_row = 6;
            endcase
        end
    endfunction

    function automatic integer tile_col(input integer index);
        begin
            case (index)
                0,2,4: tile_col = 0;
                1,5: tile_col = 2;
                3,6: tile_col = 4;
                default: tile_col = 6;
            endcase
        end
    endfunction

    function automatic logic [15:0] score_word(
        input integer group_number,
        input integer head_number,
        input integer row_number,
        input integer col_number
    );
        begin
            score_word = (group_number << 15) |
                         (head_number << 14) |
                         (row_number << 11) |
                         (col_number << 8) | 16'h005A;
        end
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
            in_group = group_number[0:0];
            in_head = head_number[0:0];
            in_row = row_number[2:0];
            in_col = col_number[2:0];
            in_score = score_word(group_number, head_number,
                                  row_number, col_number);
            in_mask = (col_number > row_number);
            in_last = last_value;
            in_valid = 1'b1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic send_tile(input integer tile_number);
        integer local_row;
        integer local_col;
        integer absolute_row;
        integer absolute_col;
        logic final_scalar;
        begin
            for (local_row = 0; local_row < TILE; local_row = local_row + 1) begin
                for (local_col = 0; local_col < TILE; local_col = local_col + 1) begin
                    absolute_row = tile_row(tile_number) + local_row;
                    absolute_col = tile_col(tile_number) + local_col;
                    final_scalar =
                        (tile_number == TILE_COUNT-1) &&
                        (local_row == TILE-1) &&
                        (local_col == TILE-1);
                    send_scalar(tile_group(tile_number),
                                tile_head(tile_number),
                                absolute_row, absolute_col, final_scalar);
                end
            end
        end
    endtask

    task automatic check_output_tile(input integer tile_number);
        integer local_row;
        integer local_col;
        integer element;
        integer absolute_row;
        integer absolute_col;
        logic expected_mask;
        logic expected_all_masked;
        logic [15:0] expected_score;
        begin
            if (($unsigned(out_group) != tile_group(tile_number)) ||
                ($unsigned(out_head) != tile_head(tile_number)) ||
                ($unsigned(out_row_base) != tile_row(tile_number)) ||
                ($unsigned(out_col_base) != tile_col(tile_number))) begin
                $display("ERROR: tile %0d metadata g/h/r/c=%0d/%0d/%0d/%0d",
                         tile_number, out_group, out_head,
                         out_row_base, out_col_base);
                $fatal(1);
            end

            expected_all_masked = 1'b1;
            for (local_row = 0; local_row < TILE; local_row = local_row + 1) begin
                for (local_col = 0; local_col < TILE; local_col = local_col + 1) begin
                    element = local_row*TILE + local_col;
                    absolute_row = tile_row(tile_number) + local_row;
                    absolute_col = tile_col(tile_number) + local_col;
                    expected_score = score_word(tile_group(tile_number),
                                                tile_head(tile_number),
                                                absolute_row, absolute_col);
                    expected_mask = (absolute_col > absolute_row);
                    expected_all_masked = expected_all_masked && expected_mask;
                    if (out_scores[element*16 +: 16] !== expected_score ||
                        out_masks[element] !== expected_mask) begin
                        $display("ERROR: tile %0d element %0d score/mask=%h/%0b expected=%h/%0b",
                                 tile_number, element,
                                 out_scores[element*16 +: 16], out_masks[element],
                                 expected_score, expected_mask);
                        $fatal(1);
                    end
                end
            end

            if (out_all_masked !== expected_all_masked) begin
                $display("ERROR: tile %0d all_masked=%0b expected=%0b",
                         tile_number, out_all_masked, expected_all_masked);
                $fatal(1);
            end
            if (out_group_last !== (tile_number == TILE_COUNT-1)) begin
                $display("ERROR: tile %0d group_last=%0b",
                         tile_number, out_group_last);
                $fatal(1);
            end
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n || clear || cycle_count < 80)
            out_ready = 1'b0;
        else
            out_ready = (($urandom(seed) % 100) < 65);
    end

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > 10000) begin
            $display("ERROR: timeout input_tiles=%0d output_tiles=%0d",
                     tiles_enqueued, output_count);
            $fatal(1);
        end

        if (stalled_last_cycle) begin
            if (!out_valid || out_scores !== stalled_scores ||
                out_masks !== stalled_masks || out_group !== stalled_group ||
                out_head !== stalled_head || out_row_base !== stalled_row ||
                out_col_base !== stalled_col ||
                out_all_masked !== stalled_all_masked ||
                out_group_last !== stalled_group_last) begin
                $display("ERROR: output payload changed while stalled");
                $fatal(1);
            end
        end

        stalled_last_cycle <= out_valid && !out_ready;
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
            check_output_tile(output_count);
            output_count <= output_count + 1;
        end
    end

    initial begin
        in_valid = 1'b0;
        in_score = '0;
        in_mask = 1'b0;
        in_group = '0;
        in_head = '0;
        in_row = '0;
        in_col = '0;
        in_last = 1'b0;
        out_ready = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        for (integer tile_number = 0;
             tile_number < TILE_COUNT;
             tile_number = tile_number + 1)
            send_tile(tile_number);

        wait (output_count == TILE_COUNT);
        @(posedge clk);
        if (tiles_enqueued != TILE_COUNT ||
            tiles_dequeued != TILE_COUNT || busy || order_error) begin
            $display("ERROR: final counters enq/deq=%0d/%0d busy=%0b order_error=%0b",
                     tiles_enqueued, tiles_dequeued, busy, order_error);
            $fatal(1);
        end

        // The detector must reject a tile that does not start at local (0,0).
        clear = 1'b1;
        @(posedge clk);
        clear = 1'b0;
        @(negedge clk);
        in_group = 0;
        in_head = 0;
        in_row = 1;
        in_col = 0;
        in_score = 16'h1234;
        in_mask = 0;
        in_last = 0;
        in_valid = 1;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 0;
        @(posedge clk);
        if (!order_error) begin
            $display("ERROR: malformed tile was not detected");
            $fatal(1);
        end

        $display("FLASH_SCORE_TILE_FIFO_TEST: PASS tiles=%0d", TILE_COUNT);
        $finish;
    end
endmodule
