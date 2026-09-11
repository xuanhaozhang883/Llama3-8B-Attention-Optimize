`timescale 1ns/1ps

module tb_cats_r4_if_v3_replay_integration;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0;
    logic [31:0] cycle_count;
    always_ff @(posedge clk)
        if (!rst_n || clear) cycle_count <= 0;
        else cycle_count <= cycle_count + 1'b1;

    logic start_valid, start_ready;
    logic [15:0] start_epoch;
    logic [2:0] start_group;
    logic [4:0] start_global_q_head;
    logic [6:0] start_row;
    logic [1:0] start_slot_id, start_numeric_mode;
    logic [31:0] start_sum_fp32, start_inv_sum_fp32;
    logic [31:0] case_weights [0:127];
    logic [31:0] all_weights [0:511];
    logic [15:0] rows_mem [0:3];
    logic [31:0] sums_mem [0:3], inv_sums_mem [0:3];

    logic ad_wr_valid, ad_wr_ready, ad_wr_mask, ad_wr_last;
    logic [15:0] ad_wr_epoch;
    logic [2:0] ad_wr_group;
    logic [4:0] ad_wr_head;
    logic [6:0] ad_wr_row, ad_wr_key;
    logic [1:0] ad_wr_slot, ad_wr_mode;
    logic [31:0] ad_wr_data;
    logic ad_commit_valid, ad_commit_ready;
    logic [15:0] ad_commit_epoch;
    logic [2:0] ad_commit_group;
    logic [4:0] ad_commit_head;
    logic [6:0] ad_commit_row;
    logic [1:0] ad_commit_slot, ad_commit_mode;
    logic [31:0] ad_commit_sum, ad_commit_inv;

    logic neg_mode, neg_wr_valid;
    logic mem_wr_valid, mem_wr_ready;
    logic [15:0] mem_wr_epoch;
    logic [2:0] mem_wr_group;
    logic [4:0] mem_wr_head;
    logic [6:0] mem_wr_row, mem_wr_key;
    logic [1:0] mem_wr_slot, mem_wr_mode;
    logic mem_wr_mask, mem_wr_last;
    logic [31:0] mem_wr_data;
    logic mem_commit_valid, mem_commit_ready;
    logic write_pause, commit_pause;

    logic pv_row_valid, pv_row_ready;
    logic [15:0] pv_row_epoch;
    logic [2:0] pv_row_group;
    logic [4:0] pv_row_global_q_head;
    logic [6:0] pv_row_row;
    logic [1:0] pv_row_slot_id, pv_row_numeric_mode;
    logic [31:0] pv_row_sum_fp32, pv_row_inv_sum_fp32;

    logic rd_valid, rd_ready, rsp_valid;
    logic [6:0] rd_key, rsp_key;
    logic [15:0] rsp_epoch;
    logic [2:0] rsp_group;
    logic [4:0] rsp_head;
    logic [6:0] rsp_row;
    logic [1:0] rsp_slot, rsp_mode;
    logic rsp_mask;
    logic [31:0] rsp_data;
    logic release_valid, release_ready;

    logic [63:0] weight_wr_accept, weight_rd_request, weight_rd_response;
    logic [63:0] row_commit_count, pv_row_count, weight_release_count;
    logic [63:0] owner_error, mask_error, last_error, mode_error;
    logic [63:0] numeric_error, epoch_drop, bank_conflict, outstanding_max;

    assign write_pause = (cycle_count[2:0] == 3);
    assign commit_pause = (cycle_count[2:0] == 5);
    assign ad_wr_ready = mem_wr_ready && !write_pause && !neg_mode;
    assign ad_commit_ready = mem_commit_ready && !commit_pause && !neg_mode;
    assign mem_wr_valid = neg_mode ? neg_wr_valid :
                          (ad_wr_valid && !write_pause);
    assign mem_wr_epoch = neg_mode ? 16'hdead : ad_wr_epoch;
    assign mem_wr_group = neg_mode ? start_group : ad_wr_group;
    assign mem_wr_head = neg_mode ? start_global_q_head : ad_wr_head;
    assign mem_wr_row = neg_mode ? start_row : ad_wr_row;
    assign mem_wr_slot = neg_mode ? start_slot_id : ad_wr_slot;
    assign mem_wr_mode = neg_mode ? start_numeric_mode : ad_wr_mode;
    assign mem_wr_key = neg_mode ? 7'd0 : ad_wr_key;
    assign mem_wr_mask = neg_mode ? 1'b0 : ad_wr_mask;
    assign mem_wr_data = neg_mode ? 32'h3f800000 : ad_wr_data;
    assign mem_wr_last = neg_mode ? 1'b0 : ad_wr_last;
    assign mem_commit_valid = ad_commit_valid && !commit_pause && !neg_mode;

    cats_r4_if_v3_replay_adapter u_replay (
        .clk, .rst_n, .clear,
        .start_valid, .start_ready, .start_epoch, .start_group,
        .start_global_q_head, .start_row, .start_slot_id,
        .start_numeric_mode, .start_sum_fp32, .start_inv_sum_fp32,
        .weight_wr_valid(ad_wr_valid), .weight_wr_ready(ad_wr_ready),
        .weight_wr_epoch(ad_wr_epoch), .weight_wr_group(ad_wr_group),
        .weight_wr_global_q_head(ad_wr_head), .weight_wr_row(ad_wr_row),
        .weight_wr_slot_id(ad_wr_slot), .weight_wr_numeric_mode(ad_wr_mode),
        .weight_wr_key(ad_wr_key), .weight_wr_mask(ad_wr_mask),
        .weight_wr_data(ad_wr_data), .weight_wr_last(ad_wr_last),
        .row_commit_valid(ad_commit_valid),
        .row_commit_ready(ad_commit_ready),
        .row_commit_epoch(ad_commit_epoch),
        .row_commit_group(ad_commit_group),
        .row_commit_global_q_head(ad_commit_head),
        .row_commit_row(ad_commit_row), .row_commit_slot_id(ad_commit_slot),
        .row_commit_numeric_mode(ad_commit_mode),
        .row_commit_sum_fp32(ad_commit_sum),
        .row_commit_inv_sum_fp32(ad_commit_inv),
        .weight_data(case_weights)
    );

    cats_r4_weight_slot_mem u_mem (
        .clk, .rst_n, .clear,
        .weight_wr_valid(mem_wr_valid), .weight_wr_ready(mem_wr_ready),
        .weight_wr_epoch(mem_wr_epoch), .weight_wr_group(mem_wr_group),
        .weight_wr_global_q_head(mem_wr_head), .weight_wr_row(mem_wr_row),
        .weight_wr_slot_id(mem_wr_slot),
        .weight_wr_numeric_mode(mem_wr_mode), .weight_wr_key(mem_wr_key),
        .weight_wr_mask(mem_wr_mask), .weight_wr_data(mem_wr_data),
        .weight_wr_last(mem_wr_last),
        .row_commit_valid(mem_commit_valid),
        .row_commit_ready(mem_commit_ready),
        .row_commit_epoch(ad_commit_epoch),
        .row_commit_group(ad_commit_group),
        .row_commit_global_q_head(ad_commit_head),
        .row_commit_row(ad_commit_row),
        .row_commit_slot_id(ad_commit_slot),
        .row_commit_numeric_mode(ad_commit_mode),
        .row_commit_sum_fp32(ad_commit_sum),
        .row_commit_inv_sum_fp32(ad_commit_inv),
        .pv_row_valid, .pv_row_ready, .pv_row_epoch, .pv_row_group,
        .pv_row_global_q_head, .pv_row_row, .pv_row_slot_id,
        .pv_row_numeric_mode, .pv_row_sum_fp32, .pv_row_inv_sum_fp32,
        .weight_rd_req_valid(rd_valid), .weight_rd_req_ready(rd_ready),
        .weight_rd_req_epoch(start_epoch),
        .weight_rd_req_group(start_group),
        .weight_rd_req_global_q_head(start_global_q_head),
        .weight_rd_req_row(start_row), .weight_rd_req_slot_id(start_slot_id),
        .weight_rd_req_numeric_mode(start_numeric_mode),
        .weight_rd_req_key(rd_key),
        .weight_rd_rsp_valid(rsp_valid), .weight_rd_rsp_epoch(rsp_epoch),
        .weight_rd_rsp_group(rsp_group),
        .weight_rd_rsp_global_q_head(rsp_head),
        .weight_rd_rsp_row(rsp_row), .weight_rd_rsp_slot_id(rsp_slot),
        .weight_rd_rsp_numeric_mode(rsp_mode),
        .weight_rd_rsp_key(rsp_key), .weight_rd_rsp_mask(rsp_mask),
        .weight_rd_rsp_data(rsp_data),
        .weight_release_valid(release_valid),
        .weight_release_ready(release_ready),
        .weight_release_epoch(start_epoch),
        .weight_release_group(start_group),
        .weight_release_global_q_head(start_global_q_head),
        .weight_release_row(start_row),
        .weight_release_slot_id(start_slot_id),
        .weight_release_numeric_mode(start_numeric_mode),
        .weight_wr_accept, .weight_rd_request, .weight_rd_response,
        .row_commit_count, .pv_row_count, .weight_release_count,
        .owner_error, .mask_error, .last_error, .mode_error,
        .numeric_error, .epoch_drop, .bank_conflict, .outstanding_max
    );

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic configure_case(input integer ci);
        integer k;
        reg [15:0] row_word;
        begin
            row_word = rows_mem[ci];
            start_epoch = 16'ha203;
            start_group = row_word[15:11];
            start_global_q_head = row_word[15:9];
            start_row = row_word[8:2];
            start_slot_id = row_word[1:0];
            start_numeric_mode = 1;
            start_sum_fp32 = sums_mem[ci];
            start_inv_sum_fp32 = inv_sums_mem[ci];
            for (k = 0; k < 128; k = k + 1)
                case_weights[k] = all_weights[ci*128+k];
        end
    endtask

    task automatic run_case(input integer ci, input logic inject_stale);
        integer k;
        begin
            configure_case(ci);
            @(negedge clk); start_valid = 1;
            while (!start_ready) tick();
            tick(); @(negedge clk); start_valid = 0;
            while (!ad_commit_valid) tick();
            while (!start_ready) tick();

            if (inject_stale) begin
                @(negedge clk); neg_mode = 1; neg_wr_valid = 1;
                tick();
                if (mem_wr_ready)
                    $fatal(1, "stale token was accepted");
                @(negedge clk); neg_wr_valid = 0; neg_mode = 0;
                tick();
            end

            repeat (3) tick();
            if (!pv_row_valid)
                $fatal(1, "PV row was not announced");
            if (pv_row_epoch != start_epoch ||
                pv_row_group != start_group ||
                pv_row_global_q_head != start_global_q_head ||
                pv_row_row != start_row ||
                pv_row_slot_id != start_slot_id ||
                pv_row_numeric_mode != 1 ||
                pv_row_sum_fp32 != start_sum_fp32 ||
                pv_row_inv_sum_fp32 != start_inv_sum_fp32)
                $fatal(1, "PV row token/metadata mismatch");
            repeat (2) tick();
            @(negedge clk); pv_row_ready = 1;
            tick(); @(negedge clk); pv_row_ready = 0;
            tick();

            for (k = 0; k < 128; k = k + 1) begin
                @(negedge clk); rd_key = k[6:0]; rd_valid = 1;
                while (!rd_ready) tick();
                tick(); @(negedge clk); rd_valid = 0;
                while (!rsp_valid) tick();
                if (rsp_epoch != start_epoch || rsp_group != start_group ||
                    rsp_head != start_global_q_head || rsp_row != start_row ||
                    rsp_slot != start_slot_id || rsp_mode != 1 ||
                    rsp_key != k[6:0] || rsp_mask != (k > start_row) ||
                    rsp_data != ((k > start_row) ? 32'd0 : case_weights[k]))
                    $fatal(1, "weight response mismatch case=%0d key=%0d", ci, k);
                tick();
            end

            @(negedge clk); release_valid = 1;
            while (!release_ready) tick();
            tick(); @(negedge clk); release_valid = 0;
            tick();
        end
    endtask

    string replay_root;
    integer probe_accept;
    initial begin
        if (!$value$plusargs("REPLAY_ROOT=%s", replay_root))
            $fatal(1, "REPLAY_ROOT plusarg is required");
        $readmemh({replay_root, "/rows.mem"}, rows_mem);
        $readmemh({replay_root, "/weights_fp32.mem"}, all_weights);
        $readmemh({replay_root, "/row_sum_fp32.mem"}, sums_mem);
        $readmemh({replay_root, "/row_inv_sum_fp32.mem"}, inv_sums_mem);

        start_valid = 0; start_epoch = 0; start_group = 0;
        start_global_q_head = 0; start_row = 0; start_slot_id = 0;
        start_numeric_mode = 1; start_sum_fp32 = 0;
        start_inv_sum_fp32 = 0; pv_row_ready = 0; rd_valid = 0;
        rd_key = 0; release_valid = 0; neg_mode = 0; neg_wr_valid = 0;
        repeat (4) tick(); rst_n = 1; repeat (2) tick();

        // Abort/drain integration uses clear after isolation. Exercise a
        // partial replay then clear it before running the clean workload.
        configure_case(3);
        @(negedge clk); start_valid = 1; tick();
        @(negedge clk); start_valid = 0;
        while (weight_wr_accept < 5) tick();
        @(negedge clk); clear = 1; tick();
        @(negedge clk); clear = 0; repeat (2) tick();
        if (!start_ready || weight_wr_accept != 0 || row_commit_count != 0)
            $fatal(1, "clear did not abort partial replay state");

        run_case(0, 1);
        run_case(1, 0);
        run_case(2, 0);
        run_case(3, 0);

        if (weight_wr_accept != 512 || weight_rd_request != 512 ||
            weight_rd_response != 512 || row_commit_count != 4 ||
            pv_row_count != 4 || weight_release_count != 4 ||
            epoch_drop != 1 || owner_error != 0 || mask_error != 0 ||
            last_error != 0 || mode_error != 0 || numeric_error != 0 ||
            bank_conflict != 0 || outstanding_max == 0)
            $fatal(1, "IF_V3 replay integration counters mismatch");
        $display("PASS: CATS-R4 A/software-B replay -> C IF_V3 weight lifecycle");
        $finish;
    end

    initial begin
        repeat (20000) tick();
        $fatal(1, "replay integration timeout");
    end
endmodule
