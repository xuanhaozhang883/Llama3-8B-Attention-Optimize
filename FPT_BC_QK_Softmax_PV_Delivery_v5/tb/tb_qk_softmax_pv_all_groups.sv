`timescale 1ns/1ps

// End-to-end test of the newly completed actionable scope:
// reference A controller -> B -> C -> synthesizable V-cache -> PV interface.
// One start must execute Groups 0 through 7 exactly once.
module tb_qk_softmax_pv_all_groups;
    localparam int QK_TILE = 4;
    localparam int PV_TILE = 2;
    localparam int SEQ_LEN = 8;
    localparam int HEAD_DIM = 8;
    localparam int Q_HEADS = 4;
    localparam int GQA_GROUPS = 8;
    localparam int HEAD_W = 2;
    localparam int GROUP_W = 3;
    localparam int GLOBAL_Q_HEAD_W = 5;
    localparam int POS_W = 3;
    localparam int DIM_W = 3;
    localparam int V_ADDR_W = 9;
    localparam int PROBS_PER_GROUP = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int VECS_PER_GROUP = Q_HEADS*(SEQ_LEN/PV_TILE)*
                                    (HEAD_DIM/PV_TILE)*SEQ_LEN;

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
    logic [PV_TILE*16-1:0] v_load_data;

    logic [PV_TILE*16-1:0] p_vec_bf16;
    logic [PV_TILE*16-1:0] v_vec_bf16;
    logic pv_vec_valid;
    logic pv_vec_ready;
    logic pv_vec_first;
    logic pv_vec_last;
    logic pv_vec_group_last;
    logic [GROUP_W-1:0] pv_vec_group_id;
    logic [HEAD_W-1:0] pv_vec_head;
    logic [GLOBAL_Q_HEAD_W-1:0] pv_vec_global_q_head;
    logic [POS_W-1:0] pv_vec_row_base;
    logic [DIM_W-1:0] pv_vec_feature_base;
    logic [POS_W-1:0] pv_vec_reduce_index;

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
    logic pipeline_group_start;
    logic pipeline_group_start_ready;
    logic pipeline_qk_busy;
    logic pipeline_b_busy;
    logic pipeline_c_busy;
    logic controller_error;
    logic pipeline_error;
    logic v_cache_error;
    logic protocol_error;

    logic [15:0] captured_p [0:GQA_GROUPS*PROBS_PER_GROUP-1];
    integer prob_count [0:GQA_GROUPS-1];
    integer pv_count [0:GQA_GROUPS-1];
    integer launch_count;
    integer complete_count;
    integer done_count;
    integer ready_cycle;
    integer lane;

    qk_softmax_pv_system_top #(
        .QK_TILE(QK_TILE),
        .PV_TILE(PV_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .SCALE_FP32(32'h3EB504F3)
    ) dut (.*);

    function automatic [15:0] v_word(
        input integer group_index,
        input integer reduce_index,
        input integer feature_index
    );
        begin
            v_word = 16'h4000 + (group_index << 8) +
                     (reduce_index << 4) + feature_index;
        end
    endfunction

    always_comb begin
        qk_vec_valid = busy;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;
        for (lane = 0; lane < QK_TILE; lane = lane + 1) begin
            q_vec_bf16[lane*16 +: 16] = 16'h3F80;
            k_vec_bf16[lane*16 +: 16] = 16'h3F80;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            pv_vec_ready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            pv_vec_ready <= ((ready_cycle % 7) != 2) &&
                            ((ready_cycle % 11) != 6);
        end
    end

    task automatic load_v_cache;
        integer group_index;
        integer reduce_index;
        integer feature_base;
        integer load_lane;
        begin
            @(negedge clk);
            v_load_valid = 1'b1;
            for (group_index = 0; group_index < GQA_GROUPS;
                 group_index = group_index + 1) begin
                for (reduce_index = 0; reduce_index < SEQ_LEN;
                     reduce_index = reduce_index + 1) begin
                    for (feature_base = 0; feature_base < HEAD_DIM;
                         feature_base = feature_base + PV_TILE) begin
                        while (!v_load_ready)
                            @(negedge clk);
                        v_load_addr = ((group_index*SEQ_LEN + reduce_index) *
                                       HEAD_DIM) + feature_base;
                        for (load_lane = 0; load_lane < PV_TILE;
                             load_lane = load_lane + 1)
                            v_load_data[load_lane*16 +: 16] =
                                v_word(group_index, reduce_index,
                                       feature_base + load_lane);
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
        integer index_in_group;
        integer expected_head;
        integer expected_row;
        integer expected_col;
        integer flat_index;

        if (!rst_n) begin
            for (group_index = 0; group_index < GQA_GROUPS;
                 group_index = group_index + 1)
                prob_count[group_index] = 0;
            launch_count = 0;
        end else begin
            if (protocol_error)
                $fatal(1, "Protocol error in 8-Group system run");

            if (pipeline_group_start && pipeline_group_start_ready) begin
                if ($unsigned(dut.launch_group_id) != launch_count)
                    $fatal(1, "Group launch order mismatch at %0d", launch_count);
                launch_count = launch_count + 1;
            end

            if (qk_vec_valid && qk_vec_ready) begin
                if ((req_group_id !== active_group_id) ||
                    (req_kv_head !== active_group_id) ||
                    ($unsigned(req_global_q_head) !=
                     ($unsigned(active_group_id)*Q_HEADS +
                      $unsigned(req_head))))
                    $fatal(1, "8-Group Q/K head mapping mismatch");
            end

            if (mon_prob_valid && mon_prob_ready) begin
                group_index = $unsigned(mon_prob_group_id);
                if ((group_index < 0) || (group_index >= GQA_GROUPS))
                    $fatal(1, "Probability Group out of range");
                index_in_group = prob_count[group_index];
                expected_head = index_in_group / (SEQ_LEN*SEQ_LEN);
                expected_row  = (index_in_group / SEQ_LEN) % SEQ_LEN;
                expected_col  = index_in_group % SEQ_LEN;
                flat_index = expected_head*SEQ_LEN*SEQ_LEN +
                             expected_row*SEQ_LEN + expected_col;

                if (($unsigned(mon_prob_head) != expected_head) ||
                    ($unsigned(mon_prob_row) != expected_row) ||
                    ($unsigned(mon_prob_col) != expected_col) ||
                    (mon_prob_first != (expected_col == 0)) ||
                    (mon_prob_last != (expected_col == SEQ_LEN-1)) ||
                    (mon_prob_group_last !=
                     (index_in_group == PROBS_PER_GROUP-1)))
                    $fatal(1, "Probability metadata mismatch Group %0d index %0d",
                           group_index, index_in_group);

                if ((expected_col > expected_row) &&
                    (mon_prob_data !== 16'h0000))
                    $fatal(1, "Causal probability nonzero");

                captured_p[group_index*PROBS_PER_GROUP + flat_index] =
                    mon_prob_data;
                prob_count[group_index] = index_in_group + 1;
            end
        end
    end

    always @(posedge clk) begin
        integer group_index;
        integer index_in_group;
        integer expected_head;
        integer expected_row_tile;
        integer expected_feature_tile;
        integer expected_reduce;
        integer expected_row_base;
        integer expected_feature_base;
        integer vecs_per_row_tile;
        integer vecs_per_head;
        integer remainder;
        integer flat_index;
        integer check_lane;

        if (!rst_n) begin
            for (group_index = 0; group_index < GQA_GROUPS;
                 group_index = group_index + 1)
                pv_count[group_index] = 0;
            complete_count = 0;
            done_count = 0;
        end else begin
            if (group_complete) begin
                if ($unsigned(completed_group_id) != complete_count)
                    $fatal(1, "Group completion order mismatch");
                complete_count = complete_count + 1;
            end
            if (done)
                done_count = done_count + 1;

            if (pv_vec_valid && pv_vec_ready) begin
                group_index = $unsigned(pv_vec_group_id);
                index_in_group = pv_count[group_index];
                vecs_per_row_tile = (HEAD_DIM/PV_TILE)*SEQ_LEN;
                vecs_per_head = (SEQ_LEN/PV_TILE)*vecs_per_row_tile;
                expected_head = index_in_group / vecs_per_head;
                remainder = index_in_group % vecs_per_head;
                expected_row_tile = remainder / vecs_per_row_tile;
                remainder = remainder % vecs_per_row_tile;
                expected_feature_tile = remainder / SEQ_LEN;
                expected_reduce = remainder % SEQ_LEN;
                expected_row_base = expected_row_tile*PV_TILE;
                expected_feature_base = expected_feature_tile*PV_TILE;

                if (($unsigned(pv_vec_head) != expected_head) ||
                    ($unsigned(pv_vec_global_q_head) !=
                     group_index*Q_HEADS + expected_head) ||
                    ($unsigned(pv_vec_row_base) != expected_row_base) ||
                    ($unsigned(pv_vec_feature_base) != expected_feature_base) ||
                    ($unsigned(pv_vec_reduce_index) != expected_reduce) ||
                    (pv_vec_first != (expected_reduce == 0)) ||
                    (pv_vec_last != (expected_reduce == SEQ_LEN-1)) ||
                    (pv_vec_group_last !=
                     (index_in_group == VECS_PER_GROUP-1)))
                    $fatal(1, "PV metadata mismatch Group %0d index %0d",
                           group_index, index_in_group);

                for (check_lane = 0; check_lane < PV_TILE;
                     check_lane = check_lane + 1) begin
                    flat_index = expected_head*SEQ_LEN*SEQ_LEN +
                                 (expected_row_base+check_lane)*SEQ_LEN +
                                 expected_reduce;
                    if (p_vec_bf16[check_lane*16 +: 16] !==
                        captured_p[group_index*PROBS_PER_GROUP + flat_index])
                        $fatal(1, "P replay mismatch Group %0d vector %0d",
                               group_index, index_in_group);
                    if (v_vec_bf16[check_lane*16 +: 16] !==
                        v_word(group_index, expected_reduce,
                               expected_feature_base+check_lane))
                        $fatal(1, "V-cache data mismatch Group %0d vector %0d",
                               group_index, index_in_group);
                end
                pv_count[group_index] = index_in_group + 1;
            end
        end
    end

    initial begin
        integer group_index;
        rst_n        = 1'b0;
        start        = 1'b0;
        causal_en    = 1'b1;
        v_load_valid = 1'b0;
        v_load_addr  = '0;
        v_load_data  = '0;

        repeat (8) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        load_v_cache();
        if (v_cache_error)
            $fatal(1, "V-cache load failed");

        wait (start_ready);
        @(negedge clk) start = 1'b1;
        @(negedge clk) start = 1'b0;

        wait (done);
        @(posedge clk);
        @(negedge clk);

        if (launch_count != GQA_GROUPS ||
            complete_count != GQA_GROUPS || done_count != 1)
            $fatal(1, "System completion counts launch=%0d complete=%0d done=%0d",
                   launch_count, complete_count, done_count);
        for (group_index = 0; group_index < GQA_GROUPS;
             group_index = group_index + 1) begin
            if (prob_count[group_index] != PROBS_PER_GROUP)
                $fatal(1, "Group %0d probability count %0d", group_index,
                       prob_count[group_index]);
            if (pv_count[group_index] != VECS_PER_GROUP)
                $fatal(1, "Group %0d PV count %0d", group_index,
                       pv_count[group_index]);
        end
        if (busy || protocol_error)
            $fatal(1, "8-Group system did not return cleanly to idle");

        $display("PASS: A-style controller executed Groups 0..7 in order");
        $display("PASS: synthesizable V-cache supplied every PV vector");
        $display("PASS: B+C 8-Group system regression, probabilities=%0d PV_vectors=%0d",
                 GQA_GROUPS*PROBS_PER_GROUP,
                 GQA_GROUPS*VECS_PER_GROUP);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $fatal(1, "Timeout in 8-Group B+C system test");
    end
endmodule
