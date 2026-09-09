`timescale 1ns/1ps

module tb_cats_r4_weight_slot_mem;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    always #5 clk = ~clk;

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

    logic weight_release_valid, weight_release_ready;
    logic [15:0] weight_release_epoch;
    logic [2:0] weight_release_group;
    logic [4:0] weight_release_global_q_head;
    logic [6:0] weight_release_row;
    logic [1:0] weight_release_slot_id, weight_release_numeric_mode;

    logic [63:0] weight_wr_accept, weight_rd_request, weight_rd_response;
    logic [63:0] row_commit_count, pv_row_count, weight_release_count;
    logic [63:0] owner_error, mask_error, last_error, mode_error;
    logic [63:0] numeric_error, epoch_drop, bank_conflict, outstanding_max;

    cats_r4_weight_slot_mem dut (.*);

    localparam logic [15:0] TEST_EPOCH = 16'h9001;
    integer active_row_index;
    integer expected_rsp_key;
    integer cycle_count;
    integer fire_cycle [0:127];
    integer rows;
    integer key;

    function automatic [31:0] data_for(
        input integer row_index,
        input integer key_index
    );
        begin
            if (key_index > (row_index & 127))
                data_for = 32'd0;
            else
                data_for = {13'h1555, row_index[11:0], key_index[6:0]};
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("FAIL: %s", message);
            $fatal(1);
        end
    endtask

    task automatic idle_inputs;
        begin
            weight_wr_valid = 1'b0;
            row_commit_valid = 1'b0;
            pv_row_ready = 1'b0;
            weight_rd_req_valid = 1'b0;
            weight_release_valid = 1'b0;
        end
    endtask

    task automatic set_wr_token(
        input integer row_index,
        input integer key_index
    );
        integer head;
        begin
            head = row_index >> 7;
            weight_wr_epoch = TEST_EPOCH;
            weight_wr_group = head >> 2;
            weight_wr_global_q_head = head;
            weight_wr_row = row_index & 127;
            weight_wr_slot_id = row_index % 3;
            weight_wr_numeric_mode = 2'd1;
            weight_wr_key = key_index;
            weight_wr_mask = (key_index > (row_index & 127));
            weight_wr_data = data_for(row_index, key_index);
            weight_wr_last = (key_index == 127);
        end
    endtask

    task automatic write_key(
        input integer row_index,
        input integer key_index
    );
        begin
            @(negedge clk);
            set_wr_token(row_index, key_index);
            weight_wr_valid = 1'b1;
            #1;
            if (!weight_wr_ready)
                fail("legal weight write rejected");
            @(posedge clk);
            @(negedge clk);
            weight_wr_valid = 1'b0;
        end
    endtask

    task automatic commit_row(
        input integer row_index,
        input logic [31:0] sum_value,
        input logic [31:0] inv_value,
        input logic expect_ready
    );
        integer head;
        begin
            head = row_index >> 7;
            @(negedge clk);
            row_commit_epoch = TEST_EPOCH;
            row_commit_group = head >> 2;
            row_commit_global_q_head = head;
            row_commit_row = row_index & 127;
            row_commit_slot_id = row_index % 3;
            row_commit_numeric_mode = 2'd1;
            row_commit_sum_fp32 = sum_value;
            row_commit_inv_sum_fp32 = inv_value;
            row_commit_valid = 1'b1;
            #1;
            if (row_commit_ready != expect_ready)
                fail("row commit readiness mismatch");
            @(posedge clk);
            @(negedge clk);
            row_commit_valid = 1'b0;
        end
    endtask

    task automatic accept_pv_row(input integer row_index);
        integer head;
        integer hold_cycles;
        logic [98:0] held_payload;
        begin
            head = row_index >> 7;
            while (!pv_row_valid)
                @(negedge clk);
            if ((pv_row_epoch != TEST_EPOCH) ||
                (pv_row_group != (head >> 2)) ||
                (pv_row_global_q_head != head) ||
                (pv_row_row != (row_index & 127)) ||
                (pv_row_slot_id != (row_index % 3)) ||
                (pv_row_numeric_mode != 2'd1) ||
                (pv_row_sum_fp32 != 32'h3f800000) ||
                (pv_row_inv_sum_fp32 != 32'h3f800000))
                fail("pv_row token or metadata mismatch");
            if (row_index == 0) begin
                held_payload = {pv_row_epoch, pv_row_group,
                    pv_row_global_q_head, pv_row_row, pv_row_slot_id,
                    pv_row_numeric_mode, pv_row_sum_fp32,
                    pv_row_inv_sum_fp32};
                for (hold_cycles = 0; hold_cycles < 3; hold_cycles = hold_cycles + 1) begin
                    @(posedge clk);
                    @(negedge clk);
                    if (!pv_row_valid ||
                        held_payload !== {pv_row_epoch, pv_row_group,
                            pv_row_global_q_head, pv_row_row, pv_row_slot_id,
                            pv_row_numeric_mode, pv_row_sum_fp32,
                            pv_row_inv_sum_fp32})
                        fail("pv_row payload changed under backpressure");
                end
            end
            pv_row_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pv_row_ready = 1'b0;
        end
    endtask

    task automatic issue_all_reads(input integer row_index);
        integer head;
        integer k;
        begin
            head = row_index >> 7;
            expected_rsp_key = 0;
            for (k = 0; k < 128; k = k + 1) begin
                @(negedge clk);
                weight_rd_req_epoch = TEST_EPOCH;
                weight_rd_req_group = head >> 2;
                weight_rd_req_global_q_head = head;
                weight_rd_req_row = row_index & 127;
                weight_rd_req_slot_id = row_index % 3;
                weight_rd_req_numeric_mode = 2'd1;
                weight_rd_req_key = k;
                weight_rd_req_valid = 1'b1;
                #1;
                if (!weight_rd_req_ready)
                    fail("legal weight read rejected");
                @(posedge clk);
            end
            @(negedge clk);
            weight_rd_req_valid = 1'b0;
        end
    endtask

    task automatic release_row(input integer row_index);
        integer head;
        begin
            head = row_index >> 7;
            while (expected_rsp_key < 128)
                @(negedge clk);
            weight_release_epoch = TEST_EPOCH;
            weight_release_group = head >> 2;
            weight_release_global_q_head = head;
            weight_release_row = row_index & 127;
            weight_release_slot_id = row_index % 3;
            weight_release_numeric_mode = 2'd1;
            weight_release_valid = 1'b1;
            #1;
            if (!weight_release_ready)
                fail("drained PV row release rejected");
            @(posedge clk);
            @(negedge clk);
            weight_release_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (weight_rd_req_valid && weight_rd_req_ready)
            fire_cycle[weight_rd_req_key] = cycle_count;
        #1;
        if (weight_rd_rsp_valid) begin
            if (weight_rd_rsp_key != expected_rsp_key)
                fail("weight response order mismatch");
            if ((cycle_count - fire_cycle[weight_rd_rsp_key]) != 2)
                fail("weight response is not fixed N+2");
            if ((weight_rd_rsp_epoch != TEST_EPOCH) ||
                (weight_rd_rsp_group != ((active_row_index >> 7) >> 2)) ||
                (weight_rd_rsp_global_q_head != (active_row_index >> 7)) ||
                (weight_rd_rsp_row != (active_row_index & 127)) ||
                (weight_rd_rsp_slot_id != (active_row_index % 3)) ||
                (weight_rd_rsp_numeric_mode != 2'd1))
                fail("weight response token mismatch");
            if (weight_rd_rsp_mask !=
                    (expected_rsp_key > (active_row_index & 127)))
                fail("weight response mask mismatch");
            if (weight_rd_rsp_data !=
                    data_for(active_row_index, expected_rsp_key))
                fail("weight response data mismatch");
            expected_rsp_key = expected_rsp_key + 1;
        end
    end

    initial begin
        cycle_count = 0;
        active_row_index = 0;
        expected_rsp_key = 128;
        idle_inputs();
        weight_wr_epoch = '0;
        weight_wr_group = '0;
        weight_wr_global_q_head = '0;
        weight_wr_row = '0;
        weight_wr_slot_id = '0;
        weight_wr_numeric_mode = '0;
        weight_wr_key = '0;
        weight_wr_mask = '0;
        weight_wr_data = '0;
        weight_wr_last = '0;
        row_commit_epoch = '0;
        row_commit_group = '0;
        row_commit_global_q_head = '0;
        row_commit_row = '0;
        row_commit_slot_id = '0;
        row_commit_numeric_mode = '0;
        row_commit_sum_fp32 = '0;
        row_commit_inv_sum_fp32 = '0;
        weight_rd_req_epoch = '0;
        weight_rd_req_group = '0;
        weight_rd_req_global_q_head = '0;
        weight_rd_req_row = '0;
        weight_rd_req_slot_id = '0;
        weight_rd_req_numeric_mode = '0;
        weight_rd_req_key = '0;
        weight_release_epoch = '0;
        weight_release_group = '0;
        weight_release_global_q_head = '0;
        weight_release_row = '0;
        weight_release_slot_id = '0;
        weight_release_numeric_mode = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // Classify malformed first-write attempts without changing slot state.
        @(negedge clk);
        set_wr_token(0, 0);
        weight_wr_numeric_mode = 2'd2;
        weight_wr_valid = 1'b1;
        #1; if (weight_wr_ready) fail("illegal numeric mode accepted");
        @(posedge clk);
        @(negedge clk);
        set_wr_token(0, 0);
        weight_wr_mask = 1'b1;
        weight_wr_valid = 1'b1;
        #1; if (weight_wr_ready) fail("bad mask accepted");
        @(posedge clk);
        @(negedge clk);
        set_wr_token(0, 0);
        weight_wr_last = 1'b1;
        weight_wr_valid = 1'b1;
        #1; if (weight_wr_ready) fail("bad last accepted");
        @(posedge clk);
        @(negedge clk);
        set_wr_token(0, 1);
        weight_wr_valid = 1'b1;
        #1; if (weight_wr_ready) fail("nonzero first key accepted");
        @(posedge clk);
        @(negedge clk);
        weight_wr_valid = 1'b0;

        for (key = 0; key < 128; key = key + 1) begin
            write_key(0, key);
            if (key == 0) begin
                @(negedge clk);
                set_wr_token(0, 1);
                weight_wr_epoch = TEST_EPOCH + 1'b1;
                weight_wr_valid = 1'b1;
                #1; if (weight_wr_ready) fail("stale epoch write accepted");
                @(posedge clk);
                @(negedge clk);
                weight_wr_valid = 1'b0;
            end
        end
        commit_row(0, 32'h00000000, 32'h3f800000, 1'b0);
        if ((mode_error != 1) || (mask_error != 1) ||
            (last_error != 1) || (owner_error != 1) ||
            (epoch_drop != 1) || (numeric_error != 1))
            fail("negative error classification mismatch");

        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        if (weight_wr_accept || owner_error || mask_error || last_error ||
            mode_error || numeric_error || epoch_drop || bank_conflict)
            fail("clear did not reset state and counters");

        // All four ingress interfaces may reject malformed traffic in the
        // same cycle.  Every event must be counted, not overwritten by a
        // later nonblocking assignment.
        @(negedge clk);
        set_wr_token(0, 0);
        weight_wr_numeric_mode = 2'd2;
        row_commit_numeric_mode = 2'd2;
        weight_rd_req_numeric_mode = 2'd2;
        weight_release_numeric_mode = 2'd2;
        weight_wr_valid = 1'b1;
        row_commit_valid = 1'b1;
        weight_rd_req_valid = 1'b1;
        weight_release_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        idle_inputs();
        if (mode_error != 4)
            fail("simultaneous mode errors were not all counted");

        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;

        // Fill all slots while PV is backpressured, then require each READY
        // row to be announced exactly once in deterministic slot order.
        for (rows = 0; rows < 3; rows = rows + 1) begin
            for (key = 0; key < 128; key = key + 1)
                write_key(rows, key);
            commit_row(rows, 32'h3f800000, 32'h3f800000, 1'b1);
        end
        accept_pv_row(0);
        accept_pv_row(1);
        accept_pv_row(2);

        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;

        // Full v3 workload: 4096 rows x 128 writes and reads.
        for (rows = 0; rows < 4096; rows = rows + 1) begin
            active_row_index = rows;
            for (key = 0; key < 128; key = key + 1)
                write_key(rows, key);
            commit_row(rows, 32'h3f800000, 32'h3f800000, 1'b1);
            accept_pv_row(rows);
            issue_all_reads(rows);

            // A release while the final two responses are outstanding is
            // ordinary backpressure, not an ownership error.
            weight_release_epoch = TEST_EPOCH;
            weight_release_group = (rows >> 7) >> 2;
            weight_release_global_q_head = rows >> 7;
            weight_release_row = rows & 127;
            weight_release_slot_id = rows % 3;
            weight_release_numeric_mode = 2'd1;
            weight_release_valid = 1'b1;
            #1;
            if (weight_release_ready)
                fail("release accepted before responses drained");
            @(posedge clk);
            @(negedge clk);
            weight_release_valid = 1'b0;
            release_row(rows);
        end

        repeat (3) @(posedge clk);
        if ((weight_wr_accept != 64'd524288) ||
            (weight_rd_request != 64'd524288) ||
            (weight_rd_response != 64'd524288) ||
            (row_commit_count != 64'd4096) ||
            (pv_row_count != 64'd4096) ||
            (weight_release_count != 64'd4096))
            fail("full workload counter closure mismatch");
        if (owner_error || mask_error || last_error || mode_error ||
            numeric_error || epoch_drop || bank_conflict)
            fail("normal workload has nonzero error counters");
        if (outstanding_max != 64'd2)
            fail("unexpected maximum outstanding read count");

        $display("PASS CATS_R4_IF_V3 weight slots rows=4096 writes=524288 reads=524288 N+2");
        $finish;
    end

    initial begin
        #30000000;
        fail("timeout");
    end
endmodule
