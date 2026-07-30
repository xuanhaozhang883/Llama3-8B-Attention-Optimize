`timescale 1ns/1ps

module tb_gqa_pingpong_buffer;

    localparam int SEQ_LEN      = 4;
    localparam int HEAD_DIM     = 4;
    localparam int Q_HEADS      = 4;
    localparam int GQA_GROUPS   = 8;
    localparam int HEAD_W       = 2;
    localparam int GROUP_W      = 3;
    localparam int GLOBAL_Q_HEAD_W = 5;
    localparam int POS_W        = 2;
    localparam int DIM_W        = 2;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic fill_start;
    logic fill_bank;
    logic [GROUP_W-1:0] fill_group_id;
    logic fill_ready;
    logic [31:0] in_p_vec_bf16;
    logic [31:0] in_v_vec_bf16;
    logic in_valid;
    logic in_ready;
    logic in_first;
    logic in_last;
    logic in_group_last;
    logic [GROUP_W-1:0] in_group_id;
    logic [HEAD_W-1:0] in_head;
    logic [GLOBAL_Q_HEAD_W-1:0] in_global_q_head;
    logic [POS_W-1:0] in_row_base;
    logic [DIM_W-1:0] in_feature_base;
    logic [POS_W-1:0] in_reduce_index;
    logic fill_done;
    logic fill_done_bank;
    logic [GROUP_W-1:0] fill_done_group_id;

    logic drain_start;
    logic drain_bank;
    logic [GROUP_W-1:0] drain_group_id;
    logic drain_ready;
    logic release_valid;
    logic release_bank;
    logic [GROUP_W-1:0] release_group_id;

    logic [HEAD_W-1:0] req_head;
    logic [POS_W-1:0] req_row_base;
    logic [DIM_W-1:0] req_col_base;
    logic [POS_W-1:0] req_reduce;
    logic [63:0] out_p_vec_bf16;
    logic [63:0] out_v_vec_bf16;
    logic out_valid;
    logic out_ready;

    logic [1:0] bank0_state;
    logic [1:0] bank1_state;
    logic [GROUP_W-1:0] bank0_group_id;
    logic [GROUP_W-1:0] bank1_group_id;
    logic protocol_error;
    logic [31:0] invalid_fill_count;
    logic [31:0] invalid_drain_count;
    logic [31:0] bank_conflict_count;

    integer producer_vectors;
    integer consumer_vectors;
    integer overlap_cycles;

    gqa_pingpong_buffer #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .fill_start(fill_start),
        .fill_bank(fill_bank),
        .fill_group_id(fill_group_id),
        .fill_ready(fill_ready),
        .in_p_vec_bf16(in_p_vec_bf16),
        .in_v_vec_bf16(in_v_vec_bf16),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_first(in_first),
        .in_last(in_last),
        .in_group_last(in_group_last),
        .in_group_id(in_group_id),
        .in_head(in_head),
        .in_global_q_head(in_global_q_head),
        .in_row_base(in_row_base),
        .in_feature_base(in_feature_base),
        .in_reduce_index(in_reduce_index),
        .fill_done(fill_done),
        .fill_done_bank(fill_done_bank),
        .fill_done_group_id(fill_done_group_id),
        .drain_start(drain_start),
        .drain_bank(drain_bank),
        .drain_group_id(drain_group_id),
        .drain_ready(drain_ready),
        .release_valid(release_valid),
        .release_bank(release_bank),
        .release_group_id(release_group_id),
        .req_head(req_head),
        .req_row_base(req_row_base),
        .req_col_base(req_col_base),
        .req_reduce(req_reduce),
        .out_p_vec_bf16(out_p_vec_bf16),
        .out_v_vec_bf16(out_v_vec_bf16),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .bank0_state(bank0_state),
        .bank1_state(bank1_state),
        .bank0_group_id(bank0_group_id),
        .bank1_group_id(bank1_group_id),
        .protocol_error(protocol_error),
        .invalid_fill_count(invalid_fill_count),
        .invalid_drain_count(invalid_drain_count),
        .bank_conflict_count(bank_conflict_count)
    );

    function automatic logic [15:0] p_value(
        input int group_id,
        input int head,
        input int row,
        input int reduce
    );
        p_value =
            16'h1000 +
            (group_id << 11) +
            (head << 7) +
            (row << 4) +
            reduce;
    endfunction

    function automatic logic [15:0] v_value(
        input int group_id,
        input int reduce,
        input int dim
    );
        v_value =
            16'h5000 +
            (group_id << 11) +
            (reduce << 4) +
            dim;
    endfunction

    task automatic fill_one_group(
        input logic bank,
        input int group_id
    );
        int head;
        int row_base;
        int feature_base;
        int reduce;
        begin
            @(negedge clk);
            fill_bank     = bank;
            fill_group_id = group_id[GROUP_W-1:0];

            while (!fill_ready)
                @(posedge clk);

            @(negedge clk);
            fill_start    = 1'b1;
            @(negedge clk);
            fill_start    = 1'b0;

            for (head = 0; head < Q_HEADS; head = head + 1) begin
                for (row_base = 0;
                     row_base < SEQ_LEN;
                     row_base = row_base + 2) begin
                    for (feature_base = 0;
                         feature_base < HEAD_DIM;
                         feature_base = feature_base + 2) begin
                        for (reduce = 0;
                             reduce < SEQ_LEN;
                             reduce = reduce + 1) begin
                            @(negedge clk);
                            in_group_id      = group_id[GROUP_W-1:0];
                            in_head          = head[HEAD_W-1:0];
                            in_global_q_head =
                                (group_id*Q_HEADS + head);
                            in_row_base      = row_base[POS_W-1:0];
                            in_feature_base  =
                                feature_base[DIM_W-1:0];
                            in_reduce_index  = reduce[POS_W-1:0];
                            in_first         = (reduce == 0);
                            in_last          = (reduce == SEQ_LEN-1);
                            in_group_last    =
                                (head == Q_HEADS-1) &&
                                (row_base == SEQ_LEN-2) &&
                                (feature_base == HEAD_DIM-2) &&
                                (reduce == SEQ_LEN-1);
                            in_p_vec_bf16 = {
                                p_value(group_id, head,
                                        row_base+1, reduce),
                                p_value(group_id, head,
                                        row_base, reduce)
                            };
                            in_v_vec_bf16 = {
                                v_value(group_id, reduce,
                                        feature_base+1),
                                v_value(group_id, reduce,
                                        feature_base)
                            };
                            in_valid = 1'b1;

                            do begin
                                @(posedge clk);
                            end while (!in_ready);
                            producer_vectors = producer_vectors + 1;
                        end
                    end
                end
            end

            @(negedge clk);
            in_valid = 1'b0;

            while (!fill_done)
                @(posedge clk);

            assert (fill_done_bank == bank)
                else $fatal(1, "fill_done Bank mismatch");
            assert (fill_done_group_id == group_id[GROUP_W-1:0])
                else $fatal(1, "fill_done Group mismatch");
        end
    endtask

    task automatic drain_one_group(
        input logic bank,
        input int group_id
    );
        int head;
        int reduce;
        logic [63:0] expected_p;
        logic [63:0] expected_v;
        int stall_seed;
        begin
            // Wait for this exact Bank/Group to be READY.
            drain_bank     = bank;
            drain_group_id = group_id[GROUP_W-1:0];
            while (!drain_ready)
                @(posedge clk);

            @(negedge clk);
            drain_start = 1'b1;
            @(negedge clk);
            drain_start = 1'b0;

            for (head = 0; head < Q_HEADS; head = head + 1) begin
                for (reduce = 0;
                     reduce < SEQ_LEN;
                     reduce = reduce + 1) begin
                    @(negedge clk);
                    req_head     = head[HEAD_W-1:0];
                    req_row_base = '0;
                    req_col_base = '0;
                    req_reduce   = reduce[POS_W-1:0];

                    expected_p = {
                        p_value(group_id, head, 3, reduce),
                        p_value(group_id, head, 2, reduce),
                        p_value(group_id, head, 1, reduce),
                        p_value(group_id, head, 0, reduce)
                    };
                    expected_v = {
                        v_value(group_id, reduce, 3),
                        v_value(group_id, reduce, 2),
                        v_value(group_id, reduce, 1),
                        v_value(group_id, reduce, 0)
                    };

                    // Deterministic pseudo-random backpressure: every third
                    // candidate cycle is stalled.
                    stall_seed = head*SEQ_LEN + reduce;
                    out_ready = 1'b0;
                    repeat ((stall_seed % 3) + 1)
                        @(posedge clk);
                    @(negedge clk);
                    out_ready = 1'b1;

                    do begin
                        @(posedge clk);
                    end while (!out_valid);

                    assert (out_p_vec_bf16 === expected_p)
                        else $fatal(1,
                            "P mismatch g=%0d h=%0d r=%0d exp=%h got=%h",
                            group_id, head, reduce,
                            expected_p, out_p_vec_bf16);
                    assert (out_v_vec_bf16 === expected_v)
                        else $fatal(1,
                            "V mismatch g=%0d h=%0d r=%0d exp=%h got=%h",
                            group_id, head, reduce,
                            expected_v, out_v_vec_bf16);
                    consumer_vectors = consumer_vectors + 1;
                    @(negedge clk);
                    out_ready = 1'b0;
                end
            end

            @(negedge clk);
            release_bank     = bank;
            release_group_id = group_id[GROUP_W-1:0];
            release_valid    = 1'b1;
            @(negedge clk);
            release_valid    = 1'b0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            overlap_cycles <= 0;
        end else if (in_valid && in_ready &&
                     out_valid && out_ready) begin
            overlap_cycles <= overlap_cycles + 1;
        end
    end

    initial begin
        fill_start       = 1'b0;
        fill_bank        = 1'b0;
        fill_group_id    = '0;
        in_p_vec_bf16    = '0;
        in_v_vec_bf16    = '0;
        in_valid         = 1'b0;
        in_first         = 1'b0;
        in_last          = 1'b0;
        in_group_last    = 1'b0;
        in_group_id      = '0;
        in_head          = '0;
        in_global_q_head = '0;
        in_row_base      = '0;
        in_feature_base  = '0;
        in_reduce_index  = '0;

        drain_start      = 1'b0;
        drain_bank       = 1'b0;
        drain_group_id   = '0;
        release_valid    = 1'b0;
        release_bank     = 1'b0;
        release_group_id = '0;
        req_head         = '0;
        req_row_base     = '0;
        req_col_base     = '0;
        req_reduce       = '0;
        out_ready        = 1'b0;

        producer_vectors = 0;
        consumer_vectors = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Prologue: fill Bank 0.
        fill_one_group(1'b0, 0);

        // Steady state: drain Group 0 while Group 1 fills the other Bank.
        fork
            drain_one_group(1'b0, 0);
            fill_one_group(1'b1, 1);
        join

        // Epilogue: drain the second Bank.
        drain_one_group(1'b1, 1);
        repeat (3) @(posedge clk);

        assert (!protocol_error)
            else $fatal(1, "Buffer protocol_error asserted");
        assert (invalid_fill_count == 0)
            else $fatal(1, "invalid_fill_count=%0d",
                        invalid_fill_count);
        assert (invalid_drain_count == 0)
            else $fatal(1, "invalid_drain_count=%0d",
                        invalid_drain_count);
        assert (bank_conflict_count == 0)
            else $fatal(1, "bank_conflict_count=%0d",
                        bank_conflict_count);
        assert (producer_vectors == 2*Q_HEADS*2*2*SEQ_LEN)
            else $fatal(1, "Producer vector count=%0d",
                        producer_vectors);
        assert (consumer_vectors == 2*Q_HEADS*SEQ_LEN)
            else $fatal(1, "Consumer vector count=%0d",
                        consumer_vectors);
        assert (overlap_cycles > 0)
            else $fatal(1, "No fill/drain overlap observed");
        assert (bank0_state == 2'd0 && bank1_state == 2'd0)
            else $fatal(1, "Banks not EMPTY after release");

        $display("================================================");
        $display("[PASS] corrected GQA ping-pong Buffer");
        $display("Producer vectors = %0d", producer_vectors);
        $display("Consumer vectors = %0d", consumer_vectors);
        $display("Overlap cycles   = %0d", overlap_cycles);
        $display("Protocol errors  = 0");
        $display("================================================");
        $finish;
    end

endmodule
