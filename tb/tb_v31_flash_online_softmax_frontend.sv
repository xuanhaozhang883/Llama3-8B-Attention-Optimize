`timescale 1ns/1ps

module tb_v31_flash_online_softmax_frontend;
    localparam int TILE = 4;
    localparam int SEQ_LEN = 8;
    localparam int L_W = 16 + $clog2(SEQ_LEN+1);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    always #5 clk = ~clk;

    logic in_valid;
    logic in_ready;
    logic [TILE*TILE*16-1:0] in_scores_bf16;
    logic [TILE*TILE-1:0] in_masks;
    logic [0:0] in_group;
    logic [0:0] in_head;
    logic [2:0] in_row_base;
    logic [2:0] in_col_base;
    logic in_group_last;
    logic out_valid;
    logic out_ready;
    logic [TILE*TILE*16-1:0] out_weights_q15;
    logic [TILE*16-1:0] out_alpha_q15;
    logic [TILE*L_W-1:0] out_l_q15;
    logic [TILE-1:0] out_row_active;
    logic [0:0] out_group;
    logic [0:0] out_head;
    logic [2:0] out_row_base;
    logic [2:0] out_col_base;
    logic out_row_tile_last;
    logic out_group_last;
    logic busy;
    logic protocol_error;
    logic [31:0] tiles_processed;

    logic [15:0] exp_mem [0:512];
    integer output_index = 0;
    integer seed = 32'h51A7C0DE;
    integer cycles = 0;
    logic stalled = 1'b0;
    logic [TILE*TILE*16-1:0] held_weights;
    logic [TILE*16-1:0] held_alpha;
    logic [TILE*L_W-1:0] held_l;
    logic [20:0] expected_l;
    integer r;
    integer c;
    integer item;

    initial $readmemh("mem/exp_lut_q15.mem", exp_mem);

    flash_online_softmax_frontend #(
        .TILE(TILE), .SEQ_LEN(SEQ_LEN), .Q_HEADS(2), .GQA_GROUPS(2),
        .HEAD_W(1), .GROUP_W(1), .POS_W(3), .L_W(L_W),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n, .clear,
        .in_valid, .in_ready, .in_scores_bf16, .in_masks,
        .in_group, .in_head, .in_row_base, .in_col_base, .in_group_last,
        .out_valid, .out_ready, .out_weights_q15, .out_alpha_q15,
        .out_l_q15, .out_row_active, .out_group, .out_head,
        .out_row_base, .out_col_base, .out_row_tile_last,
        .out_group_last, .busy, .protocol_error, .tiles_processed
    );

    function automatic logic tile_mask(
        input integer tile_index, input integer row_index, input integer col_index
    );
        begin
            case (tile_index)
                0: tile_mask = (col_index > row_index);
                1: tile_mask = 1'b1;
                2: tile_mask = 1'b0;
                default: tile_mask = (col_index > row_index);
            endcase
        end
    endfunction

    task automatic send_tile(input integer tile_index);
        integer tr;
        integer tc;
        integer ti;
        begin
            @(negedge clk);
            in_scores_bf16 = '0;
            in_masks = '0;
            for (tr = 0; tr < TILE; tr = tr + 1) begin
                for (tc = 0; tc < TILE; tc = tc + 1) begin
                    ti = tr*TILE+tc;
                    in_scores_bf16[ti*16 +: 16] =
                        (tile_index == 3) ? 16'h3F80 : 16'h0000;
                    in_masks[ti] = tile_mask(tile_index, tr, tc);
                end
            end
            in_row_base = (tile_index < 2) ? 0 : 4;
            in_col_base = (tile_index & 1) ? 4 : 0;
            in_group_last = (tile_index == 3);
            in_valid = 1'b1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            out_ready <= 1'b0;
            cycles <= 0;
            stalled <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            out_ready <= (($urandom(seed) % 4) != 0);
            if (cycles > 1000)
                $fatal(1, "frontend timeout");

            if (stalled) begin
                if (!out_valid || out_weights_q15 !== held_weights ||
                    out_alpha_q15 !== held_alpha || out_l_q15 !== held_l)
                    $fatal(1, "output changed while stalled");
            end
            stalled <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                held_weights <= out_weights_q15;
                held_alpha <= out_alpha_q15;
                held_l <= out_l_q15;
            end

            if (out_valid && out_ready) begin
                if (out_group !== 0 || out_head !== 0)
                    $fatal(1, "metadata group/head mismatch");
                if (out_row_base !== ((output_index < 2) ? 0 : 4) ||
                    out_col_base !== ((output_index & 1) ? 4 : 0))
                    $fatal(1, "metadata row/col mismatch tile=%0d", output_index);
                if (out_row_tile_last !== (output_index & 1))
                    $fatal(1, "row_tile_last mismatch tile=%0d", output_index);
                if (out_group_last !== (output_index == 3))
                    $fatal(1, "group_last mismatch tile=%0d", output_index);
                if (out_row_active !== 4'hF)
                    $fatal(1, "row_active mismatch tile=%0d", output_index);

                for (r = 0; r < TILE; r = r + 1) begin
                    case (output_index)
                        0: expected_l = (r+1)*32768;
                        1: expected_l = (r+1)*32768;
                        2: expected_l = 4*32768;
                        default: expected_l = 4*exp_mem[64] + (r+1)*32768;
                    endcase
                    if (out_l_q15[r*L_W +: L_W] !== expected_l[L_W-1:0])
                        $fatal(1, "l mismatch tile=%0d row=%0d got=%0h exp=%0h",
                               output_index, r, out_l_q15[r*L_W +: L_W],
                               expected_l[L_W-1:0]);
                    if (out_alpha_q15[r*16 +: 16] !==
                        ((output_index == 0 || output_index == 2) ?
                         16'h0000 :
                         ((output_index == 3) ? exp_mem[64] : 16'h8000)))
                        $fatal(1, "alpha mismatch tile=%0d row=%0d",
                               output_index, r);
                    for (c = 0; c < TILE; c = c + 1) begin
                        item = r*TILE+c;
                        if (out_weights_q15[item*16 +: 16] !==
                            (tile_mask(output_index, r, c) ? 16'h0000 : 16'h8000))
                            $fatal(1, "weight mismatch tile=%0d row=%0d col=%0d",
                                   output_index, r, c);
                    end
                end
                output_index <= output_index + 1;
            end
        end
    end

    initial begin
        in_valid = 1'b0;
        in_scores_bf16 = '0;
        in_masks = '0;
        in_group = '0;
        in_head = '0;
        in_row_base = '0;
        in_col_base = '0;
        in_group_last = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        send_tile(0);
        send_tile(1);
        send_tile(2);
        send_tile(3);
        wait (output_index == 4);
        repeat (3) @(posedge clk);
        if (protocol_error)
            $fatal(1, "unexpected protocol_error");
        if (tiles_processed != 4)
            $fatal(1, "tiles_processed mismatch: %0d", tiles_processed);
        $display("FLASH_ONLINE_SOFTMAX_FRONTEND_TEST: PASS tiles=%0d", output_index);
        $finish;
    end
endmodule
