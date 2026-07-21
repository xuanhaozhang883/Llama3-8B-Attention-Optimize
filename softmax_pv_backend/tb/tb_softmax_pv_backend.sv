`timescale 1ns/1ps

module tb_softmax_pv_backend #(
    parameter int Q_HEADS = 4,
    parameter int KV_HEADS = 2,
    parameter int SEQ_LEN = 8,
    parameter int HEAD_DIM = 8,
    parameter int TILE = 2
);

    localparam int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int KV_W   = (KV_HEADS <= 1) ? 1 : $clog2(KV_HEADS);
    localparam int SEQ_W  = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);
    localparam int FEAT_W = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int V_ELEMENTS = KV_HEADS * SEQ_LEN * HEAD_DIM;
    localparam int V_ADDR_W = (V_ELEMENTS <= 1) ? 1 : $clog2(V_ELEMENTS);
    localparam int GROUP_SIZE = Q_HEADS / KV_HEADS;
    localparam int TOTAL_VECS = Q_HEADS * (SEQ_LEN / TILE) *
                                (HEAD_DIM / TILE) * SEQ_LEN;
    // Allow the same testbench to cover the complete 32-head target. The
    // randomized ready pattern needs about five clocks per vector today;
    // twelve leaves margin for future response latency and backpressure.
    localparam longint TIMEOUT_CYCLES = (64'd12 * TOTAL_VECS) + 64'd100000;

    logic clk;
    logic rst_n;
    logic start;

    logic softmax_valid;
    logic softmax_ready;
    logic [15:0] softmax_data;
    logic softmax_last;
    logic [2:0] softmax_group_id;
    logic [HEAD_W-1:0] softmax_head;
    logic [SEQ_W-1:0] softmax_row;
    logic [SEQ_W-1:0] softmax_col;
    logic softmax_first;
    logic softmax_group_last;
    logic [2:0] active_group_id;

    logic v_req_valid;
    logic v_req_ready;
    logic [KV_W-1:0] v_req_kv_head;
    logic [SEQ_W-1:0] v_req_reduce_index;
    logic [FEAT_W-1:0] v_req_feature_base;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [TILE*16-1:0] v_rsp_data;

    logic [TILE*16-1:0] p_vec_bf16;
    logic [TILE*16-1:0] v_vec_bf16;
    logic vec_valid;
    logic vec_ready;
    logic vec_first;
    logic vec_last;
    logic [HEAD_W-1:0] vec_head;
    logic [SEQ_W-1:0] vec_row_base;
    logic [FEAT_W-1:0] vec_feature_base;
    logic [SEQ_W-1:0] vec_reduce_index;

    logic done;
    logic busy;
    logic protocol_error;

    logic v_pending;
    logic [KV_W-1:0] pending_kv_head;
    logic [SEQ_W-1:0] pending_reduce;
    logic [FEAT_W-1:0] pending_feature_base;

    integer errors;
    integer output_count;
    integer request_count;
    integer ready_cycle;
    integer done_seen;
    integer done_count;

    integer exp_head;
    integer exp_row_base;
    integer exp_feature_base;
    integer exp_reduce;

    integer req_exp_head;
    integer req_exp_row_base;
    integer req_exp_feature_base;
    integer req_exp_reduce;

    integer lane;
    integer expected_addr;

    softmax_pv_backend #(
        .Q_HEADS(Q_HEADS),
        .KV_HEADS(KV_HEADS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .TILE(TILE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .group_id(active_group_id),
        .prob_valid(softmax_valid),
        .prob_ready(softmax_ready),
        .prob_data(softmax_data),
        .prob_group_id(softmax_group_id),
        .prob_head(softmax_head),
        .prob_row(softmax_row),
        .prob_col(softmax_col),
        .prob_first(softmax_first),
        .prob_last(softmax_last),
        .prob_group_last(softmax_group_last),
        .v_req_valid(v_req_valid),
        .v_req_ready(v_req_ready),
        .v_req_kv_head(v_req_kv_head),
        .v_req_reduce_index(v_req_reduce_index),
        .v_req_feature_base(v_req_feature_base),
        .v_req_addr(v_req_addr),
        .v_rsp_valid(v_rsp_valid),
        .v_rsp_ready(v_rsp_ready),
        .v_rsp_data(v_rsp_data),
        .p_vec_bf16(p_vec_bf16),
        .v_vec_bf16(v_vec_bf16),
        .vec_valid(vec_valid),
        .vec_ready(vec_ready),
        .vec_first(vec_first),
        .vec_last(vec_last),
        .vec_head(vec_head),
        .vec_row_base(vec_row_base),
        .vec_feature_base(vec_feature_base),
        .vec_reduce_index(vec_reduce_index),
        .done(done),
        .busy(busy),
        .protocol_error(protocol_error)
    );

    always #5 clk = ~clk;

    function automatic [15:0] p_word(input integer h, input integer r, input integer k);
        begin
            p_word = 16'h1000 + h * 16'h0800 + r * 16'h0040 + k;
        end
    endfunction

    function automatic [15:0] v_word(input integer kv, input integer k, input integer f);
        begin
            v_word = 16'h4000 + kv * 16'h1000 + k * 16'h0040 + f;
        end
    endfunction

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic send_probability(input integer h, input integer r, input integer k);
        begin
            @(negedge clk);
            softmax_valid = 1'b1;
            softmax_data  = p_word(h, r, k);
            softmax_last  = (k == SEQ_LEN-1);
            softmax_group_id = active_group_id;
            softmax_head  = h;
            softmax_row   = r;
            softmax_col   = k;
            softmax_first = (k == 0);
            softmax_group_last = (h == Q_HEADS-1) &&
                                 (r == SEQ_LEN-1) &&
                                 (k == SEQ_LEN-1);
            @(posedge clk);
            while (!softmax_ready)
                @(posedge clk);
        end
    endtask

    task automatic feed_probabilities;
        integer h;
        integer r;
        integer k;
        begin
            for (h = 0; h < Q_HEADS; h = h + 1)
                for (r = 0; r < SEQ_LEN; r = r + 1)
                    for (k = 0; k < SEQ_LEN; k = k + 1)
                        send_probability(h, r, k);

            @(negedge clk);
            softmax_valid = 1'b0;
            softmax_last  = 1'b0;
            softmax_first = 1'b0;
            softmax_group_last = 1'b0;
        end
    endtask

    task automatic send_bad_row_last;
        begin
            pulse_start();
            @(negedge clk);
            softmax_valid = 1'b1;
            softmax_data  = 16'h3F80;
            softmax_last  = 1'b1; // Incorrect at column zero when SEQ_LEN > 1.
            softmax_group_id = active_group_id;
            softmax_head  = '0;
            softmax_row   = '0;
            softmax_col   = '0;
            softmax_first = 1'b1;
            softmax_group_last = 1'b0;
            @(posedge clk);
            while (!softmax_ready)
                @(posedge clk);
            @(negedge clk);
            softmax_valid = 1'b0;
            softmax_last  = 1'b0;
            softmax_first = 1'b0;
            softmax_group_last = 1'b0;
            repeat (5) @(posedge clk);
        end
    endtask

    // Backpressure both the external V memory request and the PV consumer.
    always @(negedge clk) begin
        if (!rst_n || start) begin
            ready_cycle <= 0;
            v_req_ready <= 1'b0;
            vec_ready   <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            v_req_ready <= ((ready_cycle % 5) != 1);
            vec_ready   <= ((ready_cycle % 7) != 3);
        end
    end

    // One-outstanding V memory responder with a registered response.
    always @(posedge clk) begin
        if (!rst_n || start) begin
            v_pending           <= 1'b0;
            pending_kv_head     <= '0;
            pending_reduce      <= '0;
            pending_feature_base <= '0;
            v_rsp_valid         <= 1'b0;
            v_rsp_data          <= '0;
        end else begin
            if (v_rsp_valid && v_rsp_ready)
                v_rsp_valid <= 1'b0;

            if (v_req_valid && v_req_ready) begin
                if (v_pending || v_rsp_valid) begin
                    $display("ERROR: more than one V request outstanding");
                    errors = errors + 1;
                end
                v_pending            <= 1'b1;
                pending_kv_head      <= v_req_kv_head;
                pending_reduce       <= v_req_reduce_index;
                pending_feature_base <= v_req_feature_base;
            end

            if (v_pending && !v_rsp_valid) begin
                for (lane = 0; lane < TILE; lane = lane + 1)
                    v_rsp_data[lane*16 +: 16] <=
                        v_word(pending_kv_head, pending_reduce,
                               pending_feature_base + lane);
                v_rsp_valid <= 1'b1;
                v_pending   <= 1'b0;
            end
        end
    end

    // Check every generated V address and the request schedule.
    logic request_hold_active;
    logic [KV_W-1:0] request_hold_kv_head;
    logic [SEQ_W-1:0] request_hold_reduce;
    logic [FEAT_W-1:0] request_hold_feature_base;
    logic [V_ADDR_W-1:0] request_hold_addr;

    always @(posedge clk) begin
        if (!rst_n || start) begin
            request_count        <= 0;
            req_exp_head         <= 0;
            req_exp_row_base     <= 0;
            req_exp_feature_base <= 0;
            req_exp_reduce       <= 0;
            request_hold_active       <= 1'b0;
            request_hold_kv_head      <= '0;
            request_hold_reduce       <= '0;
            request_hold_feature_base <= '0;
            request_hold_addr         <= '0;
        end else begin
            if (request_hold_active) begin
                if (!v_req_valid ||
                    v_req_kv_head !== request_hold_kv_head ||
                    v_req_reduce_index !== request_hold_reduce ||
                    v_req_feature_base !== request_hold_feature_base ||
                    v_req_addr !== request_hold_addr) begin
                    $display("ERROR: V request changed while stalled");
                    errors = errors + 1;
                end
            end

            if (v_req_valid && !v_req_ready) begin
                if (!request_hold_active) begin
                    request_hold_kv_head      <= v_req_kv_head;
                    request_hold_reduce       <= v_req_reduce_index;
                    request_hold_feature_base <= v_req_feature_base;
                    request_hold_addr         <= v_req_addr;
                end
                request_hold_active <= 1'b1;
            end else begin
                request_hold_active <= 1'b0;
            end

            if (v_req_valid && v_req_ready) begin
                expected_addr = (((req_exp_head / GROUP_SIZE) * SEQ_LEN) +
                                 req_exp_reduce) * HEAD_DIM + req_exp_feature_base;

                if (($unsigned(v_req_kv_head) != (req_exp_head / GROUP_SIZE)) ||
                    ($unsigned(v_req_reduce_index) != req_exp_reduce) ||
                    ($unsigned(v_req_feature_base) != req_exp_feature_base) ||
                    ($unsigned(v_req_addr) != expected_addr)) begin
                    $display("ERROR: V request got kv=%0d reduce=%0d feature=%0d addr=%0d expected kv=%0d reduce=%0d feature=%0d addr=%0d",
                             v_req_kv_head, v_req_reduce_index,
                             v_req_feature_base, v_req_addr,
                             req_exp_head / GROUP_SIZE, req_exp_reduce,
                             req_exp_feature_base, expected_addr);
                    errors = errors + 1;
                end

                request_count <= request_count + 1;
                if (req_exp_reduce == SEQ_LEN-1) begin
                    req_exp_reduce <= 0;
                    if (req_exp_feature_base + TILE < HEAD_DIM) begin
                        req_exp_feature_base <= req_exp_feature_base + TILE;
                    end else begin
                        req_exp_feature_base <= 0;
                        if (req_exp_row_base + TILE < SEQ_LEN) begin
                            req_exp_row_base <= req_exp_row_base + TILE;
                        end else begin
                            req_exp_row_base <= 0;
                            req_exp_head <= req_exp_head + 1;
                        end
                    end
                end else begin
                    req_exp_reduce <= req_exp_reduce + 1;
                end
            end
        end
    end

    // Check P replay, V vector contents, metadata and output stability.
    logic hold_active;
    logic [TILE*16-1:0] hold_p;
    logic [TILE*16-1:0] hold_v;
    logic hold_first;
    logic hold_last;
    logic [HEAD_W-1:0] hold_head;
    logic [SEQ_W-1:0] hold_row_base;
    logic [FEAT_W-1:0] hold_feature_base;
    logic [SEQ_W-1:0] hold_reduce;

    always @(posedge clk) begin
        if (!rst_n || start) begin
            output_count    <= 0;
            exp_head        <= 0;
            exp_row_base    <= 0;
            exp_feature_base <= 0;
            exp_reduce      <= 0;
            done_seen       <= 0;
            done_count      <= 0;
            hold_active     <= 1'b0;
            hold_p          <= '0;
            hold_v          <= '0;
            hold_first      <= 1'b0;
            hold_last       <= 1'b0;
            hold_head       <= '0;
            hold_row_base   <= '0;
            hold_feature_base <= '0;
            hold_reduce     <= '0;
        end else begin
            if (done) begin
                done_seen <= 1;
                done_count <= done_count + 1;
                if (busy) begin
                    $display("ERROR: done asserted while backend is busy");
                    errors = errors + 1;
                end
            end

            if (hold_active) begin
                if (!vec_valid || p_vec_bf16 !== hold_p ||
                    v_vec_bf16 !== hold_v || vec_first !== hold_first ||
                    vec_last !== hold_last || vec_head !== hold_head ||
                    vec_row_base !== hold_row_base ||
                    vec_feature_base !== hold_feature_base ||
                    vec_reduce_index !== hold_reduce) begin
                    $display("ERROR: PV vector changed while stalled");
                    errors = errors + 1;
                end
            end

            if (vec_valid && !vec_ready) begin
                if (!hold_active) begin
                    hold_p     <= p_vec_bf16;
                    hold_v     <= v_vec_bf16;
                    hold_first <= vec_first;
                    hold_last  <= vec_last;
                    hold_head  <= vec_head;
                    hold_row_base <= vec_row_base;
                    hold_feature_base <= vec_feature_base;
                    hold_reduce <= vec_reduce_index;
                end
                hold_active <= 1'b1;
            end else begin
                hold_active <= 1'b0;
            end

            if (vec_valid && vec_ready) begin
                if (($unsigned(vec_head) != exp_head) ||
                    ($unsigned(vec_row_base) != exp_row_base) ||
                    ($unsigned(vec_feature_base) != exp_feature_base) ||
                    ($unsigned(vec_reduce_index) != exp_reduce) ||
                    (vec_first != (exp_reduce == 0)) ||
                    (vec_last != (exp_reduce == SEQ_LEN-1))) begin
                    $display("ERROR: vec metadata h=%0d row=%0d feature=%0d reduce=%0d",
                             vec_head, vec_row_base,
                             vec_feature_base, vec_reduce_index);
                    errors = errors + 1;
                end

                for (lane = 0; lane < TILE; lane = lane + 1) begin
                    if (p_vec_bf16[lane*16 +: 16] !==
                        p_word(exp_head, exp_row_base + lane, exp_reduce)) begin
                        $display("ERROR: P lane=%0d h=%0d row_base=%0d feature=%0d reduce=%0d got=%h",
                                 lane, exp_head, exp_row_base,
                                 exp_feature_base, exp_reduce,
                                 p_vec_bf16[lane*16 +: 16]);
                        errors = errors + 1;
                    end

                    if (v_vec_bf16[lane*16 +: 16] !==
                        v_word(exp_head / GROUP_SIZE, exp_reduce,
                               exp_feature_base + lane)) begin
                        $display("ERROR: V lane=%0d h=%0d feature=%0d reduce=%0d got=%h",
                                 lane, exp_head, exp_feature_base, exp_reduce,
                                 v_vec_bf16[lane*16 +: 16]);
                        errors = errors + 1;
                    end
                end

                output_count <= output_count + 1;
                if (exp_reduce == SEQ_LEN-1) begin
                    exp_reduce <= 0;
                    if (exp_feature_base + TILE < HEAD_DIM) begin
                        exp_feature_base <= exp_feature_base + TILE;
                    end else begin
                        exp_feature_base <= 0;
                        if (exp_row_base + TILE < SEQ_LEN) begin
                            exp_row_base <= exp_row_base + TILE;
                        end else begin
                            exp_row_base <= 0;
                            exp_head <= exp_head + 1;
                        end
                    end
                end else begin
                    exp_reduce <= exp_reduce + 1;
                end
            end
        end
    end

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        start         = 1'b0;
        softmax_valid = 1'b0;
        softmax_data  = '0;
        softmax_last  = 1'b0;
        softmax_group_id = '0;
        softmax_head  = '0;
        softmax_row   = '0;
        softmax_col   = '0;
        softmax_first = 1'b0;
        softmax_group_last = 1'b0;
        active_group_id = 3'd0;
        v_req_ready   = 1'b0;
        v_rsp_valid   = 1'b0;
        v_rsp_data    = '0;
        vec_ready     = 1'b0;
        errors        = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if (busy || softmax_ready) begin
            $display("ERROR: backend is active before start");
            errors = errors + 1;
        end
        pulse_start();

        fork
            feed_probabilities();
            begin
                wait (done_seen == 1);
            end
        join

        wait (!busy);
        repeat (6) @(posedge clk);

        if (protocol_error) begin
            $display("ERROR: backend protocol_error asserted");
            errors = errors + 1;
        end
        if (output_count != TOTAL_VECS || request_count != TOTAL_VECS) begin
            $display("ERROR: counts output=%0d request=%0d expected=%0d",
                     output_count, request_count, TOTAL_VECS);
            errors = errors + 1;
        end
        if (done_count != 1) begin
            $display("ERROR: done pulse count=%0d expected=1", done_count);
            errors = errors + 1;
        end
        if (errors != 0)
            $fatal(1, "FAIL: softmax_pv_backend errors=%0d", errors);

        $display("PASS: Softmax -> P buffer -> PV loader, vectors=%0d", output_count);
        send_bad_row_last();
        if (!protocol_error)
            $fatal(1, "FAIL: malformed Softmax row_last was not detected");
        $display("PASS: malformed Softmax row_last raises protocol_error");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "TIMEOUT: softmax_pv_backend test did not finish");
    end

endmodule
