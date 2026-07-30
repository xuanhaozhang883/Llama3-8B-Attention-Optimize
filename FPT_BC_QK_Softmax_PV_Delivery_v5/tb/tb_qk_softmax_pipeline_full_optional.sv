`timescale 1ns/1ps

// Optional, long-running full-configuration end-to-end functional test:
// real QK RTL -> Causal Mask -> Row Tile Buffer -> Softmax.
// Configuration: TILE=4, SEQ_LEN=128, HEAD_DIM=128, Q_HEADS=4.
//
// The test checks both:
//   1) every internal QK score against scores_before_mask.hex; and
//   2) every final Softmax probability against the FP32 golden vector.
module tb_qk_softmax_pipeline_full_optional;
    localparam int TILE     = 4;
    localparam int SEQ_LEN  = 128;
    localparam int HEAD_DIM = 128;
    localparam int Q_HEADS  = 4;
    localparam int GQA_GROUPS = 8;
    localparam int HEAD_W   = 2;
    localparam int GROUP_W  = 3;
    localparam int GLOBAL_Q_HEAD_W = 5;
    localparam logic [GROUP_W-1:0] TEST_GROUP = 3'd6;
    localparam int POS_W    = 7;
    localparam int DIM_W    = 7;
    localparam int TOTAL    = Q_HEADS * SEQ_LEN * SEQ_LEN;
    localparam int ROWS     = Q_HEADS * SEQ_LEN;
    localparam logic [31:0] SCALE_FP32 = 32'h3DB504F3; // 1/sqrt(128)
    localparam real TOL_ABS = 0.0021;
    localparam real ROW_SUM_TOL = 0.01;

    parameter Q_FILE           = "q_after_rope.hex";
    parameter K_FILE           = "k_after_rope.hex";
    parameter SCORE_FILE       = "scores_before_mask.hex";
    parameter EXPECT_FP32_FILE = "full_expected_probs_fp32.mem";
    parameter EXP_LUT_FILE     = "exp_lut_q15.mem";

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, group_start, causal_en;
    logic [GROUP_W-1:0] group_id, active_group_id;
    logic group_start_ready;
    logic vec_ready, vec_valid;
    logic [TILE*16-1:0] q_vec_bf16, k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [GROUP_W-1:0] req_group_id, req_kv_head;
    logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head;
    logic [POS_W-1:0] req_row_base, req_col_base;
    logic [DIM_W-1:0] req_dim;

    logic prob_valid, prob_ready;
    logic [15:0] prob_data;
    logic [GROUP_W-1:0] prob_group_id;
    logic prob_first, prob_last, prob_group_last, prob_global_last;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row, prob_col;

    logic qk_busy, qk_done, frontend_busy, pipeline_busy, group_done, pipeline_done;
    logic start_while_busy_error, invalid_group_id_error;
    logic adapter_protocol_error, adapter_global_last_error;
    logic softmax_row_error, softmax_metadata_error;

    logic [15:0] q_mem [0:Q_HEADS*SEQ_LEN*HEAD_DIM-1];
    logic [15:0] k_mem [0:SEQ_LEN*HEAD_DIM-1];
    logic [15:0] expected_scores [0:TOTAL-1];
    logic [31:0] expected_probs_fp32 [0:TOTAL-1];

    integer lane;
    integer ready_count;
    integer qk_score_count;
    integer prob_count;
    integer row_count;
    integer qk_done_count;
    integer pipeline_done_count;
    integer prob_global_last_count;
    integer numerical_fail_count;
    real max_abs_error;
    real mean_abs_error_acc;
    real row_sum;

    qk_softmax_pipeline_top #(
        .TILE(TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W),
        .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) dut (
        .clk, .rst_n, .group_start, .group_id, .group_start_ready,
        .active_group_id, .causal_en,
        .vec_ready, .vec_valid, .q_vec_bf16, .k_vec_bf16,
        .req_head, .req_group_id, .req_global_q_head, .req_kv_head,
        .req_row_base, .req_col_base, .req_dim,
        .prob_valid, .prob_ready, .prob_data, .prob_group_id,
        .prob_head, .prob_row, .prob_col,
        .prob_first, .prob_last, .prob_group_last, .prob_global_last,
        .qk_busy, .qk_done, .frontend_busy, .pipeline_busy,
        .group_done, .pipeline_done,
        .start_while_busy_error, .invalid_group_id_error,
        .adapter_protocol_error, .adapter_global_last_error,
        .softmax_row_error, .softmax_metadata_error
    );

    function automatic real pow2_real(input integer exponent);
        real value;
        integer i;
        begin
            value = 1.0;
            if (exponent >= 0)
                for (i = 0; i < exponent; i = i + 1) value = value * 2.0;
            else
                for (i = 0; i < -exponent; i = i + 1) value = value / 2.0;
            pow2_real = value;
        end
    endfunction

    function automatic real bf16_to_real(input logic [15:0] bits);
        integer exponent, fraction;
        real mantissa, value;
        begin
            exponent = bits[14:7];
            fraction = bits[6:0];
            if (exponent == 0 && fraction == 0)
                value = 0.0;
            else if (exponent == 0) begin
                mantissa = fraction / 128.0;
                value = mantissa * pow2_real(-126);
            end else begin
                mantissa = 1.0 + fraction / 128.0;
                value = mantissa * pow2_real(exponent - 127);
            end
            bf16_to_real = bits[15] ? -value : value;
        end
    endfunction

    function automatic real fp32_to_real(input logic [31:0] bits);
        integer exponent, fraction;
        real mantissa, value;
        begin
            exponent = bits[30:23];
            fraction = bits[22:0];
            if (exponent == 0 && fraction == 0)
                value = 0.0;
            else if (exponent == 0) begin
                mantissa = fraction / 8388608.0;
                value = mantissa * pow2_real(-126);
            end else begin
                mantissa = 1.0 + fraction / 8388608.0;
                value = mantissa * pow2_real(exponent - 127);
            end
            fp32_to_real = bits[31] ? -value : value;
        end
    endfunction

    function automatic real abs_real(input real x);
        begin
            abs_real = (x < 0.0) ? -x : x;
        end
    endfunction

    // External Q/K memory loader. The QK engine requests one TILE-wide vector
    // for the current head, row tile, column tile and reduction dimension.
    always_comb begin
        vec_valid = rst_n && qk_busy;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;
        for (lane = 0; lane < TILE; lane = lane + 1) begin
            q_vec_bf16[lane*16 +: 16] =
                q_mem[req_head*SEQ_LEN*HEAD_DIM +
                      (req_row_base + lane)*HEAD_DIM + req_dim];
            k_vec_bf16[lane*16 +: 16] =
                k_mem[(req_col_base + lane)*HEAD_DIM + req_dim];
        end
    end

    // Add deterministic output backpressure so the full chain is tested as a
    // streaming valid/ready design, not only with prob_ready permanently high.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_count <= 0;
            prob_ready  <= 1'b0;
        end else begin
            ready_count <= ready_count + 1;
            prob_ready  <= ((ready_count % 19) != 6) &&
                           ((ready_count % 29) != 13);
        end
    end

    // One end-to-end scoreboard. It checks internal raw QK scores and final
    // Softmax probabilities during the same single simulation run.
    always @(posedge clk) begin
        integer score_index;
        integer expected_head, expected_row, expected_col;
        real actual_prob, expected_prob, abs_error;

        if (!rst_n) begin
            qk_score_count          = 0;
            prob_count              = 0;
            row_count               = 0;
            qk_done_count           = 0;
            pipeline_done_count     = 0;
            prob_global_last_count  = 0;
            numerical_fail_count    = 0;
            max_abs_error           = 0.0;
            mean_abs_error_acc      = 0.0;
            row_sum                 = 0.0;
        end else begin
            if (qk_done)
                qk_done_count = qk_done_count + 1;

            if (adapter_protocol_error || adapter_global_last_error ||
                softmax_row_error || softmax_metadata_error ||
                start_while_busy_error || invalid_group_id_error)
                $fatal(1, "Pipeline error flag asserted");

            if (vec_valid && vec_ready) begin
                if (req_group_id !== TEST_GROUP || req_kv_head !== TEST_GROUP)
                    $fatal(1, "Full test Q/K group request mismatch");
                if (req_global_q_head !== ((TEST_GROUP*Q_HEADS) + req_head))
                    $fatal(1, "Full test global Q-head mapping mismatch");
            end

            // Hierarchical observation of the real QK output before masking.
            if (dut.score_valid && dut.score_ready) begin
                score_index = dut.score_head*SEQ_LEN*SEQ_LEN +
                              dut.score_row*SEQ_LEN + dut.score_col;
                if (dut.score_bf16 !== expected_scores[score_index])
                    $fatal(1,
                        "QK score mismatch h=%0d r=%0d c=%0d expected=%h actual=%h",
                        dut.score_head, dut.score_row, dut.score_col,
                        expected_scores[score_index], dut.score_bf16);
                if (dut.score_last !==
                    ((dut.score_head == Q_HEADS-1) &&
                     (dut.score_row  == SEQ_LEN-1) &&
                     (dut.score_col  == SEQ_LEN-1)))
                    $fatal(1, "QK global-last mismatch at score_count=%0d",
                           qk_score_count);
                qk_score_count = qk_score_count + 1;
            end

            if (prob_valid && prob_ready) begin
                expected_head = prob_count / (SEQ_LEN*SEQ_LEN);
                expected_row  = (prob_count / SEQ_LEN) % SEQ_LEN;
                expected_col  = prob_count % SEQ_LEN;

                if (prob_group_id !== TEST_GROUP || active_group_id !== TEST_GROUP)
                    $fatal(1, "Probability group mismatch index=%0d", prob_count);

                if (prob_head !== expected_head[HEAD_W-1:0] ||
                    prob_row  !== expected_row[POS_W-1:0] ||
                    prob_col  !== expected_col[POS_W-1:0])
                    $fatal(1, "Probability metadata mismatch index=%0d", prob_count);

                if (prob_first !== (expected_col == 0) ||
                    prob_last  !== (expected_col == SEQ_LEN-1))
                    $fatal(1, "Probability row marker mismatch index=%0d", prob_count);

                if (prob_group_last !==
                    ((expected_head == Q_HEADS-1) &&
                     (expected_row  == SEQ_LEN-1) &&
                     (expected_col  == SEQ_LEN-1)))
                    $fatal(1, "Probability group-last mismatch index=%0d", prob_count);
                if (prob_global_last !== prob_group_last)
                    $fatal(1, "Compatibility last alias mismatch index=%0d", prob_count);

                if (prob_group_last)
                    prob_global_last_count = prob_global_last_count + 1;

                if ((expected_col > expected_row) && (prob_data !== 16'h0000))
                    $fatal(1, "Masked probability is nonzero index=%0d data=%h",
                           prob_count, prob_data);

                actual_prob   = bf16_to_real(prob_data);
                expected_prob = fp32_to_real(expected_probs_fp32[prob_count]);
                abs_error     = abs_real(actual_prob - expected_prob);

                if (abs_error > max_abs_error)
                    max_abs_error = abs_error;
                mean_abs_error_acc = mean_abs_error_acc + abs_error;

                if (abs_error > TOL_ABS) begin
                    numerical_fail_count = numerical_fail_count + 1;
                    if (numerical_fail_count <= 8)
                        $display("NUM FAIL idx=%0d h=%0d r=%0d c=%0d actual=%f expected=%f err=%f",
                                 prob_count, expected_head, expected_row, expected_col,
                                 actual_prob, expected_prob, abs_error);
                end

                row_sum = row_sum + actual_prob;
                if (expected_col == SEQ_LEN-1) begin
                    if (abs_real(row_sum - 1.0) > ROW_SUM_TOL)
                        $fatal(1, "Probability row sum=%f h=%0d r=%0d",
                               row_sum, expected_head, expected_row);
                    row_sum = 0.0;
                    row_count = row_count + 1;
                end

                if (group_done) begin
                    if (!pipeline_done)
                        $fatal(1, "Compatibility done alias mismatch");
                    pipeline_done_count = pipeline_done_count + 1;
                end

                prob_count = prob_count + 1;
                if ((prob_count % 8192) == 0)
                    $display("PROGRESS: final probabilities %0d/%0d, QK scores %0d/%0d",
                             prob_count, TOTAL, qk_score_count, TOTAL);
            end
        end
    end

    initial begin
        $readmemh(Q_FILE, q_mem);
        $readmemh(K_FILE, k_mem);
        $readmemh(SCORE_FILE, expected_scores);
        $readmemh(EXPECT_FP32_FILE, expected_probs_fp32);

        rst_n = 1'b0;
        group_start = 1'b0;
        group_id = TEST_GROUP;
        causal_en = 1'b1;

        repeat (8) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (3) @(posedge clk);
        if (!group_start_ready) $fatal(1, "group_start_ready must be high while idle");
        @(negedge clk) group_start = 1'b1;
        @(negedge clk) group_start = 1'b0;

        wait (prob_count == TOTAL);
        repeat (12) @(posedge clk);

        if (qk_score_count != TOTAL)
            $fatal(1, "Expected %0d QK scores, got %0d", TOTAL, qk_score_count);
        if (row_count != ROWS)
            $fatal(1, "Expected %0d probability rows, got %0d", ROWS, row_count);
        if (qk_done_count != 1)
            $fatal(1, "Expected one qk_done, got %0d", qk_done_count);
        if (pipeline_done_count != 1)
            $fatal(1, "Expected one group_done/pipeline_done, got %0d", pipeline_done_count);
        if (prob_global_last_count != 1)
            $fatal(1, "Expected one prob_group_last, got %0d", prob_global_last_count);
        if (numerical_fail_count != 0)
            $fatal(1, "Probability numerical failures=%0d", numerical_fail_count);
        if (pipeline_busy)
            $fatal(1, "Pipeline remained busy after final output");

        $display("PASS: OPTIONAL full selected-group real QK -> Causal Mask -> Row Tile Buffer -> Softmax");
        $display("group=%0d qk_scores=%0d probabilities=%0d rows=%0d", TEST_GROUP, qk_score_count, prob_count, row_count);
        $display("max_abs_error=%f mean_abs_error=%f",
                 max_abs_error, mean_abs_error_acc / TOTAL);
        $finish;
    end

    // Existing full QK->Adapter run completed around 70 ms of simulated time.
    // Keep a generous functional timeout for the additional Softmax processing.
    initial begin
        #1000000000;
        $fatal(1, "Timeout: full real QK-to-Softmax end-to-end functional test");
    end
endmodule
