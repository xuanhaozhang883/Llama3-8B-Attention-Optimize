`timescale 1ns/1ps

module tb_v312_qk_multilane_equivalence;
    localparam int CONFIGS = 4;
    localparam int TILE = 4;
    localparam int SEQ_LEN = 32;
    localparam int HEAD_DIM = 8;
    localparam int Q_HEADS = 2;
    localparam int HEAD_W = $clog2(Q_HEADS);
    localparam int POS_W = $clog2(SEQ_LEN);
    localparam int DIM_W = $clog2(HEAD_DIM);
    localparam int TOTAL_SCORES = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int ALL_TILES = Q_HEADS*(SEQ_LEN/TILE)*(SEQ_LEN/TILE);
    localparam int CAUSAL_COMPUTED = Q_HEADS*(SEQ_LEN/TILE)*((SEQ_LEN/TILE)+1)/2;
    localparam int CAUSAL_SKIPPED = ALL_TILES-CAUSAL_COMPUTED;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic causal_en = 1'b0;
    logic [31:0] lfsr = 32'h6D2B79F5;
    integer cycle_count = 0;
    integer run_start_cycle = 0;
    integer run_id = 0;

    logic [CONFIGS-1:0] busy;
    logic [CONFIGS-1:0] done;
    logic [CONFIGS-1:0] vec_ready;
    logic [CONFIGS-1:0] vec_valid;
    logic [TILE*16-1:0] q_vec [0:CONFIGS-1];
    logic [TILE*16-1:0] k_vec [0:CONFIGS-1];
    logic [HEAD_W-1:0] req_head [0:CONFIGS-1];
    logic [POS_W-1:0] req_row_base [0:CONFIGS-1];
    logic [POS_W-1:0] req_col_base [0:CONFIGS-1];
    logic [DIM_W-1:0] req_dim [0:CONFIGS-1];
    logic [CONFIGS-1:0] score_valid;
    logic [CONFIGS-1:0] score_ready;
    logic [15:0] score_bf16 [0:CONFIGS-1];
    logic [31:0] score_fp32 [0:CONFIGS-1];
    logic [HEAD_W-1:0] score_head [0:CONFIGS-1];
    logic [POS_W-1:0] score_row [0:CONFIGS-1];
    logic [POS_W-1:0] score_col [0:CONFIGS-1];
    logic [CONFIGS-1:0] score_last;
    logic [31:0] tiles_computed [0:CONFIGS-1];
    logic [31:0] tiles_skipped [0:CONFIGS-1];
    logic [31:0] masked_emitted [0:CONFIGS-1];
    logic [CONFIGS-1:0] skip_error;

    integer output_count [0:CONFIGS-1];
    integer request_count [0:CONFIGS-1];
    integer noncausal_cycles [0:CONFIGS-1];
    integer causal_cycles [0:CONFIGS-1];
    logic [CONFIGS-1:0] done_seen;

    logic [CONFIGS-1:0] score_stalled;
    logic [15:0] held_score [0:CONFIGS-1];
    logic [31:0] held_fp32 [0:CONFIGS-1];
    logic [HEAD_W-1:0] held_head [0:CONFIGS-1];
    logic [POS_W-1:0] held_row [0:CONFIGS-1];
    logic [POS_W-1:0] held_col [0:CONFIGS-1];
    logic [CONFIGS-1:0] held_last;

    logic [CONFIGS-1:0] request_stalled;
    logic [HEAD_W-1:0] held_req_head [0:CONFIGS-1];
    logic [POS_W-1:0] held_req_row [0:CONFIGS-1];
    logic [POS_W-1:0] held_req_col [0:CONFIGS-1];
    logic [DIM_W-1:0] held_req_dim [0:CONFIGS-1];

    always #5 clk = ~clk;

    function automatic logic q_bit(
        input integer head, input integer row, input integer dim
    );
        q_bit = (((head + row + dim) % 3) != 0);
    endfunction

    function automatic logic k_bit(
        input integer head, input integer col, input integer dim
    );
        k_bit = (((2*head + col + dim) % 4) < 2);
    endfunction

    function automatic integer expected_sum(
        input integer head, input integer row, input integer col
    );
        integer d;
        begin
            expected_sum = 0;
            for (d = 0; d < HEAD_DIM; d = d + 1)
                if (q_bit(head, row, d) && k_bit(head, col, d))
                    expected_sum = expected_sum + 1;
        end
    endfunction

    function automatic logic [31:0] integer_fp32(input integer value);
        begin
            case (value)
                0: integer_fp32 = 32'h00000000;
                1: integer_fp32 = 32'h3F800000;
                2: integer_fp32 = 32'h40000000;
                3: integer_fp32 = 32'h40400000;
                4: integer_fp32 = 32'h40800000;
                5: integer_fp32 = 32'h40A00000;
                6: integer_fp32 = 32'h40C00000;
                7: integer_fp32 = 32'h40E00000;
                8: integer_fp32 = 32'h41000000;
                default: integer_fp32 = 32'h7FC00000;
            endcase
        end
    endfunction

    genvar g;
    generate
        for (g = 0; g < CONFIGS; g = g + 1) begin : GEN_DUT
            localparam int LANES = (1 << g);
            qk_parallel_systolic_gqa_top #(
                .TILE(TILE), .QK_LANES(LANES), .SEQ_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
                .CAUSAL_TILE_SKIP(1'b1), .SCALE_FP32(32'h3F800000)
            ) dut (
                .clk, .rst_n, .start, .causal_en,
                .busy(busy[g]), .done(done[g]),
                .vec_ready(vec_ready[g]), .vec_valid(vec_valid[g]),
                .q_vec_bf16(q_vec[g]), .k_vec_bf16(k_vec[g]),
                .req_head(req_head[g]), .req_row_base(req_row_base[g]),
                .req_col_base(req_col_base[g]), .req_dim(req_dim[g]),
                .score_valid(score_valid[g]), .score_ready(score_ready[g]),
                .score_bf16(score_bf16[g]),
                .score_fp32_debug(score_fp32[g]),
                .score_head(score_head[g]), .score_row(score_row[g]),
                .score_col(score_col[g]), .score_last(score_last[g]),
                .qk_tiles_computed(tiles_computed[g]),
                .qk_tiles_skipped(tiles_skipped[g]),
                .masked_tiles_emitted(masked_emitted[g]),
                .causal_skip_error(skip_error[g])
            );
        end
    endgenerate

    integer cfg_comb;
    integer cfg_seq;
    integer item;
    integer row_i;
    integer col_i;
    integer head_i;
    integer head_offset;
    integer row_tile_i;
    integer col_tile_i;
    integer local_i;
    logic [31:0] expected_fp32;

    always_comb begin
        for (cfg_comb = 0; cfg_comb < CONFIGS;
             cfg_comb = cfg_comb + 1) begin
            q_vec[cfg_comb] = '0;
            k_vec[cfg_comb] = '0;
            for (item = 0; item < TILE; item = item + 1) begin
                q_vec[cfg_comb][item*16 +: 16] =
                    q_bit($unsigned(req_head[cfg_comb]),
                          $unsigned(req_row_base[cfg_comb])+item,
                          $unsigned(req_dim[cfg_comb])) ? 16'h3F80 : 16'h0000;
                k_vec[cfg_comb][item*16 +: 16] =
                    k_bit($unsigned(req_head[cfg_comb]),
                          $unsigned(req_col_base[cfg_comb])+item,
                          $unsigned(req_dim[cfg_comb])) ? 16'h3F80 : 16'h0000;
            end
            vec_valid[cfg_comb] = lfsr[cfg_comb] || lfsr[cfg_comb+8];
            score_ready[cfg_comb] = lfsr[cfg_comb+16] || lfsr[cfg_comb+24];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 32'h6D2B79F5;
            cycle_count <= 0;
            done_seen <= '0;
            for (cfg_seq = 0; cfg_seq < CONFIGS;
                 cfg_seq = cfg_seq + 1) begin
                output_count[cfg_seq] <= 0;
                request_count[cfg_seq] <= 0;
                noncausal_cycles[cfg_seq] <= 0;
                causal_cycles[cfg_seq] <= 0;
                score_stalled[cfg_seq] <= 1'b0;
                request_stalled[cfg_seq] <= 1'b0;
            end
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            cycle_count <= cycle_count + 1;
            if (start) begin
                done_seen <= '0;
                for (cfg_seq = 0; cfg_seq < CONFIGS;
                     cfg_seq = cfg_seq + 1) begin
                    output_count[cfg_seq] <= 0;
                    request_count[cfg_seq] <= 0;
                    score_stalled[cfg_seq] <= 1'b0;
                    request_stalled[cfg_seq] <= 1'b0;
                end
            end

            for (cfg_seq = 0; cfg_seq < CONFIGS;
                 cfg_seq = cfg_seq + 1) begin
                if (skip_error[cfg_seq])
                    $fatal(1, "lane%0d causal_skip_error", 1 << cfg_seq);

                if (request_stalled[cfg_seq]) begin
                    if ((req_head[cfg_seq] !== held_req_head[cfg_seq]) ||
                        (req_row_base[cfg_seq] !== held_req_row[cfg_seq]) ||
                        (req_col_base[cfg_seq] !== held_req_col[cfg_seq]) ||
                        (req_dim[cfg_seq] !== held_req_dim[cfg_seq]))
                        $fatal(1, "lane%0d request changed while waiting", 1 << cfg_seq);
                    if (vec_valid[cfg_seq] && vec_ready[cfg_seq])
                        request_stalled[cfg_seq] <= 1'b0;
                end else if (vec_ready[cfg_seq] && !vec_valid[cfg_seq]) begin
                    request_stalled[cfg_seq] <= 1'b1;
                    held_req_head[cfg_seq] <= req_head[cfg_seq];
                    held_req_row[cfg_seq] <= req_row_base[cfg_seq];
                    held_req_col[cfg_seq] <= req_col_base[cfg_seq];
                    held_req_dim[cfg_seq] <= req_dim[cfg_seq];
                end

                if (vec_valid[cfg_seq] && vec_ready[cfg_seq])
                    request_count[cfg_seq] <= request_count[cfg_seq] + 1;

                if (score_stalled[cfg_seq]) begin
                    if (!score_valid[cfg_seq] ||
                        (score_bf16[cfg_seq] !== held_score[cfg_seq]) ||
                        (score_fp32[cfg_seq] !== held_fp32[cfg_seq]) ||
                        (score_head[cfg_seq] !== held_head[cfg_seq]) ||
                        (score_row[cfg_seq] !== held_row[cfg_seq]) ||
                        (score_col[cfg_seq] !== held_col[cfg_seq]) ||
                        (score_last[cfg_seq] !== held_last[cfg_seq]))
                        $fatal(1, "lane%0d score payload changed under backpressure", 1 << cfg_seq);
                    if (score_ready[cfg_seq])
                        score_stalled[cfg_seq] <= 1'b0;
                end else if (score_valid[cfg_seq] && !score_ready[cfg_seq]) begin
                    score_stalled[cfg_seq] <= 1'b1;
                    held_score[cfg_seq] <= score_bf16[cfg_seq];
                    held_fp32[cfg_seq] <= score_fp32[cfg_seq];
                    held_head[cfg_seq] <= score_head[cfg_seq];
                    held_row[cfg_seq] <= score_row[cfg_seq];
                    held_col[cfg_seq] <= score_col[cfg_seq];
                    held_last[cfg_seq] <= score_last[cfg_seq];
                end

                if (score_valid[cfg_seq] && score_ready[cfg_seq]) begin
                    head_i = output_count[cfg_seq] / (SEQ_LEN*SEQ_LEN);
                    head_offset = output_count[cfg_seq] % (SEQ_LEN*SEQ_LEN);
                    row_tile_i = head_offset / ((SEQ_LEN/TILE)*TILE*TILE);
                    head_offset = head_offset % ((SEQ_LEN/TILE)*TILE*TILE);
                    col_tile_i = head_offset / (TILE*TILE);
                    local_i = head_offset % (TILE*TILE);
                    row_i = row_tile_i*TILE + local_i/TILE;
                    col_i = col_tile_i*TILE + local_i%TILE;
                    if ((score_head[cfg_seq] !== head_i) ||
                        (score_row[cfg_seq] !== row_i) ||
                        (score_col[cfg_seq] !== col_i))
                        $fatal(1, "lane%0d output order mismatch at %0d: %0d/%0d/%0d",
                               1 << cfg_seq, output_count[cfg_seq], score_head[cfg_seq],
                               score_row[cfg_seq], score_col[cfg_seq]);
                    if (causal_en && (col_tile_i > row_tile_i)) begin
                        if ((score_bf16[cfg_seq] !== 16'hFF80) ||
                            (score_fp32[cfg_seq] !== 32'hFF800000))
                            $fatal(1, "lane%0d causal mask mismatch at %0d",
                                   1 << cfg_seq, output_count[cfg_seq]);
                    end else begin
                        expected_fp32 = expected_sum(head_i, row_i, col_i);
                        expected_fp32 = integer_fp32(expected_fp32);
                        if ((score_fp32[cfg_seq] !== expected_fp32) ||
                            (score_bf16[cfg_seq] !== expected_fp32[31:16]))
                            $fatal(1, "lane%0d score mismatch at %0d got %h/%h expected %h",
                                   1 << cfg_seq, output_count[cfg_seq], score_fp32[cfg_seq],
                                   score_bf16[cfg_seq], expected_fp32);
                    end
                    if (score_last[cfg_seq] !==
                        (output_count[cfg_seq] == TOTAL_SCORES-1))
                        $fatal(1, "lane%0d score_last mismatch at %0d",
                               1 << cfg_seq, output_count[cfg_seq]);
                    output_count[cfg_seq] <= output_count[cfg_seq] + 1;
                end

                if (done[cfg_seq]) begin
                    done_seen[cfg_seq] <= 1'b1;
                    if (run_id == 0)
                        noncausal_cycles[cfg_seq] <= cycle_count-run_start_cycle;
                    else
                        causal_cycles[cfg_seq] <= cycle_count-run_start_cycle;
                end
            end

            if ((cycle_count-run_start_cycle > 500000) && (start == 1'b0) &&
                (done_seen != {CONFIGS{1'b1}}))
                $fatal(1, "multilane equivalence timeout run=%0d done=%b", run_id, done_seen);
        end
    end

    task automatic run_case(input logic causal_value, input integer this_run);
        integer c;
        integer expected_computed;
        integer expected_skipped;
        begin
            wait (busy == '0);
            causal_en = causal_value;
            run_id = this_run;
            run_start_cycle = cycle_count;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            wait (done_seen == '0);
            wait (done_seen == {CONFIGS{1'b1}});
            @(posedge clk);
            #1;
            expected_computed = causal_value ? CAUSAL_COMPUTED : ALL_TILES;
            expected_skipped = causal_value ? CAUSAL_SKIPPED : 0;
            for (c = 0; c < CONFIGS; c = c + 1) begin
                if (output_count[c] != TOTAL_SCORES)
                    $fatal(1, "lane%0d output count %0d expected %0d",
                           1 << c, output_count[c], TOTAL_SCORES);
                if (request_count[c] != expected_computed*HEAD_DIM)
                    $fatal(1, "lane%0d request count %0d expected %0d",
                           1 << c, request_count[c], expected_computed*HEAD_DIM);
                if ((tiles_computed[c] != expected_computed) ||
                    (tiles_skipped[c] != expected_skipped) ||
                    (masked_emitted[c] != expected_skipped))
                    $fatal(1, "lane%0d tile counters %0d/%0d/%0d expected %0d/%0d/%0d",
                           1 << c, tiles_computed[c], tiles_skipped[c],
                           masked_emitted[c], expected_computed,
                           expected_skipped, expected_skipped);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        run_case(1'b0, 0);
        run_case(1'b1, 1);
        $display("QK_MULTILANE_EQUIVALENCE_TEST: PASS scores=%0d", TOTAL_SCORES);
        $display("QK_CYCLES_NONCAUSAL lane1=%0d lane2=%0d lane4=%0d lane8=%0d",
                 noncausal_cycles[0], noncausal_cycles[1],
                 noncausal_cycles[2], noncausal_cycles[3]);
        $display("QK_CYCLES_CAUSAL lane1=%0d lane2=%0d lane4=%0d lane8=%0d",
                 causal_cycles[0], causal_cycles[1],
                 causal_cycles[2], causal_cycles[3]);
        $finish;
    end
endmodule
