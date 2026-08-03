`timescale 1ns/1ps

module tb_online_softmax_full_backend;
    localparam int SEQ_LEN = 128;
    localparam int HEAD_DIM = 128;
    localparam int Q_HEADS = 4;
    localparam int TILE = 4;
    localparam int INPUT_BEATS_EXPECTED = Q_HEADS * SEQ_LEN * SEQ_LEN;
    localparam int VECTOR_BEATS_EXPECTED =
        Q_HEADS * (SEQ_LEN/TILE) * (HEAD_DIM/TILE) * SEQ_LEN;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic start, feeding;
    logic in_valid, in_ready, in_last, in_mask;
    logic [15:0] in_data;
    logic [1:0] in_head;
    logic [6:0] in_row, in_col;
    logic prob_valid, prob_ready, prob_first, prob_last;
    logic [15:0] prob_data;
    logic [1:0] prob_head;
    logic [6:0] prob_row, prob_col;
    logic softmax_busy, row_error, metadata_error;
    logic prob_group_last;

    logic v_req_valid, v_req_ready, v_rsp_valid, v_rsp_ready;
    logic [2:0] v_req_kv_head;
    logic [6:0] v_req_reduce_index, v_req_feature_base;
    logic [16:0] v_req_addr;
    logic [63:0] v_rsp_data;
    logic [63:0] p_vec_bf16, v_vec_bf16;
    logic vec_valid, vec_ready, vec_first, vec_last;
    logic [1:0] vec_head;
    logic [6:0] vec_row_base, vec_feature_base, vec_reduce_index;
    logic backend_done, backend_busy, backend_error;

    integer cycles;
    integer input_beats;
    integer probability_beats;
    integer vector_beats;

    assign in_valid = feeding;
    assign in_data = 16'h0000;
    assign in_mask = 1'b0;
    assign in_last = (in_col == SEQ_LEN-1);
    assign prob_group_last = prob_valid && prob_last &&
                             (prob_head == Q_HEADS-1) &&
                             (prob_row == SEQ_LEN-1) &&
                             (prob_col == SEQ_LEN-1);
    assign vec_ready = 1'b1;
    assign v_req_ready = !v_rsp_valid || v_rsp_ready;
    assign v_rsp_data = '0;

    softmax_bf16 #(
        .MAX_LEN(SEQ_LEN), .HEAD_W(2), .POS_W(7),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) u_softmax (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_data, .in_last, .in_mask,
        .in_head, .in_row, .in_col,
        .out_valid(prob_valid), .out_ready(prob_ready),
        .out_data(prob_data), .out_first(prob_first), .out_last(prob_last),
        .out_head(prob_head), .out_row(prob_row), .out_col(prob_col),
        .busy(softmax_busy), .row_error, .metadata_error
    );

    softmax_pv_backend #(
        .Q_HEADS(Q_HEADS), .KV_HEADS(1), .V_KV_HEADS(8),
        .USE_GROUP_ID_FOR_KV(1'b1), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .TILE(TILE)
    ) u_backend (
        .clk, .rst_n, .start, .group_id(3'd0),
        .prob_valid, .prob_ready, .prob_data,
        .prob_group_id(3'd0), .prob_head, .prob_row, .prob_col,
        .prob_first, .prob_last, .prob_group_last,
        .v_req_valid, .v_req_ready, .v_req_kv_head,
        .v_req_reduce_index, .v_req_feature_base, .v_req_addr,
        .v_rsp_valid, .v_rsp_ready, .v_rsp_data,
        .p_vec_bf16, .v_vec_bf16, .vec_valid, .vec_ready,
        .vec_first, .vec_last, .vec_head, .vec_row_base,
        .vec_feature_base, .vec_reduce_index,
        .done(backend_done), .busy(backend_busy),
        .protocol_error(backend_error)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cycles <= 0;
            input_beats <= 0;
            probability_beats <= 0;
            vector_beats <= 0;
            feeding <= 1'b0;
            in_head <= '0;
            in_row <= '0;
            in_col <= '0;
            v_rsp_valid <= 1'b0;
        end else begin
            cycles <= cycles + 1;

            if (start)
                feeding <= 1'b1;

            if (v_rsp_valid && v_rsp_ready)
                v_rsp_valid <= 1'b0;
            if (v_req_valid && v_req_ready)
                v_rsp_valid <= 1'b1;

            if (in_valid && in_ready) begin
                input_beats <= input_beats + 1;
                if (in_col == SEQ_LEN-1) begin
                    in_col <= '0;
                    if (in_row == SEQ_LEN-1) begin
                        in_row <= '0;
                        if (in_head == Q_HEADS-1)
                            feeding <= 1'b0;
                        else
                            in_head <= in_head + 1'b1;
                    end else begin
                        in_row <= in_row + 1'b1;
                    end
                end else begin
                    in_col <= in_col + 1'b1;
                end
            end

            if (prob_valid && prob_ready)
                probability_beats <= probability_beats + 1;
            if (vec_valid && vec_ready)
                vector_beats <= vector_beats + 1;

            if (metadata_error || row_error || backend_error)
                $fatal(1, "Full-backend protocol failure cycle=%0d input=%0d prob=%0d vec=%0d meta/row/backend=%0b/%0b/%0b",
                       cycles, input_beats, probability_beats, vector_beats,
                       metadata_error, row_error, backend_error);

            if (backend_done) begin
                if (input_beats != INPUT_BEATS_EXPECTED ||
                    probability_beats != INPUT_BEATS_EXPECTED ||
                    vector_beats != VECTOR_BEATS_EXPECTED)
                    $fatal(1, "Full-backend count mismatch input=%0d prob=%0d vec=%0d",
                           input_beats, probability_beats, vector_beats);
                $display("FULL_BACKEND_TEST: PASS input=%0d prob=%0d vec=%0d",
                         input_beats, probability_beats, vector_beats);
                $finish;
            end

            if (cycles > 2000000)
                $fatal(1, "Full-backend timeout input=%0d prob=%0d vec=%0d",
                       input_beats, probability_beats, vector_beats);
        end
    end

    initial begin
        start = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endmodule
