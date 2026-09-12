`timescale 1ns/1ps

module tb_cats_r4_b4_cluster_agent #(
    parameter integer CLUSTERS = 1,
    parameter integer CLUSTER_ID = 0,
    parameter integer GLOBAL_HEADS = 32,
    parameter integer ROWS_PER_HEAD = 128,
    parameter integer MODE = 0,
    parameter integer INJECT_SCORE_ERROR = 0,
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem",
    parameter logic [31:0] SEED = 32'hb400_0001
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic counter_clear,
    output logic driver_done,
    output logic agent_done,
    output logic [63:0] checked_rows,
    output logic [63:0] checked_context_words,
    output logic [63:0] checked_final_releases
);
    localparam integer LOCAL_HEADS = GLOBAL_HEADS / CLUSTERS;
    localparam integer LOCAL_ROWS = LOCAL_HEADS * ROWS_PER_HEAD;
    localparam integer LOCAL_VALID_SCORES = LOCAL_HEADS *
        ROWS_PER_HEAD * (ROWS_PER_HEAD+1) / 2;
    localparam integer LOCAL_WEIGHT_WRITES = LOCAL_ROWS * 128;
    localparam integer LOCAL_VECTORS = LOCAL_VALID_SCORES * 4;
    localparam integer LOCAL_PV_MACS = LOCAL_VALID_SCORES * 128;
    localparam integer LOCAL_CONTEXT_WORDS = LOCAL_ROWS * 128;
    localparam logic [15:0] TEST_EPOCH = 16'hb440;

    logic row_valid, row_ready;
    logic [15:0] row_epoch;
    logic [2:0] row_group;
    logic [4:0] row_global_q_head;
    logic [6:0] row_index;
    logic [1:0] row_slot_id, row_numeric_mode;
    logic [15:0] row_max_bf16;
    logic score_valid, score_ready;
    logic [15:0] score_epoch;
    logic [2:0] score_group;
    logic [4:0] score_global_q_head;
    logic [6:0] score_row;
    logic [1:0] score_slot_id, score_numeric_mode;
    logic [6:0] score_key;
    logic [15:0] score_bf16;
    logic score_last;

    logic weight_wr_valid, weight_wr_ready;
    logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group;
    logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row;
    logic [1:0] weight_wr_slot_id, weight_wr_numeric_mode;
    logic [6:0] weight_wr_key;
    logic weight_wr_mask;
    logic [31:0] weight_wr_data;
    logic weight_wr_last;
    logic row_commit_valid, row_commit_ready;
    logic [15:0] row_commit_epoch;
    logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head;
    logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id, row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32, row_commit_inv_sum_fp32;
    logic row_error_valid, row_error_ready;
    logic [15:0] row_error_epoch;
    logic [2:0] row_error_group;
    logic [4:0] row_error_global_q_head;
    logic [6:0] row_error_row;
    logic [1:0] row_error_slot_id, row_error_numeric_mode;
    logic [3:0] row_error_code;
    logic [6:0] row_error_bad_key;

    logic pv_row_valid, pv_row_ready;
    logic [15:0] pv_row_epoch;
    logic [2:0] pv_row_group;
    logic [4:0] pv_row_global_q_head;
    logic [6:0] pv_row_row;
    logic [1:0] pv_row_slot_id, pv_row_numeric_mode;
    logic [31:0] pv_row_sum_fp32, pv_row_inv_sum_fp32;
    logic weight_rd_req_valid, weight_rd_req_ready;
    logic [15:0] weight_rd_req_epoch;
    logic [2:0] weight_rd_req_group;
    logic [4:0] weight_rd_req_global_q_head;
    logic [6:0] weight_rd_req_row;
    logic [1:0] weight_rd_req_slot_id, weight_rd_req_numeric_mode;
    logic [6:0] weight_rd_req_key;
    logic weight_rd_rsp_valid;
    logic [15:0] weight_rd_rsp_epoch;
    logic [2:0] weight_rd_rsp_group;
    logic [4:0] weight_rd_rsp_global_q_head;
    logic [6:0] weight_rd_rsp_row;
    logic [1:0] weight_rd_rsp_slot_id, weight_rd_rsp_numeric_mode;
    logic [6:0] weight_rd_rsp_key;
    logic weight_rd_rsp_mask;
    logic [31:0] weight_rd_rsp_data;

    logic v_req_valid, v_req_ready;
    logic [3:0] v_req_context_tag;
    logic [6:0] v_req_key;
    logic [1:0] v_req_feature_block;
    logic v_rsp_valid;
    logic [3:0] v_rsp_context_tag;
    logic [511:0] v_rsp_vec_bf16;
    logic out_valid, out_ready;
    logic [15:0] out_epoch;
    logic [11:0] out_seq;
    logic [4:0] out_global_q_head;
    logic [6:0] out_row;
    logic [1:0] out_feature_block;
    logic [511:0] out_data_bf16;
    logic out_row_last, out_tensor_last;
    logic weight_release_valid, weight_release_ready;
    logic [15:0] weight_release_epoch;
    logic [2:0] weight_release_group;
    logic [4:0] weight_release_global_q_head;
    logic [6:0] weight_release_row;
    logic [1:0] weight_release_slot_id, weight_release_numeric_mode;
    logic final_release_valid, final_release_ready;
    logic [15:0] final_release_epoch;
    logic [2:0] final_release_group;
    logic [4:0] final_release_global_q_head;
    logic [6:0] final_release_row;
    logic [1:0] final_release_slot_id, final_release_numeric_mode;

    logic [63:0] b2_rows_issue, b2_exp_issue, b2_exp_commit;
    logic [63:0] b2_weight_writes, b2_row_commits, b2_slot_releases;
    logic [63:0] b2_protocol_errors, b2_numeric_errors, b2_owner_errors;
    logic [63:0] b3_pv_rows, b3_weight_requests, b3_weight_responses;
    logic [63:0] b3_weight_consumes, b3_v_requests, b3_v_responses;
    logic [63:0] b3_v_consumes, b3_pv_issue, b3_pv_result;
    logic [63:0] b3_pv_commit, b3_context_words, b3_rows_released;
    logic [63:0] b3_protocol_errors, b3_numeric_errors, b3_epoch_drops;
    logic [63:0] final_release_count, release_join_errors;
    logic error_sticky;
    logic [63:0] c_weight_writes, c_row_commits, c_pv_rows;
    logic [63:0] c_weight_requests, c_weight_responses;
    logic [63:0] c_weight_releases;
    logic c_error_sticky;
    logic [63:0] checked_row_errors;

    logic [31:0] service_lfsr;
    integer output_sequence;
    integer output_block;
    integer release_sequence;
    integer expected_head;
    integer expected_row;

    assign row_error_ready = 1'b1;
    assign v_req_ready = service_lfsr[0] || service_lfsr[6];
    assign out_ready = service_lfsr[1] || service_lfsr[8];
    assign final_release_ready = service_lfsr[2] || service_lfsr[10];
    assign v_rsp_vec_bf16 = {32{16'h3f80}};

    cats_r4_b4_softmax_pv_cluster #(
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_b (.*);

    tb_cats_r4_b4_c_weight_model #(
        .CLUSTERS(CLUSTERS),
        .CLUSTER_ID(CLUSTER_ID),
        .ROWS_PER_HEAD(ROWS_PER_HEAD),
        .SEED(SEED ^ CLUSTER_ID)
    ) u_c (.*);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            service_lfsr <= SEED ^ 32'h51a7_0000 ^ CLUSTER_ID;
            v_rsp_valid <= 1'b0;
            v_rsp_context_tag <= '0;
            output_sequence <= 0;
            output_block <= 0;
            release_sequence <= 0;
            checked_rows <= '0;
            checked_context_words <= '0;
            checked_final_releases <= '0;
            checked_row_errors <= '0;
        end else if (clear) begin
            v_rsp_valid <= 1'b0;
            output_sequence <= 0;
            output_block <= 0;
            release_sequence <= 0;
        end else begin
            service_lfsr <= {service_lfsr[30:0],
                service_lfsr[31]^service_lfsr[21]^
                service_lfsr[1]^service_lfsr[0]};
            v_rsp_valid <= v_req_valid && v_req_ready;
            if (v_req_valid && v_req_ready)
                v_rsp_context_tag <= v_req_context_tag;

            if (row_error_valid && row_error_ready) begin
                if (!INJECT_SCORE_ERROR)
                    $fatal(1,
                        "B4 unexpected row error cluster=%0d code=%0d key=%0d",
                        CLUSTER_ID, row_error_code, row_error_bad_key);
                if (row_error_epoch != TEST_EPOCH || row_error_group != 0 ||
                    row_error_global_q_head != 0 || row_error_row != 0 ||
                    row_error_slot_id != 0 ||
                    row_error_numeric_mode != MODE || row_error_code == 0)
                    $fatal(1, "B4 error release token/code mismatch");
                checked_row_errors <= checked_row_errors + 1'b1;
            end

            if (out_valid && out_ready) begin
                if (INJECT_SCORE_ERROR)
                    $fatal(1, "B4 error row leaked Context output");
                expected_head = CLUSTER_ID +
                    (output_sequence / ROWS_PER_HEAD) * CLUSTERS;
                expected_row = output_sequence % ROWS_PER_HEAD;
                if (out_epoch != TEST_EPOCH ||
                    out_global_q_head != expected_head ||
                    out_row != expected_row ||
                    out_seq != expected_head*128+expected_row ||
                    out_feature_block != output_block ||
                    out_data_bf16 != {32{16'h3f80}} ||
                    out_row_last != (output_block == 3) ||
                    out_tensor_last != (expected_head == 31 &&
                        expected_row == 127 && output_block == 3))
                    $fatal(1,
                        "B4 output mismatch c=%0d seq=%0d block=%0d got_head=%0d got_row=%0d",
                        CLUSTER_ID, output_sequence, output_block,
                        out_global_q_head, out_row);
                checked_context_words <= checked_context_words + 32;
                if (output_block == 3) begin
                    output_block <= 0;
                    output_sequence <= output_sequence + 1;
                    checked_rows <= checked_rows + 1'b1;
                end else begin
                    output_block <= output_block + 1;
                end
            end

            if (final_release_valid && final_release_ready) begin
                expected_head = CLUSTER_ID +
                    (release_sequence / ROWS_PER_HEAD) * CLUSTERS;
                expected_row = release_sequence % ROWS_PER_HEAD;
                if (final_release_epoch != TEST_EPOCH ||
                    final_release_global_q_head != expected_head ||
                    final_release_group != expected_head/4 ||
                    final_release_row != expected_row ||
                    final_release_slot_id != release_sequence%3 ||
                    final_release_numeric_mode != MODE)
                    $fatal(1,
                        "B4 final release mismatch c=%0d seq=%0d",
                        CLUSTER_ID, release_sequence);
                release_sequence <= release_sequence + 1;
                checked_final_releases <= checked_final_releases + 1'b1;
            end

            if (counter_clear) begin
                checked_rows <= '0;
                checked_context_words <= '0;
                checked_final_releases <= '0;
                checked_row_errors <= '0;
            end
        end
    end

    task automatic send_row(input integer local_sequence);
        integer head;
        integer row_number;
        integer slot;
        integer key;
        begin
            head = CLUSTER_ID +
                   (local_sequence / ROWS_PER_HEAD) * CLUSTERS;
            row_number = local_sequence % ROWS_PER_HEAD;
            slot = local_sequence % 3;
            @(negedge clk);
            row_valid = 1'b1;
            row_epoch = TEST_EPOCH;
            row_group = head / 4;
            row_global_q_head = head;
            row_index = row_number;
            row_slot_id = slot;
            row_numeric_mode = MODE;
            row_max_bf16 = 16'h0000;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 1'b0;

            for (key = 0; key <= row_number; key = key + 1) begin
                score_valid = 1'b1;
                score_epoch = TEST_EPOCH;
                score_group = head / 4;
                score_global_q_head = head;
                score_row = row_number;
                score_slot_id = slot;
                score_numeric_mode = MODE;
                score_key = key;
                score_bf16 = 16'h0000;
                score_last = key == row_number;
                do @(posedge clk); while (!score_ready);
                @(negedge clk);
                score_valid = 1'b0;
            end
        end
    endtask

    task automatic send_error_row;
        begin
            @(negedge clk);
            row_valid = 1'b1;
            row_epoch = TEST_EPOCH;
            row_group = 0;
            row_global_q_head = 0;
            row_index = 0;
            row_slot_id = 0;
            row_numeric_mode = MODE;
            row_max_bf16 = 16'h0000;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid = 1'b0;

            // Changing numeric_mode while the slot is busy must be reported
            // before any weight write reaches C, then release B2 and finally
            // A without sending a C weight release.
            score_valid = 1'b1;
            score_epoch = TEST_EPOCH;
            score_group = 0;
            score_global_q_head = 0;
            score_row = 0;
            score_slot_id = 0;
            score_numeric_mode = MODE == 0 ? 2'd1 : 2'd0;
            score_key = 0;
            score_bf16 = 16'h0000;
            score_last = 1'b1;
            do @(posedge clk); while (!score_ready);
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    integer drive_sequence;
    integer timeout;
    initial begin
        row_valid = 1'b0;
        score_valid = 1'b0;
        row_epoch = '0;
        row_group = '0;
        row_global_q_head = '0;
        row_index = '0;
        row_slot_id = '0;
        row_numeric_mode = MODE;
        row_max_bf16 = '0;
        score_epoch = '0;
        score_group = '0;
        score_global_q_head = '0;
        score_row = '0;
        score_slot_id = '0;
        score_numeric_mode = MODE;
        score_key = '0;
        score_bf16 = '0;
        score_last = 1'b0;
        driver_done = 1'b0;
        agent_done = 1'b0;
        wait (rst_n);
        repeat (2) @(posedge clk);
        if (INJECT_SCORE_ERROR)
            send_error_row();
        else
            for (drive_sequence = 0; drive_sequence < LOCAL_ROWS;
                 drive_sequence = drive_sequence + 1)
                send_row(drive_sequence);
        driver_done = 1'b1;

        timeout = 0;
        while (checked_final_releases != LOCAL_ROWS &&
               timeout < 4000000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 4000000)
            $fatal(1,
                "B4 cluster timeout c=%0d releases=%0d/%0d",
                CLUSTER_ID, checked_final_releases, LOCAL_ROWS);
        repeat (5) @(posedge clk);
        if (INJECT_SCORE_ERROR) begin
            if (checked_rows != 0 || checked_context_words != 0 ||
                checked_final_releases != 1 || checked_row_errors != 1 ||
                b2_rows_issue != 1 || b2_weight_writes != 0 ||
                b2_row_commits != 0 || b2_slot_releases != 1 ||
                (b2_protocol_errors + b2_numeric_errors) == 0 ||
                b2_owner_errors != 0 || b3_pv_rows != 0 ||
                b3_weight_requests != 0 || b3_weight_responses != 0 ||
                b3_weight_consumes != 0 || b3_v_requests != 0 ||
                b3_v_responses != 0 || b3_v_consumes != 0 ||
                b3_pv_issue != 0 || b3_pv_result != 0 ||
                b3_pv_commit != 0 || b3_context_words != 0 ||
                b3_rows_released != 0 || final_release_count != 1 ||
                c_weight_writes != 0 || c_row_commits != 0 ||
                c_pv_rows != 0 || c_weight_requests != 0 ||
                c_weight_responses != 0 || c_weight_releases != 0 ||
                b3_protocol_errors != 0 || b3_numeric_errors != 0 ||
                b3_epoch_drops != 0 || release_join_errors != 0 ||
                c_error_sticky || !error_sticky)
                $fatal(1,
                    "B4 error release closure c=%0d report=%0d write=%0d commit=%0d b2rel=%0d final=%0d c_rel=%0d err=%0d/%0d",
                    CLUSTER_ID, checked_row_errors, b2_weight_writes,
                    b2_row_commits, b2_slot_releases,
                    final_release_count, c_weight_releases,
                    b2_protocol_errors, release_join_errors);
            agent_done = 1'b1;
            $display("PASS B4 error release mode=%0d reports=%0d writes=%0d C_releases=%0d final_releases=%0d",
                     MODE, checked_row_errors, b2_weight_writes,
                     c_weight_releases, final_release_count);
        end else if (checked_rows != LOCAL_ROWS ||
            checked_context_words != LOCAL_CONTEXT_WORDS ||
            checked_final_releases != LOCAL_ROWS ||
            b2_rows_issue != LOCAL_ROWS ||
            b2_exp_issue != LOCAL_VALID_SCORES ||
            b2_exp_commit != LOCAL_VALID_SCORES ||
            b2_weight_writes != LOCAL_WEIGHT_WRITES ||
            b2_row_commits != LOCAL_ROWS ||
            b2_slot_releases != LOCAL_ROWS ||
            b3_pv_rows != LOCAL_ROWS ||
            b3_weight_requests != LOCAL_VALID_SCORES ||
            b3_weight_responses != LOCAL_VALID_SCORES ||
            b3_weight_consumes != LOCAL_VALID_SCORES ||
            b3_v_requests != LOCAL_VECTORS ||
            b3_v_responses != LOCAL_VECTORS ||
            b3_v_consumes != LOCAL_VECTORS ||
            b3_pv_issue != LOCAL_PV_MACS ||
            b3_pv_result != LOCAL_PV_MACS ||
            b3_pv_commit != LOCAL_PV_MACS ||
            b3_context_words != LOCAL_CONTEXT_WORDS ||
            b3_rows_released != LOCAL_ROWS ||
            final_release_count != LOCAL_ROWS ||
            c_weight_writes != LOCAL_WEIGHT_WRITES ||
            c_row_commits != LOCAL_ROWS || c_pv_rows != LOCAL_ROWS ||
            c_weight_requests != LOCAL_VALID_SCORES ||
            c_weight_responses != LOCAL_VALID_SCORES ||
            c_weight_releases != LOCAL_ROWS ||
            b2_protocol_errors != 0 || b2_numeric_errors != 0 ||
            b2_owner_errors != 0 || b3_protocol_errors != 0 ||
            b3_numeric_errors != 0 || b3_epoch_drops != 0 ||
            release_join_errors != 0 || c_error_sticky || error_sticky)
            $fatal(1,
                "B4 counter closure c=%0d rows=%0d/%0d exp=%0d pv=%0d out=%0d rel=%0d err=%0d/%0d/%0d/%0d",
                CLUSTER_ID, b2_rows_issue, b3_pv_rows, b2_exp_issue,
                b3_pv_commit, b3_context_words, final_release_count,
                b2_protocol_errors, b3_protocol_errors,
                release_join_errors, c_error_sticky);
        if (!INJECT_SCORE_ERROR) begin
            agent_done = 1'b1;
            $display("PASS B4 cluster=%0d/%0d mode=%0d rows=%0d exp=%0d PV=%0d Context=%0d releases=%0d",
                     CLUSTER_ID, CLUSTERS, MODE, LOCAL_ROWS,
                     LOCAL_VALID_SCORES, LOCAL_PV_MACS,
                     LOCAL_CONTEXT_WORDS, final_release_count);
        end
    end
endmodule

module tb_cats_r4_b4_multicluster #(
    parameter integer CLUSTERS = 1,
    parameter integer GLOBAL_HEADS = 32,
    parameter integer ROWS_PER_HEAD = 128,
    parameter integer MODE = 0,
    parameter integer INJECT_SCORE_ERROR = 0,
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem",
    parameter logic [31:0] SEED = 32'hb400_0001
);
    localparam integer ROWS = GLOBAL_HEADS * ROWS_PER_HEAD;
    localparam integer VALID_SCORES = GLOBAL_HEADS *
        ROWS_PER_HEAD * (ROWS_PER_HEAD+1) / 2;
    localparam integer PV_MACS = VALID_SCORES * 128;
    localparam integer CONTEXT_WORDS = ROWS * 128;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic counter_clear = 1'b0;
    logic driver_done [0:CLUSTERS-1];
    logic agent_done [0:CLUSTERS-1];
    logic [63:0] checked_rows [0:CLUSTERS-1];
    logic [63:0] checked_context_words [0:CLUSTERS-1];
    logic [63:0] checked_final_releases [0:CLUSTERS-1];
    integer cluster;
    integer done_count;
    integer aggregate_rows;
    integer aggregate_context;
    integer aggregate_releases;

    generate
        genvar c;
        for (c = 0; c < CLUSTERS; c = c + 1) begin : g_cluster
            tb_cats_r4_b4_cluster_agent #(
                .CLUSTERS(CLUSTERS), .CLUSTER_ID(c),
                .GLOBAL_HEADS(GLOBAL_HEADS),
                .ROWS_PER_HEAD(ROWS_PER_HEAD),
                .MODE(MODE), .INJECT_SCORE_ERROR(INJECT_SCORE_ERROR),
                .EXP_LUT_FILE(EXP_LUT_FILE),
                .SEED(SEED)
            ) u_agent (
                .clk, .rst_n, .clear, .counter_clear,
                .driver_done(driver_done[c]),
                .agent_done(agent_done[c]),
                .checked_rows(checked_rows[c]),
                .checked_context_words(checked_context_words[c]),
                .checked_final_releases(checked_final_releases[c])
            );
        end
    endgenerate

    initial begin
        if (!(CLUSTERS == 1 || CLUSTERS == 2 || CLUSTERS == 4))
            $fatal(1, "B4 CLUSTERS must be 1, 2 or 4");
        if (GLOBAL_HEADS < CLUSTERS || GLOBAL_HEADS > 32 ||
            GLOBAL_HEADS % CLUSTERS != 0 || ROWS_PER_HEAD < 1 ||
            ROWS_PER_HEAD > 128)
            $fatal(1, "B4 illegal head/row test shape");
        if (!(MODE == 0 || MODE == 1))
            $fatal(1, "B4 MODE must be Compatibility or Accuracy");
        if (INJECT_SCORE_ERROR &&
            (CLUSTERS != 1 || GLOBAL_HEADS != 1 || ROWS_PER_HEAD != 1))
            $fatal(1, "B4 error-release test requires 1x1x1 shape");
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        done_count = 0;
        while (done_count != CLUSTERS) begin
            @(posedge clk);
            done_count = 0;
            for (cluster = 0; cluster < CLUSTERS; cluster = cluster + 1)
                done_count = done_count + agent_done[cluster];
        end
        aggregate_rows = 0;
        aggregate_context = 0;
        aggregate_releases = 0;
        for (cluster = 0; cluster < CLUSTERS; cluster = cluster + 1) begin
            aggregate_rows = aggregate_rows + checked_rows[cluster];
            aggregate_context = aggregate_context +
                                checked_context_words[cluster];
            aggregate_releases = aggregate_releases +
                                 checked_final_releases[cluster];
        end
        if (aggregate_rows != (INJECT_SCORE_ERROR ? 0 : ROWS) ||
            aggregate_context !=
                (INJECT_SCORE_ERROR ? 0 : CONTEXT_WORDS) ||
            aggregate_releases != ROWS)
            $fatal(1, "B4 aggregate closure failed");
        if (INJECT_SCORE_ERROR)
            $display("PASS B4 aggregate error release mode=%0d releases=%0d",
                     MODE, aggregate_releases);
        else
            $display("PASS B4 aggregate clusters=%0d mode=%0d seed=%08x rows=%0d exp=%0d PV=%0d Context=%0d releases=%0d",
                     CLUSTERS, MODE, SEED, aggregate_rows, VALID_SCORES,
                     PV_MACS, aggregate_context, aggregate_releases);
        $finish;
    end

    initial begin
        #1000000000;
        $fatal(1, "B4 multicluster global timeout");
    end
endmodule
