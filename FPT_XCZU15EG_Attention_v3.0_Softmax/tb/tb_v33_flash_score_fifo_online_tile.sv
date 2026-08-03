`timescale 1ns/1ps

module tb_v33_flash_score_fifo_online_tile;
    localparam integer TILE = 4;
    localparam integer SCORE_W = 24;
    localparam integer EXP_W = 24;
    localparam integer L_SUM_W = 32;
    localparam integer MAX_CASES = 256;

    logic clk;
    logic rst_n;
    logic state_clear;
    logic state_clear_ready;
    logic state_clear_busy;
    logic state_clear_done;
    logic status_clear;
    logic score_valid;
    logic score_ready;
    logic [15:0] score_bf16;
    logic [1:0] score_head;
    logic [6:0] score_row;
    logic [6:0] score_col;
    logic score_last;
    logic tile_valid;
    logic tile_ready;
    logic [1:0] tile_head;
    logic [6:0] tile_row_base;
    logic [6:0] tile_col_base;
    logic tile_last;
    logic [3:0] tile_state_valid;
    logic [95:0] tile_m_fixed;
    logic [127:0] tile_l_q23;
    logic [95:0] tile_alpha_q23;
    logic [63:0] tile_alpha_q15;
    logic [63:0] tile_alpha_bf16;
    logic [383:0] tile_weights_q23;
    logic [255:0] tile_weights_q15;
    logic [255:0] tile_weights_bf16;
    logic [127:0] tile_row_sum_q23;
    logic [3:0] tile_all_masked_rows;
    logic [3:0] tile_numeric_error;
    logic busy;
    logic [31:0] tiles_assembled;
    logic [31:0] tiles_emitted;
    logic [31:0] input_backpressure_cycles;
    logic [1:0] buffered_tiles;
    logic [1:0] max_buffered_tiles;
    logic protocol_error;

    integer vector_id [0:MAX_CASES-1];
    logic vec_group_start [0:MAX_CASES-1];
    logic [1:0] vec_head [0:MAX_CASES-1];
    logic [6:0] vec_row_base [0:MAX_CASES-1];
    logic [6:0] vec_col_base [0:MAX_CASES-1];
    logic vec_last [0:MAX_CASES-1];
    logic [255:0] vec_scores [0:MAX_CASES-1];
    logic [15:0] vec_mask [0:MAX_CASES-1];
    logic [3:0] vec_state_valid [0:MAX_CASES-1];
    logic [95:0] vec_m_fixed [0:MAX_CASES-1];
    logic [127:0] vec_l_q23 [0:MAX_CASES-1];
    logic [95:0] vec_alpha_q23 [0:MAX_CASES-1];
    logic [63:0] vec_alpha_q15 [0:MAX_CASES-1];
    logic [63:0] vec_alpha_bf16 [0:MAX_CASES-1];
    logic [383:0] vec_weights_q23 [0:MAX_CASES-1];
    logic [255:0] vec_weights_q15 [0:MAX_CASES-1];
    logic [255:0] vec_weights_bf16 [0:MAX_CASES-1];
    logic [127:0] vec_row_sum_q23 [0:MAX_CASES-1];
    logic [3:0] vec_all_masked [0:MAX_CASES-1];
    logic [3:0] vec_numeric_error [0:MAX_CASES-1];

    integer case_count;
    integer received_count;
    integer vector_fd;
    integer marker_fd;
    integer scan_count;
    integer case_index;
    integer item_index;
    integer accepted;
    string vector_file;
    string marker_file;

    logic [15:0] ready_lfsr;
    logic [6:0] ready_cycle;
    logic stall_active;
    logic [1:0] stall_head;
    logic [6:0] stall_row_base;
    logic [6:0] stall_col_base;
    logic stall_last;
    logic [3:0] stall_state_valid;
    logic [95:0] stall_m_fixed;
    logic [127:0] stall_l_q23;
    logic [95:0] stall_alpha_q23;
    logic [383:0] stall_weights_q23;

    flash_score_fifo_online_tile #(
        .TILE(4),
        .SEQ_LEN(128),
        .Q_HEADS(4),
        .HEAD_W(2),
        .POS_W(7),
        .CAUSAL(1),
        .EXP_LUT_FILE("exp_lut_q23.mem")
    ) dut (
        .clk,
        .rst_n,
        .state_clear,
        .state_clear_ready,
        .state_clear_busy,
        .state_clear_done,
        .status_clear,
        .score_valid,
        .score_ready,
        .score_bf16,
        .score_head,
        .score_row,
        .score_col,
        .score_last,
        .tile_valid,
        .tile_ready,
        .tile_head,
        .tile_row_base,
        .tile_col_base,
        .tile_last,
        .tile_state_valid,
        .tile_m_fixed,
        .tile_l_q23,
        .tile_alpha_q23,
        .tile_alpha_q15,
        .tile_alpha_bf16,
        .tile_weights_q23,
        .tile_weights_q15,
        .tile_weights_bf16,
        .tile_row_sum_q23,
        .tile_all_masked_rows,
        .tile_numeric_error,
        .busy,
        .tiles_assembled,
        .tiles_emitted,
        .input_backpressure_cycles,
        .buffered_tiles,
        .max_buffered_tiles,
        .protocol_error
    );

    initial clk = 1'b0;
    always #3.333 clk = ~clk;

    initial begin
        if (!$value$plusargs("VECTORS=%s", vector_file))
            vector_file = "v33_online_tile_vectors.txt";
        if (!$value$plusargs("MARKER=%s", marker_file))
            marker_file = "v33_online_tile_pass.txt";

        case_count = 0;
        received_count = 0;
        vector_fd = $fopen(vector_file, "r");
        if (vector_fd == 0)
            $fatal(1, "cannot open vector file: %s", vector_file);

        while (!$feof(vector_fd)) begin
            if (case_count >= MAX_CASES)
                $fatal(1, "too many Stage 2B vectors");
            scan_count = $fscanf(
                vector_fd,
                "%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                vector_id[case_count],
                vec_group_start[case_count],
                vec_head[case_count],
                vec_row_base[case_count],
                vec_col_base[case_count],
                vec_last[case_count],
                vec_scores[case_count],
                vec_mask[case_count],
                vec_state_valid[case_count],
                vec_m_fixed[case_count],
                vec_l_q23[case_count],
                vec_alpha_q23[case_count],
                vec_alpha_q15[case_count],
                vec_alpha_bf16[case_count],
                vec_weights_q23[case_count],
                vec_weights_q15[case_count],
                vec_weights_bf16[case_count],
                vec_row_sum_q23[case_count],
                vec_all_masked[case_count],
                vec_numeric_error[case_count]
            );
            if (scan_count == 20)
                case_count = case_count + 1;
            else if (scan_count != -1)
                $fatal(1, "malformed vector near case %0d (%0d fields)",
                       case_count, scan_count);
        end
        $fclose(vector_fd);
        if (case_count < 2)
            $fatal(1, "too few Stage 2B vectors");
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            ready_lfsr <= 16'h1ace;
            ready_cycle <= '0;
            tile_ready <= 1'b0;
        end else begin
            ready_lfsr <= {ready_lfsr[14:0],
                ready_lfsr[15] ^ ready_lfsr[13] ^
                ready_lfsr[12] ^ ready_lfsr[10]};
            ready_cycle <= ready_cycle + 1'b1;
            if ((ready_cycle >= 7'd48) &&
                (ready_cycle < 7'd88))
                tile_ready <= 1'b0;
            else
                tile_ready <= ready_lfsr[0] | ready_lfsr[3];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            stall_active <= 1'b0;
        end else if (tile_valid && !tile_ready) begin
            if (!stall_active) begin
                stall_active <= 1'b1;
                stall_head <= tile_head;
                stall_row_base <= tile_row_base;
                stall_col_base <= tile_col_base;
                stall_last <= tile_last;
                stall_state_valid <= tile_state_valid;
                stall_m_fixed <= tile_m_fixed;
                stall_l_q23 <= tile_l_q23;
                stall_alpha_q23 <= tile_alpha_q23;
                stall_weights_q23 <= tile_weights_q23;
            end else if ((tile_head !== stall_head) ||
                         (tile_row_base !== stall_row_base) ||
                         (tile_col_base !== stall_col_base) ||
                         (tile_last !== stall_last) ||
                         (tile_state_valid !== stall_state_valid) ||
                         (tile_m_fixed !== stall_m_fixed) ||
                         (tile_l_q23 !== stall_l_q23) ||
                         (tile_alpha_q23 !== stall_alpha_q23) ||
                         (tile_weights_q23 !== stall_weights_q23)) begin
                $fatal(1, "tile payload changed under backpressure");
            end
        end else begin
            stall_active <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n && tile_valid && tile_ready) begin
            if (received_count >= case_count)
                $fatal(1, "unexpected extra output tile");
            if (tile_head !== vec_head[received_count] ||
                tile_row_base !== vec_row_base[received_count] ||
                tile_col_base !== vec_col_base[received_count] ||
                tile_last !== vec_last[received_count])
                $fatal(1, "metadata mismatch at case %0d", received_count);
            if (tile_state_valid !== vec_state_valid[received_count])
                $fatal(1, "state-valid mismatch at case %0d", received_count);
            if (tile_m_fixed !== vec_m_fixed[received_count])
                $fatal(1, "m mismatch at case %0d", received_count);
            if (tile_l_q23 !== vec_l_q23[received_count])
                $fatal(1, "l mismatch at case %0d", received_count);
            if (tile_alpha_q23 !== vec_alpha_q23[received_count] ||
                tile_alpha_q15 !== vec_alpha_q15[received_count] ||
                tile_alpha_bf16 !== vec_alpha_bf16[received_count])
                $fatal(1, "alpha mismatch at case %0d", received_count);
            if (tile_weights_q23 !== vec_weights_q23[received_count] ||
                tile_weights_q15 !== vec_weights_q15[received_count] ||
                tile_weights_bf16 !== vec_weights_bf16[received_count])
                $fatal(1, "P tile mismatch at case %0d", received_count);
            if (tile_row_sum_q23 !== vec_row_sum_q23[received_count])
                $fatal(1, "row sum mismatch at case %0d", received_count);
            if (tile_all_masked_rows !== vec_all_masked[received_count])
                $fatal(1, "all-masked mismatch at case %0d", received_count);
            if (tile_numeric_error !== vec_numeric_error[received_count])
                $fatal(1, "numeric-error mismatch at case %0d", received_count);
            received_count <= received_count + 1;
        end
    end

    initial begin
        rst_n = 1'b0;
        state_clear = 1'b0;
        status_clear = 1'b0;
        score_valid = 1'b0;
        score_bf16 = '0;
        score_head = '0;
        score_row = '0;
        score_col = '0;
        score_last = 1'b0;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (state_clear_done === 1'b1);

        for (case_index = 0; case_index < case_count;
             case_index = case_index + 1) begin
            if (vec_group_start[case_index] && (case_index != 0)) begin
                wait (received_count == case_index);
                wait (state_clear_ready === 1'b1);
                @(negedge clk);
                state_clear = 1'b1;
                @(negedge clk);
                state_clear = 1'b0;
                wait (state_clear_busy === 1'b1);
                wait (state_clear_done === 1'b1);
            end

            for (item_index = 0; item_index < TILE*TILE;
                 item_index = item_index + 1) begin
                @(negedge clk);
                score_valid = 1'b1;
                score_bf16 =
                    vec_scores[case_index][item_index*16 +: 16];
                score_head = vec_head[case_index];
                score_row = vec_row_base[case_index] +
                            (item_index/TILE);
                score_col = vec_col_base[case_index] +
                            (item_index%TILE);
                score_last = vec_last[case_index] &&
                             (item_index == TILE*TILE-1);
                accepted = 0;
                while (accepted == 0) begin
                    @(posedge clk);
                    if (score_ready)
                        accepted = 1;
                end
            end
        end

        @(negedge clk);
        score_valid = 1'b0;
        score_last = 1'b0;
        wait (received_count == case_count);
        repeat (20) @(posedge clk);

        if (protocol_error)
            $fatal(1, "adapter reported protocol_error");
        if (tiles_assembled !== case_count ||
            tiles_emitted !== case_count)
            $fatal(1, "tile counters mismatch: assembled=%0d emitted=%0d",
                   tiles_assembled, tiles_emitted);
        if (busy)
            $fatal(1, "adapter remained busy after final output");
        if (max_buffered_tiles != 2)
            $fatal(1, "both ping-pong tile slots were not exercised");

        marker_fd = $fopen(marker_file, "w");
        if (marker_fd == 0)
            $fatal(1, "cannot create marker file: %s", marker_file);
        $fdisplay(marker_fd, "V33_FLASH_SCORE_FIFO_ONLINE_TILE: PASS");
        $fclose(marker_fd);
        $display("============================================================");
        $display("V33_FLASH_SCORE_FIFO_ONLINE_TILE_TEST: PASS");
        $display("Tiles: %0d, input backpressure cycles: %0d",
                 case_count, input_backpressure_cycles);
        $display("Maximum assembled-tile buffering: %0d",
                 max_buffered_tiles);
        $display("============================================================");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "Stage 2B test timeout");
    end

endmodule
