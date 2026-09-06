// Protocol and counter regression for cats_r4_qk_32lane_scheduler.
module tb_cats_r4_qk_32lane_scheduler;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic start_valid, start_ready;
    logic [15:0] start_epoch;
    logic [2:0] start_group;
    logic [4:0] start_global_q_head;
    logic [2:0] start_row_window;
    logic [4:0] start_row_count;
    logic [1:0] start_key_block;
    logic done_valid, done_ready;
    logic [15:0] done_epoch;
    logic [2:0] done_group;
    logic [4:0] done_global_q_head;
    logic [2:0] done_row_window;
    logic [1:0] done_key_block;
    logic done_error;

    logic q_req_valid, q_req_ready;
    logic [3:0] q_req_context_tag;
    logic [6:0] q_req_d;
    logic q_rsp_valid;
    logic [3:0] q_rsp_context_tag;
    logic [15:0] q_rsp_bf16;

    logic k_req_valid, k_req_ready;
    logic [3:0] k_req_context_tag;
    logic [1:0] k_req_key_block;
    logic [6:0] k_req_d;
    logic k_rsp_valid;
    logic [3:0] k_rsp_context_tag;
    logic [511:0] k_rsp_vec;

    logic mac_valid, mac_ready;
    logic [15:0] mac_epoch;
    logic [2:0] mac_group;
    logic [4:0] mac_global_q_head;
    logic [6:0] mac_row;
    logic [1:0] mac_key_block;
    logic [3:0] mac_context_tag;
    logic [6:0] mac_d;
    logic [31:0] mac_lane_valid;
    logic mac_first, mac_last;
    logic [15:0] mac_q_bf16;
    logic [511:0] mac_k_vec;

    logic mac_rsp_valid, mac_rsp_ready;
    logic [15:0] mac_rsp_epoch;
    logic [2:0] mac_rsp_group;
    logic [4:0] mac_rsp_global_q_head;
    logic [6:0] mac_rsp_row;
    logic [1:0] mac_rsp_key_block;
    logic [3:0] mac_rsp_context_tag;
    logic [6:0] mac_rsp_d;

    logic [63:0] q_requests_accepted, k_requests_accepted;
    logic [63:0] mac_steps_issued, mac_steps_completed;
    logic [63:0] valid_macs, causal_lane_bubbles;
    logic [63:0] causal_rows_skipped;
    logic [63:0] memory_request_stalls, mac_issue_stalls;
    logic [63:0] protocol_errors;
    logic protocol_error_sticky;

    cats_r4_qk_32lane_scheduler dut (.*);

    logic [31:0] lfsr = 32'h1ace_b00c;
    assign q_req_ready = lfsr[0] | lfsr[5];
    assign k_req_ready = lfsr[1] | lfsr[7];
    assign mac_ready = lfsr[2] | lfsr[9];

    logic q_pipe_valid [0:1];
    logic [3:0] q_pipe_context [0:1];
    logic [6:0] q_pipe_d [0:1];
    logic k_pipe_valid [0:1];
    logic [3:0] k_pipe_context [0:1];
    logic [6:0] k_pipe_d [0:1];
    logic [1:0] k_pipe_block [0:1];

    logic [15:0] model_pending;
    logic [4:0] model_delay [0:15];
    logic [15:0] model_epoch [0:15];
    logic [2:0] model_group [0:15];
    logic [4:0] model_head [0:15];
    logic [6:0] model_row [0:15];
    logic [1:0] model_block [0:15];
    logic [6:0] model_d [0:15];
    logic [7:0] expected_d [0:15];

    logic prev_q_stall, prev_k_stall, prev_mac_stall;
    logic [10:0] prev_q_payload;
    logic [12:0] prev_k_payload;
    logic [1096:0] prev_mac_payload;

    integer i;
    integer due_index;
    integer timeout_cycles;

    function automatic [15:0] q_word(
        input logic [3:0] context_value,
        input logic [6:0] d_value
    );
        q_word = {5'd0, d_value, context_value};
    endfunction

    function automatic [15:0] k_word(
        input logic [3:0] context_value,
        input logic [6:0] d_value,
        input logic [1:0] block_value
    );
        k_word = {3'd0, block_value, d_value, context_value};
    endfunction

    function automatic [31:0] expected_mask(
        input logic [6:0] row_value,
        input logic [1:0] block_value
    );
        integer lane;
        begin
            expected_mask = 0;
            for (lane = 0; lane < 32; lane = lane + 1)
                if ((block_value * 32 + lane) <= row_value)
                    expected_mask[lane] = 1;
        end
    endfunction

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic pulse_counter_clear;
        begin
            @(negedge clk);
            counter_clear = 1;
            @(negedge clk);
            counter_clear = 0;
        end
    endtask

    task automatic launch_job(
        input logic [15:0] epoch_value,
        input logic [2:0] group_value,
        input logic [4:0] head_value,
        input logic [2:0] window_value,
        input logic [4:0] count_value,
        input logic [1:0] block_value
    );
        begin
            while (!start_ready) tick();
            @(negedge clk);
            start_epoch = epoch_value;
            start_group = group_value;
            start_global_q_head = head_value;
            start_row_window = window_value;
            start_row_count = count_value;
            start_key_block = block_value;
            start_valid = 1;
            @(negedge clk);
            start_valid = 0;
        end
    endtask

    task automatic wait_for_done(input logic expected_error);
        logic [31:0] held_done;
        begin
            timeout_cycles = 0;
            done_ready = 0;
            while (!done_valid && timeout_cycles < 200000) begin
                tick();
                timeout_cycles = timeout_cycles + 1;
            end
            if (!done_valid)
                $fatal(1, "timeout waiting for done");
            if (done_error !== expected_error)
                $fatal(1, "done_error mismatch expected=%0d actual=%0d",
                       expected_error, done_error);
            held_done = {done_epoch, done_group, done_global_q_head,
                         done_row_window, done_key_block, done_error, 2'd0};
            repeat (4) begin
                tick();
                if ({done_epoch, done_group, done_global_q_head,
                     done_row_window, done_key_block, done_error, 2'd0}
                    !== held_done)
                    $fatal(1, "done payload changed under backpressure");
            end
            @(negedge clk);
            done_ready = 1;
            tick();
            @(negedge clk);
            done_ready = 0;
        end
    endtask

    always_ff @(posedge clk) begin : p_models
        integer model_index;
        integer emit_index;

        if (!rst_n || clear) begin
            lfsr <= 32'h1ace_b00c;
            q_pipe_valid[0] <= 0;
            q_pipe_valid[1] <= 0;
            k_pipe_valid[0] <= 0;
            k_pipe_valid[1] <= 0;
            q_rsp_valid <= 0;
            q_rsp_context_tag <= 0;
            q_rsp_bf16 <= 0;
            k_rsp_valid <= 0;
            k_rsp_context_tag <= 0;
            k_rsp_vec <= 0;
            mac_rsp_valid <= 0;
            mac_rsp_epoch <= 0;
            mac_rsp_group <= 0;
            mac_rsp_global_q_head <= 0;
            mac_rsp_row <= 0;
            mac_rsp_key_block <= 0;
            mac_rsp_context_tag <= 0;
            mac_rsp_d <= 0;
            model_pending <= 0;
            prev_q_stall <= 0;
            prev_k_stall <= 0;
            prev_mac_stall <= 0;
            for (model_index = 0; model_index < 16;
                 model_index = model_index + 1) begin
                model_delay[model_index] <= 0;
                model_epoch[model_index] <= 0;
                model_group[model_index] <= 0;
                model_head[model_index] <= 0;
                model_row[model_index] <= 0;
                model_block[model_index] <= 0;
                model_d[model_index] <= 0;
                expected_d[model_index] <= 0;
            end
        end else begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

            if (prev_q_stall &&
                {q_req_context_tag, q_req_d} !== prev_q_payload)
                $fatal(1, "Q request changed while stalled");
            if (prev_k_stall &&
                {k_req_context_tag, k_req_key_block, k_req_d}
                !== prev_k_payload)
                $fatal(1, "K request changed while stalled");
            if (prev_mac_stall &&
                {mac_epoch, mac_group, mac_global_q_head, mac_row,
                 mac_key_block, mac_context_tag, mac_d, mac_lane_valid,
                 mac_first, mac_last, mac_q_bf16, mac_k_vec}
                !== prev_mac_payload)
                $fatal(1, "MAC payload changed while stalled");

            prev_q_stall <= q_req_valid && !q_req_ready;
            prev_k_stall <= k_req_valid && !k_req_ready;
            prev_mac_stall <= mac_valid && !mac_ready;
            prev_q_payload <= {q_req_context_tag, q_req_d};
            prev_k_payload <=
                {k_req_context_tag, k_req_key_block, k_req_d};
            prev_mac_payload <=
                {mac_epoch, mac_group, mac_global_q_head, mac_row,
                 mac_key_block, mac_context_tag, mac_d, mac_lane_valid,
                 mac_first, mac_last, mac_q_bf16, mac_k_vec};

            q_rsp_valid <= q_pipe_valid[1];
            q_rsp_context_tag <= q_pipe_context[1];
            q_rsp_bf16 <= q_word(q_pipe_context[1], q_pipe_d[1]);
            q_pipe_valid[1] <= q_pipe_valid[0];
            q_pipe_context[1] <= q_pipe_context[0];
            q_pipe_d[1] <= q_pipe_d[0];
            q_pipe_valid[0] <= q_req_valid && q_req_ready;
            q_pipe_context[0] <= q_req_context_tag;
            q_pipe_d[0] <= q_req_d;

            k_rsp_valid <= k_pipe_valid[1];
            k_rsp_context_tag <= k_pipe_context[1];
            for (model_index = 0; model_index < 32;
                 model_index = model_index + 1)
                k_rsp_vec[model_index*16 +: 16] <=
                    k_word(k_pipe_context[1], k_pipe_d[1],
                           k_pipe_block[1]);
            k_pipe_valid[1] <= k_pipe_valid[0];
            k_pipe_context[1] <= k_pipe_context[0];
            k_pipe_d[1] <= k_pipe_d[0];
            k_pipe_block[1] <= k_pipe_block[0];
            k_pipe_valid[0] <= k_req_valid && k_req_ready;
            k_pipe_context[0] <= k_req_context_tag;
            k_pipe_d[0] <= k_req_d;
            k_pipe_block[0] <= k_req_key_block;

            if (mac_valid && mac_ready) begin
                if (model_pending[mac_context_tag])
                    $fatal(1, "context reused before MAC completion");
                if (mac_d !== expected_d[mac_context_tag][6:0])
                    $fatal(1, "d order mismatch ctx=%0d exp=%0d got=%0d",
                           mac_context_tag,
                           expected_d[mac_context_tag], mac_d);
                if (mac_first !== (mac_d == 0) ||
                    mac_last !== (mac_d == 127))
                    $fatal(1, "first/last mismatch");
                if (mac_lane_valid !==
                    expected_mask(mac_row, mac_key_block))
                    $fatal(1, "causal lane mask mismatch row=%0d block=%0d",
                           mac_row, mac_key_block);
                if (mac_q_bf16 !== q_word(mac_context_tag, mac_d))
                    $fatal(1, "Q payload/tag mismatch");
                if (mac_k_vec[15:0] !==
                    k_word(mac_context_tag, mac_d, mac_key_block))
                    $fatal(1, "K payload/tag mismatch");
                model_pending[mac_context_tag] <= 1;
                model_delay[mac_context_tag] <=
                    2 + {2'd0, lfsr[13:11]};
                model_epoch[mac_context_tag] <= mac_epoch;
                model_group[mac_context_tag] <= mac_group;
                model_head[mac_context_tag] <= mac_global_q_head;
                model_row[mac_context_tag] <= mac_row;
                model_block[mac_context_tag] <= mac_key_block;
                model_d[mac_context_tag] <= mac_d;
                expected_d[mac_context_tag] <=
                    expected_d[mac_context_tag] + 1;
            end

            for (model_index = 0; model_index < 16;
                 model_index = model_index + 1)
                if (model_pending[model_index] &&
                    (model_delay[model_index] != 0))
                    model_delay[model_index] <=
                        model_delay[model_index] - 1;

            mac_rsp_valid <= 0;
            emit_index = -1;
            for (model_index = 0; model_index < 16;
                 model_index = model_index + 1)
                if ((emit_index < 0) && model_pending[model_index] &&
                    (model_delay[model_index] == 0))
                    emit_index = model_index;
            if (emit_index >= 0) begin
                mac_rsp_valid <= 1;
                mac_rsp_epoch <= model_epoch[emit_index];
                mac_rsp_group <= model_group[emit_index];
                mac_rsp_global_q_head <= model_head[emit_index];
                mac_rsp_row <= model_row[emit_index];
                mac_rsp_key_block <= model_block[emit_index];
                mac_rsp_context_tag <= emit_index[3:0];
                mac_rsp_d <= model_d[emit_index];
                model_pending[emit_index] <= 0;
            end
        end
    end

    initial begin
        start_valid = 0;
        start_epoch = 0;
        start_group = 0;
        start_global_q_head = 0;
        start_row_window = 0;
        start_row_count = 0;
        start_key_block = 0;
        done_ready = 0;

        repeat (5) tick();
        rst_n = 1;
        repeat (2) tick();

        pulse_counter_clear();
        for (i = 0; i < 16; i = i + 1)
            expected_d[i] = 0;
        launch_job(16'h12, 3'd0, 5'd0, 3'd0, 5'd16, 2'd0);
        wait_for_done(0);
        if (q_requests_accepted != 2048 ||
            k_requests_accepted != 2048 ||
            mac_steps_issued != 2048 ||
            mac_steps_completed != 2048)
            $fatal(1, "full tile step counters mismatch q=%0d k=%0d i=%0d r=%0d",
                   q_requests_accepted, k_requests_accepted,
                   mac_steps_issued, mac_steps_completed);
        if (valid_macs != 17408 || causal_lane_bubbles != 48128)
            $fatal(1, "full tile causal counters mismatch valid=%0d bubble=%0d",
                   valid_macs, causal_lane_bubbles);
        if (causal_rows_skipped != 0 || protocol_errors != 0)
            $fatal(1, "unexpected full tile skip/error");
        if (memory_request_stalls == 0 || mac_issue_stalls == 0)
            $fatal(1, "random backpressure did not exercise stalls");

        pulse_counter_clear();
        for (i = 0; i < 16; i = i + 1)
            expected_d[i] = 0;
        launch_job(16'h13, 3'd0, 5'd1, 3'd0, 5'd16, 2'd1);
        wait_for_done(0);
        if (q_requests_accepted != 0 || k_requests_accepted != 0 ||
            mac_steps_issued != 0 || mac_steps_completed != 0 ||
            valid_macs != 0 || causal_lane_bubbles != 0 ||
            causal_rows_skipped != 16 || protocol_errors != 0)
            $fatal(1, "wholly masked tile counters mismatch");

        pulse_counter_clear();
        for (i = 0; i < 16; i = i + 1)
            expected_d[i] = 0;
        launch_job(16'h14, 3'd1, 5'd4, 3'd2, 5'd5, 2'd1);
        wait_for_done(0);
        if (q_requests_accepted != 640 ||
            k_requests_accepted != 640 ||
            mac_steps_issued != 640 ||
            mac_steps_completed != 640)
            $fatal(1, "short tile step counters mismatch");
        if (valid_macs != 1920 || causal_lane_bubbles != 18560 ||
            causal_rows_skipped != 0 || protocol_errors != 0)
            $fatal(1, "short tile causal counters mismatch");

        pulse_counter_clear();
        launch_job(16'h15, 3'd1, 5'd0, 3'd0, 5'd16, 2'd0);
        wait_for_done(1);
        if (protocol_errors != 1 || !protocol_error_sticky ||
            q_requests_accepted != 0 || k_requests_accepted != 0 ||
            mac_steps_issued != 0)
            $fatal(1, "invalid start gate mismatch");

        $display("PASS: CATS-R4 R16/32-lane QK scheduler tags, causal mask, stalls, and counters");
        $finish;
    end
endmodule
