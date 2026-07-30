`timescale 1ns/1ps

// Two complete Group banks built from the verified TILE2-to-TILE4 adapter.
//
// One bank may be filled by B+C while the other is drained by the real PV
// engine.  The existing address/lane mapping is intentionally unchanged.
module gqa_pingpong_buffer #(
    parameter int SEQ_LEN      = 128,
    parameter int HEAD_DIM     = 128,
    parameter int Q_HEADS      = 4,
    parameter int GQA_GROUPS   = 8,
    parameter int HEAD_W       =
        (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W      =
        (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W =
        ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
        $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W        =
        (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W        =
        (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM)
) (
    input  logic clk,
    input  logic rst_n,

    // Producer ownership.
    input  logic fill_start,
    input  logic fill_bank,
    input  logic [GROUP_W-1:0] fill_group_id,
    output logic fill_ready,

    input  logic [31:0] in_p_vec_bf16,
    input  logic [31:0] in_v_vec_bf16,
    input  logic in_valid,
    output logic in_ready,
    input  logic in_first,
    input  logic in_last,
    input  logic in_group_last,
    input  logic [GROUP_W-1:0] in_group_id,
    input  logic [HEAD_W-1:0] in_head,
    input  logic [GLOBAL_Q_HEAD_W-1:0] in_global_q_head,
    input  logic [POS_W-1:0] in_row_base,
    input  logic [DIM_W-1:0] in_feature_base,
    input  logic [POS_W-1:0] in_reduce_index,

    output logic fill_done,
    output logic fill_done_bank,
    output logic [GROUP_W-1:0] fill_done_group_id,

    // Consumer ownership.
    input  logic drain_start,
    input  logic drain_bank,
    input  logic [GROUP_W-1:0] drain_group_id,
    output logic drain_ready,

    input  logic release_valid,
    input  logic release_bank,
    input  logic [GROUP_W-1:0] release_group_id,

    input  logic [HEAD_W-1:0] req_head,
    input  logic [POS_W-1:0] req_row_base,
    input  logic [DIM_W-1:0] req_col_base,
    input  logic [POS_W-1:0] req_reduce,

    output logic [63:0] out_p_vec_bf16,
    output logic [63:0] out_v_vec_bf16,
    output logic out_valid,
    input  logic out_ready,

    // State exported to the wavefront scheduler.
    output logic [1:0] bank0_state,
    output logic [1:0] bank1_state,
    output logic [GROUP_W-1:0] bank0_group_id,
    output logic [GROUP_W-1:0] bank1_group_id,

    output logic protocol_error,
    output logic [31:0] invalid_fill_count,
    output logic [31:0] invalid_drain_count,
    output logic [31:0] bank_conflict_count
);

    localparam logic [1:0] BANK_EMPTY    = 2'd0;
    localparam logic [1:0] BANK_FILLING  = 2'd1;
    localparam logic [1:0] BANK_READY    = 2'd2;
    localparam logic [1:0] BANK_DRAINING = 2'd3;

    logic [1:0] state [0:1];
    logic [GROUP_W-1:0] bank_group_id [0:1];

    logic fill_active;
    logic active_fill_bank;
    logic drain_active;
    logic active_drain_bank;

    logic capture_start0;
    logic capture_start1;
    logic capture_complete0;
    logic capture_complete1;
    logic capture_done0;
    logic capture_done1;
    logic in_ready0;
    logic in_ready1;
    logic out_valid0;
    logic out_valid1;
    logic [63:0] out_p0;
    logic [63:0] out_p1;
    logic [63:0] out_v0;
    logic [63:0] out_v1;
    logic adapter_error0;
    logic adapter_error1;

    logic accepted_fill_start;
    logic accepted_drain_start;

    assign bank0_state    = state[0];
    assign bank1_state    = state[1];
    assign bank0_group_id = bank_group_id[0];
    assign bank1_group_id = bank_group_id[1];

    always_comb begin
        fill_ready =
            !fill_active &&
            (state[fill_bank] == BANK_EMPTY);

        drain_ready =
            !drain_active &&
            (state[drain_bank] == BANK_READY) &&
            (bank_group_id[drain_bank] == drain_group_id);

        accepted_fill_start  = fill_start && fill_ready;
        accepted_drain_start = drain_start && drain_ready;

        capture_start0 =
            accepted_fill_start && (fill_bank == 1'b0);
        capture_start1 =
            accepted_fill_start && (fill_bank == 1'b1);

        if (fill_active) begin
            in_ready = active_fill_bank ? in_ready1 : in_ready0;
        end else begin
            in_ready = 1'b0;
        end

        if (drain_active) begin
            if (active_drain_bank) begin
                out_p_vec_bf16 = out_p1;
                out_v_vec_bf16 = out_v1;
                out_valid      = out_valid1;
            end else begin
                out_p_vec_bf16 = out_p0;
                out_v_vec_bf16 = out_v0;
                out_valid      = out_valid0;
            end
        end else begin
            out_p_vec_bf16 = '0;
            out_v_vec_bf16 = '0;
            out_valid      = 1'b0;
        end
    end

    pv_tile2_to_tile4_buffer_adapter #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) u_bank0 (
        .clk(clk),
        .rst_n(rst_n),
        .capture_start(capture_start0),
        // Use the Bank-owned, latched Group ID instead of the live scheduler
        // bus. This remains correct even while the other Bank is selected.
        .expected_group_id(bank_group_id[0]),
        .in_p_vec_bf16(in_p_vec_bf16),
        .in_v_vec_bf16(in_v_vec_bf16),
        .in_valid(in_valid && fill_active &&
                  (active_fill_bank == 1'b0)),
        .in_ready(in_ready0),
        .in_first(in_first),
        .in_last(in_last),
        .in_group_last(in_group_last),
        .in_group_id(in_group_id),
        .in_head(in_head),
        .in_global_q_head(in_global_q_head),
        .in_row_base(in_row_base),
        .in_feature_base(in_feature_base),
        .in_reduce_index(in_reduce_index),
        .capture_complete(capture_complete0),
        .capture_done(capture_done0),
        .feed_enable(drain_active &&
                     (active_drain_bank == 1'b0)),
        .req_head(req_head),
        .req_row_base(req_row_base),
        .req_col_base(req_col_base),
        .req_reduce(req_reduce),
        .out_p_vec_bf16(out_p0),
        .out_v_vec_bf16(out_v0),
        .out_valid(out_valid0),
        .out_ready(out_ready),
        .protocol_error(adapter_error0)
    );

    pv_tile2_to_tile4_buffer_adapter #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) u_bank1 (
        .clk(clk),
        .rst_n(rst_n),
        .capture_start(capture_start1),
        .expected_group_id(bank_group_id[1]),
        .in_p_vec_bf16(in_p_vec_bf16),
        .in_v_vec_bf16(in_v_vec_bf16),
        .in_valid(in_valid && fill_active &&
                  (active_fill_bank == 1'b1)),
        .in_ready(in_ready1),
        .in_first(in_first),
        .in_last(in_last),
        .in_group_last(in_group_last),
        .in_group_id(in_group_id),
        .in_head(in_head),
        .in_global_q_head(in_global_q_head),
        .in_row_base(in_row_base),
        .in_feature_base(in_feature_base),
        .in_reduce_index(in_reduce_index),
        .capture_complete(capture_complete1),
        .capture_done(capture_done1),
        .feed_enable(drain_active &&
                     (active_drain_bank == 1'b1)),
        .req_head(req_head),
        .req_row_base(req_row_base),
        .req_col_base(req_col_base),
        .req_reduce(req_reduce),
        .out_p_vec_bf16(out_p1),
        .out_v_vec_bf16(out_v1),
        .out_valid(out_valid1),
        .out_ready(out_ready),
        .protocol_error(adapter_error1)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state[0]             <= BANK_EMPTY;
            state[1]             <= BANK_EMPTY;
            bank_group_id[0]     <= '0;
            bank_group_id[1]     <= '0;
            fill_active          <= 1'b0;
            active_fill_bank     <= 1'b0;
            drain_active         <= 1'b0;
            active_drain_bank    <= 1'b0;
            fill_done            <= 1'b0;
            fill_done_bank       <= 1'b0;
            fill_done_group_id   <= '0;
            protocol_error       <= 1'b0;
            invalid_fill_count   <= '0;
            invalid_drain_count  <= '0;
            bank_conflict_count  <= '0;
        end else begin
            fill_done <= 1'b0;

            if (fill_start && !fill_ready) begin
                protocol_error      <= 1'b1;
                invalid_fill_count  <= invalid_fill_count + 1'b1;
            end

            if (drain_start && !drain_ready) begin
                protocol_error       <= 1'b1;
                invalid_drain_count  <= invalid_drain_count + 1'b1;
            end

            if (accepted_fill_start) begin
                fill_active                <= 1'b1;
                active_fill_bank           <= fill_bank;
                state[fill_bank]           <= BANK_FILLING;
                bank_group_id[fill_bank]   <= fill_group_id;
            end

            if (fill_active &&
                ((!active_fill_bank && capture_done0) ||
                 ( active_fill_bank && capture_done1))) begin
                fill_active                    <= 1'b0;
                state[active_fill_bank]        <= BANK_READY;
                fill_done                      <= 1'b1;
                fill_done_bank                 <= active_fill_bank;
                fill_done_group_id             <=
                    bank_group_id[active_fill_bank];
            end

            if (accepted_drain_start) begin
                drain_active              <= 1'b1;
                active_drain_bank         <= drain_bank;
                state[drain_bank]         <= BANK_DRAINING;
            end

            if (accepted_fill_start && accepted_drain_start &&
                (fill_bank == drain_bank)) begin
                protocol_error      <= 1'b1;
                bank_conflict_count <= bank_conflict_count + 1'b1;
            end

            if (release_valid) begin
                if (!drain_active ||
                    (release_bank != active_drain_bank) ||
                    (release_group_id !=
                     bank_group_id[active_drain_bank]) ||
                    (state[release_bank] != BANK_DRAINING)) begin
                    protocol_error       <= 1'b1;
                    invalid_drain_count  <=
                        invalid_drain_count + 1'b1;
                end else begin
                    state[release_bank] <= BANK_EMPTY;
                    drain_active        <= 1'b0;
                end
            end

            if (adapter_error0 || adapter_error1)
                protocol_error <= 1'b1;

            if (fill_active && drain_active &&
                (active_fill_bank == active_drain_bank)) begin
                protocol_error      <= 1'b1;
                bank_conflict_count <= bank_conflict_count + 1'b1;
            end
        end
    end

    initial begin
        if ((SEQ_LEN % 4) != 0)
            $error("gqa_pingpong_buffer: SEQ_LEN must be divisible by 4");

        if ((HEAD_DIM % 4) != 0)
            $error("gqa_pingpong_buffer: HEAD_DIM must be divisible by 4");

        if (Q_HEADS != 4)
            $error("gqa_pingpong_buffer: Q_HEADS must equal 4");
    end

endmodule
