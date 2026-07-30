`timescale 1ns/1ps

// Full-chain numerical regression using only the repository's fpga_slice:
// raw Q/K -> RoPE -> QK -> causal mask -> Softmax -> real PV -> Context.
//
// fpga_slice is one GQA Group, not one attention head:
//   Q/Context = [4][128][128], K/V = [1][128][128].
// The DUT retains the physical 8-Group widths/caches but executes Group 0 only.
module tb_attention_system_with_rope_pv_fpga_slice_golden;
    localparam int QK_TILE       = 4;
    localparam int BC_PV_TILE    = 2;
    localparam int REAL_PV_TILE  = 4;
    localparam int SEQ_LEN       = 128;
    localparam int HEAD_DIM      = 128;
    localparam int HALF_DIM      = HEAD_DIM/2;
    localparam int Q_HEADS       = 4;
    localparam int GQA_GROUPS    = 8;
    localparam int RUN_GROUPS    = 1;
    localparam int HEAD_W        = 2;
    localparam int GROUP_W       = 3;
    localparam int GLOBAL_HEAD_W = 5;
    localparam int POS_W         = 7;
    localparam int DIM_W         = 7;
    localparam int PAIR_W        = 6;
    localparam int V_ADDR_W      = 17;

    localparam int Q_WORDS       = Q_HEADS*SEQ_LEN*HEAD_DIM;
    localparam int KV_WORDS      = SEQ_LEN*HEAD_DIM;
    localparam int PROB_WORDS    = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int CONTEXT_WORDS = Q_HEADS*SEQ_LEN*HEAD_DIM;
    localparam int RAW_REQUESTS  = (Q_HEADS+1)*SEQ_LEN*HALF_DIM;
    localparam int QK_VECTORS    =
        Q_HEADS*(SEQ_LEN/QK_TILE)*(SEQ_LEN/QK_TILE)*HEAD_DIM;
    localparam int V_LOAD_BEATS  = KV_WORDS/BC_PV_TILE;
    localparam int MAX_REPORTS   = 20;
    // These are the numerical contracts already documented by the project.
    // Context tolerance is backed by the complete software mirror for this
    // exact slice (predicted maximum 6.103515625e-5).
    localparam real ROPE_ABS_TOL    = 0.001;
    localparam real SOFTMAX_ABS_TOL = 0.0021;
    localparam real CONTEXT_ABS_TOL = 0.0001;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic start;
    logic start_ready;
    logic busy;
    logic done;
    logic causal_en;

    logic raw_req_valid;
    logic raw_req_ready;
    logic raw_req_is_k;
    logic [GLOBAL_HEAD_W-1:0] raw_req_head;
    logic [POS_W-1:0] raw_req_token;
    logic [PAIR_W-1:0] raw_req_pair;
    logic raw_rsp_valid;
    logic raw_rsp_ready;
    logic [15:0] raw_rsp_x0;
    logic [15:0] raw_rsp_x1;

    logic [HEAD_W-1:0] req_head;
    logic [GROUP_W-1:0] req_group_id;
    logic [GLOBAL_HEAD_W-1:0] req_global_q_head;
    logic [GROUP_W-1:0] req_kv_head;
    logic [POS_W-1:0] req_row_base;
    logic [POS_W-1:0] req_col_base;
    logic [DIM_W-1:0] req_dim;

    logic v_load_valid;
    logic v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr;
    logic [BC_PV_TILE*16-1:0] v_load_data;

    logic context_valid;
    logic context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [GROUP_W-1:0] context_group_id;
    logic [HEAD_W-1:0] context_head;
    logic [GLOBAL_HEAD_W-1:0] context_global_q_head;
    logic [POS_W-1:0] context_row;
    logic [DIM_W-1:0] context_col;
    logic context_group_last;
    logic context_global_last;

    logic mon_prob_valid;
    logic mon_prob_ready;
    logic [15:0] mon_prob_data;
    logic [GROUP_W-1:0] mon_prob_group_id;
    logic [HEAD_W-1:0] mon_prob_head;
    logic [POS_W-1:0] mon_prob_row;
    logic [POS_W-1:0] mon_prob_col;
    logic mon_prob_first;
    logic mon_prob_last;
    logic mon_prob_group_last;

    logic group_complete;
    logic [GROUP_W-1:0] completed_group_id;
    logic [GROUP_W-1:0] active_group_id;
    logic bc_group_done;
    logic capture_complete;
    logic pv_group_done;
    logic bc_busy;
    logic pv_busy;
    logic start_while_busy_error;
    logic controller_error;
    logic bc_protocol_error;
    logic v_cache_error;
    logic repack_error;
    logic protocol_error;

    logic [15:0] q_before_mem [0:Q_WORDS-1];
    logic [15:0] k_before_mem [0:KV_WORDS-1];
    logic [15:0] v_mem        [0:KV_WORDS-1];
    logic [15:0] q_after_mem  [0:Q_WORDS-1];
    logic [15:0] k_after_mem  [0:KV_WORDS-1];
    logic [15:0] prob_mem     [0:PROB_WORDS-1];
    logic [15:0] context_mem  [0:CONTEXT_WORDS-1];
    bit context_seen [0:CONTEXT_WORDS-1];

    integer raw_request_count = 0;
    integer v_load_count = 0;
    integer qk_vector_count = 0;
    integer probability_count = 0;
    integer context_count = 0;
    integer group_complete_count = 0;
    integer done_count = 0;
    integer q_rope_mismatches = 0;
    integer k_rope_mismatches = 0;
    integer probability_mismatches = 0;
    integer context_mismatches = 0;
    integer q_rope_tolerance_failures = 0;
    integer k_rope_tolerance_failures = 0;
    integer probability_tolerance_failures = 0;
    integer context_tolerance_failures = 0;
    integer duplicate_contexts = 0;
    integer metadata_errors = 0;
    integer report_count = 0;
    real max_q_rope_abs_error = 0.0;
    real max_k_rope_abs_error = 0.0;
    real max_probability_abs_error = 0.0;
    real max_context_abs_error = 0.0;

    integer lane;
    integer q_index;
    integer k_index;
    integer gold_index;
    integer h_i;
    integer row_i;
    integer col_i;
    integer dim_i;
    real context_diff;
    real stage_diff;

    initial begin
        $readmemh("q_before_rope_bf16.hex", q_before_mem);
        $readmemh("k_before_rope_bf16.hex", k_before_mem);
        $readmemh("v_bf16.hex", v_mem);
        $readmemh("q_after_rope_golden_bf16.hex", q_after_mem);
        $readmemh("k_after_rope_golden_bf16.hex", k_after_mem);
        $readmemh("softmax_weights_bf16.hex", prob_mem);
        $readmemh("attn_out_per_head_bf16.hex", context_mem);
    end

    attention_system_with_rope_pv_top #(
        .QK_TILE(QK_TILE),
        .BC_PV_TILE(BC_PV_TILE),
        .REAL_PV_TILE(REAL_PV_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .RUN_GQA_GROUPS(RUN_GROUPS),
        .EXP_LUT_FILE("exp_lut_q15.mem"),
        .SIN_ROM_FILE("sin_bf16.hex"),
        .COS_ROM_FILE("cos_bf16.hex")
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .start_ready(start_ready),
        .busy(busy),
        .done(done),
        .causal_en(causal_en),

        .raw_req_valid(raw_req_valid),
        .raw_req_ready(raw_req_ready),
        .raw_req_is_k(raw_req_is_k),
        .raw_req_head(raw_req_head),
        .raw_req_token(raw_req_token),
        .raw_req_pair(raw_req_pair),
        .raw_rsp_valid(raw_rsp_valid),
        .raw_rsp_ready(raw_rsp_ready),
        .raw_rsp_x0(raw_rsp_x0),
        .raw_rsp_x1(raw_rsp_x1),

        .req_head(req_head),
        .req_group_id(req_group_id),
        .req_global_q_head(req_global_q_head),
        .req_kv_head(req_kv_head),
        .req_row_base(req_row_base),
        .req_col_base(req_col_base),
        .req_dim(req_dim),

        .v_load_valid(v_load_valid),
        .v_load_ready(v_load_ready),
        .v_load_addr(v_load_addr),
        .v_load_data(v_load_data),

        .context_valid(context_valid),
        .context_ready(context_ready),
        .context_bf16(context_bf16),
        .context_fp32_debug(context_fp32_debug),
        .context_group_id(context_group_id),
        .context_head(context_head),
        .context_global_q_head(context_global_q_head),
        .context_row(context_row),
        .context_col(context_col),
        .context_group_last(context_group_last),
        .context_global_last(context_global_last),

        .mon_prob_valid(mon_prob_valid),
        .mon_prob_ready(mon_prob_ready),
        .mon_prob_data(mon_prob_data),
        .mon_prob_group_id(mon_prob_group_id),
        .mon_prob_head(mon_prob_head),
        .mon_prob_row(mon_prob_row),
        .mon_prob_col(mon_prob_col),
        .mon_prob_first(mon_prob_first),
        .mon_prob_last(mon_prob_last),
        .mon_prob_group_last(mon_prob_group_last),

        .group_complete(group_complete),
        .completed_group_id(completed_group_id),
        .active_group_id(active_group_id),
        .bc_group_done(bc_group_done),
        .capture_complete(capture_complete),
        .pv_group_done(pv_group_done),
        .bc_busy(bc_busy),
        .pv_busy(pv_busy),
        .start_while_busy_error(start_while_busy_error),
        .controller_error(controller_error),
        .bc_protocol_error(bc_protocol_error),
        .v_cache_error(v_cache_error),
        .repack_error(repack_error),
        .protocol_error(protocol_error)
    );

    function automatic real pow2i(input integer exponent);
        integer n;
        real value;
        begin
            value = 1.0;
            if (exponent >= 0)
                for (n = 0; n < exponent; n = n + 1)
                    value = value * 2.0;
            else
                for (n = 0; n < -exponent; n = n + 1)
                    value = value / 2.0;
            pow2i = value;
        end
    endfunction

    function automatic real bf16_to_real(input logic [15:0] value);
        integer exponent;
        integer fraction;
        real magnitude;
        begin
            exponent = value[14:7];
            fraction = value[6:0];
            if (exponent == 0)
                magnitude = (fraction / 128.0) * pow2i(-126);
            else if (exponent == 255)
                magnitude = 1.0e300;
            else
                magnitude = (1.0 + fraction / 128.0) * pow2i(exponent-127);
            bf16_to_real = value[15] ? -magnitude : magnitude;
        end
    endfunction

    // The RoPE contract uses split-half pairs, matching Python rotate_half():
    // x0 = x[..., pair], x1 = x[..., pair + HEAD_DIM/2].
    assign raw_req_ready = rst_n && !raw_rsp_valid;
    always @(posedge clk) begin
        if (!rst_n) begin
            raw_rsp_valid <= 1'b0;
            raw_rsp_x0 <= '0;
            raw_rsp_x1 <= '0;
            raw_request_count = 0;
        end else begin
            if (raw_rsp_valid && raw_rsp_ready)
                raw_rsp_valid <= 1'b0;

            if (raw_req_valid && raw_req_ready) begin
                if ($unsigned(raw_req_token) >= SEQ_LEN ||
                    $unsigned(raw_req_pair) >= HALF_DIM) begin
                    $fatal(1, "raw request index out of range");
                end

                if (raw_req_is_k) begin
                    if (raw_req_head !== 0) begin
                        metadata_errors = metadata_errors + 1;
                        $fatal(1, "fpga_slice contains only KV head 0, requested %0d", raw_req_head);
                    end
                    k_index = $unsigned(raw_req_token)*HEAD_DIM +
                              $unsigned(raw_req_pair);
                    raw_rsp_x0 <= k_before_mem[k_index];
                    raw_rsp_x1 <= k_before_mem[k_index+HALF_DIM];
                end else begin
                    if ($unsigned(raw_req_head) >= Q_HEADS) begin
                        metadata_errors = metadata_errors + 1;
                        $fatal(1, "fpga_slice contains Q heads 0..3, requested %0d", raw_req_head);
                    end
                    q_index = ($unsigned(raw_req_head)*SEQ_LEN +
                               $unsigned(raw_req_token))*HEAD_DIM +
                              $unsigned(raw_req_pair);
                    raw_rsp_x0 <= q_before_mem[q_index];
                    raw_rsp_x1 <= q_before_mem[q_index+HALF_DIM];
                end
                raw_rsp_valid <= 1'b1;
                raw_request_count = raw_request_count + 1;
            end
        end
    end

    // Verify every rotated Q/K vector when the internal cache feeds QK.
    always @(posedge clk) begin
        if (rst_n && dut.u_rope_bc_group.qk_vec_valid &&
            dut.u_rope_bc_group.qk_vec_ready) begin
            if (req_group_id !== 0 || req_kv_head !== 0 ||
                req_global_q_head !== req_head) begin
                metadata_errors = metadata_errors + 1;
                if (report_count < MAX_REPORTS) begin
                    $display("[META] QK group/head mapping mismatch");
                    report_count = report_count + 1;
                end
            end

            for (lane = 0; lane < QK_TILE; lane = lane + 1) begin
                q_index = ($unsigned(req_head)*SEQ_LEN +
                           ($unsigned(req_row_base)+lane))*HEAD_DIM +
                          $unsigned(req_dim);
                k_index = ($unsigned(req_col_base)+lane)*HEAD_DIM +
                          $unsigned(req_dim);

                if (dut.u_rope_bc_group.q_vec_bf16[lane*16 +: 16] !==
                    q_after_mem[q_index]) begin
                    q_rope_mismatches = q_rope_mismatches + 1;
                    stage_diff =
                        bf16_to_real(dut.u_rope_bc_group.q_vec_bf16[lane*16 +: 16]) -
                        bf16_to_real(q_after_mem[q_index]);
                    if (stage_diff < 0.0)
                        stage_diff = -stage_diff;
                    if (stage_diff > max_q_rope_abs_error)
                        max_q_rope_abs_error = stage_diff;
                    if (stage_diff > ROPE_ABS_TOL)
                        q_rope_tolerance_failures = q_rope_tolerance_failures + 1;
                    if (report_count < MAX_REPORTS) begin
                        $display("[ROPE-Q] h=%0d token=%0d dim=%0d expected=%04h rtl=%04h abs_err=%e",
                            req_head, $unsigned(req_row_base)+lane, req_dim,
                            q_after_mem[q_index],
                            dut.u_rope_bc_group.q_vec_bf16[lane*16 +: 16], stage_diff);
                        report_count = report_count + 1;
                    end
                end

                if (dut.u_rope_bc_group.k_vec_bf16[lane*16 +: 16] !==
                    k_after_mem[k_index]) begin
                    k_rope_mismatches = k_rope_mismatches + 1;
                    stage_diff =
                        bf16_to_real(dut.u_rope_bc_group.k_vec_bf16[lane*16 +: 16]) -
                        bf16_to_real(k_after_mem[k_index]);
                    if (stage_diff < 0.0)
                        stage_diff = -stage_diff;
                    if (stage_diff > max_k_rope_abs_error)
                        max_k_rope_abs_error = stage_diff;
                    if (stage_diff > ROPE_ABS_TOL)
                        k_rope_tolerance_failures = k_rope_tolerance_failures + 1;
                    if (report_count < MAX_REPORTS) begin
                        $display("[ROPE-K] token=%0d dim=%0d expected=%04h rtl=%04h abs_err=%e",
                            $unsigned(req_col_base)+lane, req_dim,
                            k_after_mem[k_index],
                            dut.u_rope_bc_group.k_vec_bf16[lane*16 +: 16], stage_diff);
                        report_count = report_count + 1;
                    end
                end
            end
            qk_vector_count = qk_vector_count + 1;
        end
    end

    // Verify the Softmax boundary using its explicit [head,row,col] metadata.
    always @(posedge clk) begin
        if (rst_n && mon_prob_valid && mon_prob_ready) begin
            h_i = $unsigned(mon_prob_head);
            row_i = $unsigned(mon_prob_row);
            col_i = $unsigned(mon_prob_col);
            if (mon_prob_group_id !== 0 || h_i >= Q_HEADS ||
                row_i >= SEQ_LEN || col_i >= SEQ_LEN) begin
                metadata_errors = metadata_errors + 1;
                $fatal(1, "Softmax metadata out of range");
            end
            gold_index = (h_i*SEQ_LEN + row_i)*SEQ_LEN + col_i;
            if (mon_prob_data !== prob_mem[gold_index]) begin
                probability_mismatches = probability_mismatches + 1;
                stage_diff = bf16_to_real(mon_prob_data) -
                             bf16_to_real(prob_mem[gold_index]);
                if (stage_diff < 0.0)
                    stage_diff = -stage_diff;
                if (stage_diff > max_probability_abs_error)
                    max_probability_abs_error = stage_diff;
                if (stage_diff > SOFTMAX_ABS_TOL)
                    probability_tolerance_failures =
                        probability_tolerance_failures + 1;
                if (report_count < MAX_REPORTS) begin
                    $display("[SOFTMAX] h=%0d row=%0d col=%0d expected=%04h rtl=%04h abs_err=%e",
                        h_i, row_i, col_i, prob_mem[gold_index], mon_prob_data,
                        stage_diff);
                    report_count = report_count + 1;
                end
            end
            probability_count = probability_count + 1;
        end
    end

    assign context_ready = rst_n;
    always @(posedge clk) begin
        if (rst_n && context_valid && context_ready) begin
            h_i = $unsigned(context_head);
            row_i = $unsigned(context_row);
            col_i = $unsigned(context_col);
            if (context_group_id !== 0 || h_i >= Q_HEADS ||
                row_i >= SEQ_LEN || col_i >= HEAD_DIM ||
                context_global_q_head !== context_head) begin
                metadata_errors = metadata_errors + 1;
                $fatal(1, "Context metadata out of range or incorrectly mapped");
            end
            gold_index = (h_i*SEQ_LEN + row_i)*HEAD_DIM + col_i;
            if (context_seen[gold_index]) begin
                duplicate_contexts = duplicate_contexts + 1;
                if (report_count < MAX_REPORTS) begin
                    $display("[CONTEXT] duplicate h=%0d row=%0d col=%0d", h_i, row_i, col_i);
                    report_count = report_count + 1;
                end
            end
            context_seen[gold_index] = 1'b1;

            context_diff = bf16_to_real(context_bf16) -
                           bf16_to_real(context_mem[gold_index]);
            if (context_diff < 0.0)
                context_diff = -context_diff;
            if (context_diff > max_context_abs_error)
                max_context_abs_error = context_diff;

            if (context_bf16 !== context_mem[gold_index]) begin
                context_mismatches = context_mismatches + 1;
                if (context_diff > CONTEXT_ABS_TOL)
                    context_tolerance_failures = context_tolerance_failures + 1;
                if (report_count < MAX_REPORTS) begin
                    $display("[CONTEXT] h=%0d row=%0d col=%0d expected=%04h rtl=%04h abs_err=%e",
                        h_i, row_i, col_i, context_mem[gold_index],
                        context_bf16, context_diff);
                    report_count = report_count + 1;
                end
            end

            if (context_group_last !== (gold_index == CONTEXT_WORDS-1) ||
                context_global_last !== (gold_index == CONTEXT_WORDS-1)) begin
                metadata_errors = metadata_errors + 1;
                if (report_count < MAX_REPORTS) begin
                    $display("[CONTEXT] last flag mismatch at index %0d", gold_index);
                    report_count = report_count + 1;
                end
            end
            context_count = context_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && v_load_valid && v_load_ready)
            v_load_count = v_load_count + 1;
        if (rst_n && group_complete) begin
            group_complete_count = group_complete_count + 1;
            if (completed_group_id !== 0)
                metadata_errors = metadata_errors + 1;
        end
        if (rst_n && done)
            done_count = done_count + 1;
    end

    task automatic load_group0_v;
        integer beat;
        begin
            for (beat = 0; beat < V_LOAD_BEATS; beat = beat + 1) begin
                @(negedge clk);
                v_load_valid = 1'b1;
                v_load_addr = beat*BC_PV_TILE;
                v_load_data[15:0] = v_mem[beat*BC_PV_TILE];
                v_load_data[31:16] = v_mem[beat*BC_PV_TILE+1];
                while (!v_load_ready)
                    @(negedge clk);
                @(posedge clk);
            end
            @(negedge clk);
            v_load_valid = 1'b0;
            v_load_addr = '0;
            v_load_data = '0;
        end
    endtask

    task automatic print_summary;
        begin
            $display("================================================");
            $display("fpga_slice full-chain golden comparison");
            $display("Raw Q/K requests          = %0d / %0d", raw_request_count, RAW_REQUESTS);
            $display("V load beats              = %0d / %0d", v_load_count, V_LOAD_BEATS);
            $display("Rotated QK vectors        = %0d / %0d", qk_vector_count, QK_VECTORS);
            $display("RoPE Q mismatches         = %0d", q_rope_mismatches);
            $display("RoPE Q tolerance failures = %0d (tol=%e, max=%e)",
                q_rope_tolerance_failures, ROPE_ABS_TOL, max_q_rope_abs_error);
            $display("RoPE K mismatches         = %0d", k_rope_mismatches);
            $display("RoPE K tolerance failures = %0d (tol=%e, max=%e)",
                k_rope_tolerance_failures, ROPE_ABS_TOL, max_k_rope_abs_error);
            $display("Softmax outputs           = %0d / %0d", probability_count, PROB_WORDS);
            $display("Softmax mismatches        = %0d", probability_mismatches);
            $display("Softmax tolerance failures= %0d (tol=%e, max=%e)",
                probability_tolerance_failures, SOFTMAX_ABS_TOL,
                max_probability_abs_error);
            $display("Context outputs           = %0d / %0d", context_count, CONTEXT_WORDS);
            $display("Context exact matches     = %0d / %0d",
                CONTEXT_WORDS-context_mismatches, CONTEXT_WORDS);
            $display("Context mismatches        = %0d", context_mismatches);
            $display("Context tolerance failures= %0d (tol=%e)",
                context_tolerance_failures, CONTEXT_ABS_TOL);
            $display("Context max abs error     = %e", max_context_abs_error);
            $display("Duplicate Context outputs = %0d", duplicate_contexts);
            $display("Group completions         = %0d", group_complete_count);
            $display("System done pulses        = %0d", done_count);
            $display("Metadata errors           = %0d", metadata_errors);
            $display("Protocol error vector     = %b%b%b%b%b%b",
                protocol_error, start_while_busy_error, controller_error,
                bc_protocol_error, v_cache_error, repack_error);
            $display("================================================");
        end
    endtask

    integer check_index;
    integer final_failures;
    initial begin
        start = 1'b0;
        causal_en = 1'b1;
        v_load_valid = 1'b0;
        v_load_addr = '0;
        v_load_data = '0;
        raw_rsp_valid = 1'b0;
        raw_rsp_x0 = '0;
        raw_rsp_x1 = '0;
        for (check_index = 0; check_index < CONTEXT_WORDS; check_index = check_index + 1)
            context_seen[check_index] = 1'b0;

        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        load_group0_v();
        if (v_load_count != V_LOAD_BEATS)
            $fatal(1, "V cache load did not complete: %0d/%0d", v_load_count, V_LOAD_BEATS);

        wait (start_ready && !busy);
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (done);
        repeat (10) @(posedge clk);
        print_summary();

        final_failures = 0;
        if (raw_request_count != RAW_REQUESTS) final_failures = final_failures + 1;
        if (v_load_count != V_LOAD_BEATS) final_failures = final_failures + 1;
        if (qk_vector_count != QK_VECTORS) final_failures = final_failures + 1;
        if (probability_count != PROB_WORDS) final_failures = final_failures + 1;
        if (context_count != CONTEXT_WORDS) final_failures = final_failures + 1;
        if (q_rope_tolerance_failures != 0 || k_rope_tolerance_failures != 0)
            final_failures = final_failures + 1;
        if (probability_tolerance_failures != 0)
            final_failures = final_failures + 1;
        if (context_tolerance_failures != 0)
            final_failures = final_failures + 1;
        if (duplicate_contexts != 0 || metadata_errors != 0)
            final_failures = final_failures + 1;
        if (group_complete_count != 1 || done_count != 1)
            final_failures = final_failures + 1;
        if (protocol_error || start_while_busy_error || controller_error ||
            bc_protocol_error || v_cache_error || repack_error)
            final_failures = final_failures + 1;
        if (busy || bc_busy || pv_busy) final_failures = final_failures + 1;

        for (check_index = 0; check_index < CONTEXT_WORDS; check_index = check_index + 1)
            if (!context_seen[check_index])
                final_failures = final_failures + 1;

        if (final_failures == 0) begin
            $display("[PASS] fpga_slice full-chain numerical comparison passed");
            $finish;
        end else begin
            $fatal(1, "[FAIL] fpga_slice golden comparison failed (%0d failure classes)",
                final_failures);
        end
    end

    // 10 seconds of simulated time = one billion 100-MHz clock cycles.
    initial begin
        #10_000_000_000;
        print_summary();
        $fatal(1, "[TIMEOUT] full-chain fpga_slice simulation did not finish");
    end
endmodule
