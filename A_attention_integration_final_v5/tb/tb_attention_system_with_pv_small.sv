`timescale 1ns/1ps

module tb_attention_system_with_pv_small;

    localparam int QK_TILE      = 4;
    localparam int BC_PV_TILE   = 2;
    localparam int REAL_PV_TILE = 4;
    localparam int SEQ_LEN      = 4;
    localparam int HEAD_DIM     = 4;
    localparam int Q_HEADS      = 4;
    localparam int GQA_GROUPS   = 8;

    localparam int HEAD_W = 2;
    localparam int GROUP_W = 3;
    localparam int GLOBAL_Q_HEAD_W = 5;
    localparam int POS_W = 2;
    localparam int DIM_W = 2;
    localparam int V_ADDR_W = 7;

    localparam int PROBS_PER_GROUP =
        Q_HEADS * SEQ_LEN * SEQ_LEN;
    localparam int BC_PV_VECTORS_PER_GROUP =
        Q_HEADS * (SEQ_LEN/BC_PV_TILE) *
        (HEAD_DIM/BC_PV_TILE) * SEQ_LEN;
    localparam int REAL_PV_VECTORS_PER_GROUP =
        Q_HEADS * (SEQ_LEN/REAL_PV_TILE) *
        (HEAD_DIM/REAL_PV_TILE) * SEQ_LEN;
    localparam int CONTEXTS_PER_GROUP =
        Q_HEADS * SEQ_LEN * HEAD_DIM;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic start;
    logic start_ready;
    logic busy;
    logic done;
    logic causal_en;

    logic qk_vec_ready;
    logic qk_vec_valid;
    logic [QK_TILE*16-1:0] q_vec_bf16;
    logic [QK_TILE*16-1:0] k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [GROUP_W-1:0] req_group_id;
    logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head;
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
    logic [GLOBAL_Q_HEAD_W-1:0] context_global_q_head;
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

    logic mon_bc_pv_valid;
    logic mon_bc_pv_ready;
    logic [31:0] mon_bc_p_vec_bf16;
    logic [31:0] mon_bc_v_vec_bf16;
    logic [GROUP_W-1:0] mon_bc_pv_group_id;
    logic [HEAD_W-1:0] mon_bc_pv_head;
    logic [POS_W-1:0] mon_bc_pv_row_base;
    logic [DIM_W-1:0] mon_bc_pv_feature_base;
    logic [POS_W-1:0] mon_bc_pv_reduce_index;

    logic mon_real_pv_valid;
    logic mon_real_pv_ready;
    logic [63:0] mon_real_p_vec_bf16;
    logic [63:0] mon_real_v_vec_bf16;
    logic [HEAD_W-1:0] mon_real_pv_req_head;
    logic [POS_W-1:0] mon_real_pv_req_row_base;
    logic [DIM_W-1:0] mon_real_pv_req_col_base;
    logic [POS_W-1:0] mon_real_pv_req_reduce;

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

    logic seen [0:GQA_GROUPS-1]
               [0:Q_HEADS-1]
               [0:SEQ_LEN-1]
               [0:HEAD_DIM-1];

    integer prob_count [0:GQA_GROUPS-1];
    integer bc_pv_count [0:GQA_GROUPS-1];
    integer real_pv_count [0:GQA_GROUPS-1];
    integer context_count [0:GQA_GROUPS-1];
    integer group_complete_count;
    integer bc_done_count;
    integer pv_done_count;
    integer system_done_count;
    integer ready_cycle;
    integer lane;
    integer g;
    integer h;
    integer r;
    integer c;

    attention_system_with_pv_top #(
        .QK_TILE(QK_TILE),
        .BC_PV_TILE(BC_PV_TILE),
        .REAL_PV_TILE(REAL_PV_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .SCALE_FP32(32'h3F000000),
        .EXP_LUT_FILE("exp_lut_q15.mem")
    ) dut (
        .*
    );

    function automatic real pow2_real(input integer exponent);
        real value;
        integer index;
        begin
            value = 1.0;
            if (exponent >= 0)
                for (index = 0; index < exponent; index = index + 1)
                    value = value * 2.0;
            else
                for (index = 0; index < -exponent; index = index + 1)
                    value = value / 2.0;
            pow2_real = value;
        end
    endfunction

    function automatic real fp32_bits_to_real(
        input logic [31:0] bits
    );
        integer exponent;
        integer fraction;
        real mantissa;
        real value;
        begin
            exponent = bits[30:23];
            fraction = bits[22:0];

            if ((exponent == 0) && (fraction == 0)) begin
                value = 0.0;
            end else if (exponent == 0) begin
                mantissa = fraction / 8388608.0;
                value = mantissa * pow2_real(-126);
            end else begin
                mantissa = 1.0 + fraction / 8388608.0;
                value = mantissa * pow2_real(exponent-127);
            end

            fp32_bits_to_real = bits[31] ? -value : value;
        end
    endfunction

    function automatic real abs_real(input real value);
        begin
            abs_real = (value < 0.0) ? -value : value;
        end
    endfunction

    always_comb begin
        qk_vec_valid = rst_n;
        q_vec_bf16   = '0;
        k_vec_bf16   = '0;

        for (lane = 0; lane < QK_TILE; lane = lane + 1) begin
            q_vec_bf16[lane*16 +: 16] = 16'h3F80;
            k_vec_bf16[lane*16 +: 16] = 16'h3F80;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle   <= 0;
            context_ready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            context_ready <= ((ready_cycle % 7) != 2) &&
                             ((ready_cycle % 13) != 5);
        end
    end

    task automatic load_all_v_as_one;
        integer group_index;
        integer reduce_index;
        integer feature_base;
        integer load_lane;
        begin
            @(negedge clk);
            v_load_valid = 1'b1;

            for (group_index = 0;
                 group_index < GQA_GROUPS;
                 group_index = group_index + 1) begin
                for (reduce_index = 0;
                     reduce_index < SEQ_LEN;
                     reduce_index = reduce_index + 1) begin
                    for (feature_base = 0;
                         feature_base < HEAD_DIM;
                         feature_base = feature_base + BC_PV_TILE) begin

                        while (!v_load_ready)
                            @(negedge clk);

                        v_load_addr =
                            ((group_index*SEQ_LEN + reduce_index) *
                             HEAD_DIM) + feature_base;

                        for (load_lane = 0;
                             load_lane < BC_PV_TILE;
                             load_lane = load_lane + 1) begin
                            v_load_data[load_lane*16 +: 16] =
                                16'h3F80;
                        end

                        @(negedge clk);
                    end
                end
            end

            v_load_valid = 1'b0;
            v_load_addr  = '0;
            v_load_data  = '0;
        end
    endtask

    always @(posedge clk) begin
        integer group_index;
        integer local_head;
        integer row_index;
        integer col_index;
        integer expected_global_head;
        real context_value;

        if (!rst_n) begin
            group_complete_count = 0;
            bc_done_count        = 0;
            pv_done_count        = 0;
            system_done_count    = 0;

            for (group_index = 0;
                 group_index < GQA_GROUPS;
                 group_index = group_index + 1) begin
                prob_count[group_index]     = 0;
                bc_pv_count[group_index]    = 0;
                real_pv_count[group_index]  = 0;
                context_count[group_index]  = 0;

                for (local_head = 0;
                     local_head < Q_HEADS;
                     local_head = local_head + 1)
                    for (row_index = 0;
                         row_index < SEQ_LEN;
                         row_index = row_index + 1)
                        for (col_index = 0;
                             col_index < HEAD_DIM;
                             col_index = col_index + 1)
                            seen[group_index]
                                [local_head]
                                [row_index]
                                [col_index] = 1'b0;
            end
        end else begin
            if (protocol_error)
                $fatal(
                    1,
                    "protocol_error ctrl=%b bc=%b vcache=%b repack=%b",
                    controller_error,
                    bc_protocol_error,
                    v_cache_error,
                    repack_error
                );

            if (mon_prob_valid && mon_prob_ready) begin
                group_index = $unsigned(mon_prob_group_id);
                prob_count[group_index] =
                    prob_count[group_index] + 1;

                if (($unsigned(mon_prob_col) >
                     $unsigned(mon_prob_row)) &&
                    (mon_prob_data !== 16'h0000))
                    $fatal(1, "Masked probability is not zero");
            end

            if (mon_bc_pv_valid && mon_bc_pv_ready) begin
                group_index = $unsigned(mon_bc_pv_group_id);
                bc_pv_count[group_index] =
                    bc_pv_count[group_index] + 1;
            end

            if (mon_real_pv_valid && mon_real_pv_ready) begin
                group_index = $unsigned(active_group_id);
                real_pv_count[group_index] =
                    real_pv_count[group_index] + 1;
            end

            if (context_valid && context_ready) begin
                group_index = $unsigned(context_group_id);
                local_head  = $unsigned(context_head);
                row_index   = $unsigned(context_row);
                col_index   = $unsigned(context_col);

                if (seen[group_index]
                        [local_head]
                        [row_index]
                        [col_index])
                    $fatal(
                        1,
                        "Duplicate Context g=%0d h=%0d r=%0d c=%0d",
                        group_index,
                        local_head,
                        row_index,
                        col_index
                    );

                seen[group_index]
                    [local_head]
                    [row_index]
                    [col_index] = 1'b1;

                expected_global_head =
                    group_index*Q_HEADS + local_head;

                if ($unsigned(context_global_q_head) !=
                    expected_global_head)
                    $fatal(1, "Context global-head mismatch");

                if (^context_fp32_debug === 1'bx)
                    $fatal(1, "Context FP32 contains X");

                context_value =
                    fp32_bits_to_real(context_fp32_debug);

                // Q=K=1 -> uniform causal probabilities; V=1 -> Context ~= 1.
                if (abs_real(context_value - 1.0) > 0.02)
                    $fatal(
                        1,
                        "Context mismatch g=%0d h=%0d r=%0d c=%0d value=%f",
                        group_index,
                        local_head,
                        row_index,
                        col_index,
                        context_value
                    );

                if (context_group_last !=
                    ((local_head == Q_HEADS-1) &&
                     (row_index == SEQ_LEN-1) &&
                     (col_index == HEAD_DIM-1)))
                    $fatal(1, "context_group_last mismatch");

                if (context_global_last !=
                    ((group_index == GQA_GROUPS-1) &&
                     (local_head == Q_HEADS-1) &&
                     (row_index == SEQ_LEN-1) &&
                     (col_index == HEAD_DIM-1)))
                    $fatal(1, "context_global_last mismatch");

                context_count[group_index] =
                    context_count[group_index] + 1;
            end

            if (bc_group_done)
                bc_done_count = bc_done_count + 1;

            if (pv_group_done)
                pv_done_count = pv_done_count + 1;

            if (group_complete) begin
                if ($unsigned(completed_group_id) !=
                    group_complete_count)
                    $fatal(1, "Group completion order mismatch");

                group_complete_count =
                    group_complete_count + 1;
            end

            if (done)
                system_done_count = system_done_count + 1;
        end
    end

    initial begin
        rst_n        = 1'b0;
        start        = 1'b0;
        causal_en    = 1'b1;
        v_load_valid = 1'b0;
        v_load_addr  = '0;
        v_load_data  = '0;

        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;

        load_all_v_as_one();

        while (!start_ready)
            @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (done === 1'b1);
        repeat (10) @(posedge clk);

        for (g = 0; g < GQA_GROUPS; g = g + 1) begin
            if (prob_count[g] != PROBS_PER_GROUP)
                $fatal(1, "Probability count mismatch group=%0d", g);

            if (bc_pv_count[g] != BC_PV_VECTORS_PER_GROUP)
                $fatal(1, "BC TILE2 PV-vector count mismatch group=%0d", g);

            if (real_pv_count[g] != REAL_PV_VECTORS_PER_GROUP)
                $fatal(1, "Real TILE4 PV-vector count mismatch group=%0d", g);

            if (context_count[g] != CONTEXTS_PER_GROUP)
                $fatal(1, "Context count mismatch group=%0d", g);

            for (h = 0; h < Q_HEADS; h = h + 1)
                for (r = 0; r < SEQ_LEN; r = r + 1)
                    for (c = 0; c < HEAD_DIM; c = c + 1)
                        if (!seen[g][h][r][c])
                            $fatal(
                                1,
                                "Missing Context g=%0d h=%0d r=%0d c=%0d",
                                g, h, r, c
                            );
        end

        if (group_complete_count != GQA_GROUPS)
            $fatal(1, "group_complete count mismatch");

        if (bc_done_count != GQA_GROUPS)
            $fatal(1, "BC done count mismatch");

        if (pv_done_count != GQA_GROUPS)
            $fatal(1, "PV done count mismatch");

        if (system_done_count != 1)
            $fatal(1, "System done count mismatch");

        $display("================================================");
        $display("[PASS] Corrected A+B+C+real-PV full-path smoke test");
        $display("Groups                    = %0d", GQA_GROUPS);
        $display("Probabilities/group       = %0d", PROBS_PER_GROUP);
        $display("BC TILE2 vectors/group    = %0d", BC_PV_VECTORS_PER_GROUP);
        $display("Real TILE4 vectors/group  = %0d", REAL_PV_VECTORS_PER_GROUP);
        $display("Context outputs/group     = %0d", CONTEXTS_PER_GROUP);
        $display("Group completions         = %0d", group_complete_count);
        $display("System done pulses        = %0d", system_done_count);
        $display("Protocol errors           = 0");
        $display("Validated through         = real Context output");
        $display("================================================");

        #50;
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "TIMEOUT: corrected A+B+C+PV integration");
    end

endmodule
