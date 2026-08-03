`timescale 1ns/1ps

// Two complete-Group TILE2-to-TILE4 repack banks.
//
// Bank states:
//   EMPTY -> FILLING -> READY -> DRAINING -> EMPTY
//
// The B+C TILE2 stream writes one bank while the real TILE4 PV engine reads
// the other.  P and V memories use synchronous simple-dual-port templates so
// Vivado can infer block RAM instead of expanding the full Group into LUTRAM.
module pv_tile2_to_tile4_pingpong_adapter #(
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
    input  logic start,

    input  logic fill_start_valid,
    output logic fill_start_ready,
    input  logic [GROUP_W-1:0] fill_start_group_id,

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

    output logic capture_complete,
    output logic capture_done,
    output logic capture_busy,

    output logic drain_valid,
    input  logic drain_ready,
    output logic [GROUP_W-1:0] drain_group_id,
    input  logic drain_release,

    input  logic feed_enable,
    input  logic [HEAD_W-1:0] req_head,
    input  logic [POS_W-1:0] req_row_base,
    input  logic [DIM_W-1:0] req_col_base,
    input  logic [POS_W-1:0] req_reduce,

    output logic [63:0] out_p_vec_bf16,
    output logic [63:0] out_v_vec_bf16,
    output logic out_valid,
    input  logic out_ready,

    output logic [1:0] bank0_state,
    output logic [1:0] bank1_state,
    output logic drain_active,
    output logic buffer_busy,
    output logic protocol_error
);

    localparam logic [1:0] BANK_EMPTY    = 2'd0;
    localparam logic [1:0] BANK_FILLING  = 2'd1;
    localparam logic [1:0] BANK_READY    = 2'd2;
    localparam logic [1:0] BANK_DRAINING = 2'd3;

    localparam int ROW_TILES4 = SEQ_LEN / 4;
    localparam int COL_TILES4 = HEAD_DIM / 4;
    localparam int P_BANK_DEPTH =
        Q_HEADS * ROW_TILES4 * SEQ_LEN;
    localparam int V_BANK_DEPTH =
        SEQ_LEN * COL_TILES4;
    localparam int P_MEM_DEPTH = 2 * P_BANK_DEPTH;
    localparam int V_MEM_DEPTH = 2 * V_BANK_DEPTH;
    localparam int P_ADDR_W =
        (P_MEM_DEPTH <= 1) ? 1 : $clog2(P_MEM_DEPTH);
    localparam int V_ADDR_W =
        (V_MEM_DEPTH <= 1) ? 1 : $clog2(V_MEM_DEPTH);

    logic [1:0] bank_state [0:1];
    logic [GROUP_W-1:0] bank_group_id [0:1];
    logic next_fill_bank;
    logic next_drain_bank;
    logic fill_bank;
    logic drain_bank;
    logic fill_active;

    logic [GROUP_W-1:0] fill_group_id;
    logic [HEAD_W-1:0] expected_head;
    logic [POS_W-1:0] expected_row_base2;
    logic [DIM_W-1:0] expected_feature_base2;
    logic [POS_W-1:0] expected_reduce;

    logic expected_first;
    logic expected_last;
    logic expected_group_last;
    logic [GLOBAL_Q_HEAD_W-1:0] expected_global_q_head;

    logic [P_ADDR_W-1:0] p_write_addr;
    logic [V_ADDR_W-1:0] v_write_addr;
    logic [P_ADDR_W-1:0] p_issue_addr;
    logic [V_ADDR_W-1:0] v_issue_addr;

    logic issue_read;
    logic [HEAD_W-1:0] issue_head;
    logic [POS_W-1:0] issue_row_base;
    logic [DIM_W-1:0] issue_col_base;
    logic [POS_W-1:0] issue_reduce;
    logic issue_request_legal;
    logic response_is_last;

    logic out_valid_reg;
    logic [15:0] out_p_lane_reg [0:3];
    logic [15:0] out_v_lane_reg [0:3];
    logic [HEAD_W-1:0] rsp_head;
    logic [POS_W-1:0] rsp_row_base;
    logic [DIM_W-1:0] rsp_col_base;
    logic [POS_W-1:0] rsp_reduce;
    logic feed_complete;

    function automatic [P_ADDR_W-1:0] make_p_addr(
        input logic bank,
        input logic [HEAD_W-1:0] head,
        input logic [POS_W-1:0] row_base,
        input logic [POS_W-1:0] reduce_index
    );
        integer unsigned value;
        begin
            value =
                (($unsigned(head) * ROW_TILES4 +
                  ($unsigned(row_base) >> 2)) * SEQ_LEN) +
                $unsigned(reduce_index);
            if (bank)
                value = value + P_BANK_DEPTH;
            make_p_addr = value[P_ADDR_W-1:0];
        end
    endfunction

    function automatic [V_ADDR_W-1:0] make_v_addr(
        input logic bank,
        input logic [POS_W-1:0] reduce_index,
        input logic [DIM_W-1:0] col_base
    );
        integer unsigned value;
        begin
            value =
                ($unsigned(reduce_index) * COL_TILES4) +
                ($unsigned(col_base) >> 2);
            if (bank)
                value = value + V_BANK_DEPTH;
            make_v_addr = value[V_ADDR_W-1:0];
        end
    endfunction

    assign bank0_state = bank_state[0];
    assign bank1_state = bank_state[1];

    assign fill_start_ready =
        !fill_active &&
        (bank_state[next_fill_bank] == BANK_EMPTY);
    assign in_ready =
        fill_active &&
        (bank_state[fill_bank] == BANK_FILLING);

    assign drain_valid =
        !drain_active &&
        (bank_state[next_drain_bank] == BANK_READY);
    assign drain_group_id = bank_group_id[next_drain_bank];

    assign capture_busy = fill_active;
    assign buffer_busy =
        fill_active ||
        drain_active ||
        out_valid_reg ||
        (bank_state[0] != BANK_EMPTY) ||
        (bank_state[1] != BANK_EMPTY);

    assign out_valid = out_valid_reg;
    assign out_p_vec_bf16 = {
        out_p_lane_reg[3],
        out_p_lane_reg[2],
        out_p_lane_reg[1],
        out_p_lane_reg[0]
    };
    assign out_v_vec_bf16 = {
        out_v_lane_reg[3],
        out_v_lane_reg[2],
        out_v_lane_reg[1],
        out_v_lane_reg[0]
    };

    always_comb begin
        expected_first = (expected_reduce == 0);
        expected_last =
            ($unsigned(expected_reduce) == SEQ_LEN-1);
        expected_group_last =
            ($unsigned(expected_head) == Q_HEADS-1) &&
            ($unsigned(expected_row_base2) == SEQ_LEN-2) &&
            ($unsigned(expected_feature_base2) == HEAD_DIM-2) &&
            ($unsigned(expected_reduce) == SEQ_LEN-1);
        expected_global_q_head =
            ($unsigned(fill_group_id) * Q_HEADS) +
            $unsigned(expected_head);

        p_write_addr = make_p_addr(
            fill_bank,
            in_head,
            in_row_base,
            in_reduce_index
        );
        v_write_addr = make_v_addr(
            fill_bank,
            in_reduce_index,
            in_feature_base
        );
    end

    // The first read uses the real-PV request metadata directly.  Every
    // accepted response prefetches the deterministic next request so the
    // synchronous BRAM adds only initial latency, not a bubble per reduce beat.
    always_comb begin
        issue_read     = 1'b0;
        issue_head     = req_head;
        issue_row_base = req_row_base;
        issue_col_base = req_col_base;
        issue_reduce   = req_reduce;

        response_is_last =
            ($unsigned(rsp_head) == Q_HEADS-1) &&
            ($unsigned(rsp_row_base) == SEQ_LEN-4) &&
            ($unsigned(rsp_col_base) == HEAD_DIM-4) &&
            ($unsigned(rsp_reduce) == SEQ_LEN-1);

        if (drain_active && feed_enable && !feed_complete) begin
            if (!out_valid_reg) begin
                issue_read = 1'b1;
            end else if (out_ready && !response_is_last) begin
                issue_read     = 1'b1;
                issue_head     = rsp_head;
                issue_row_base = rsp_row_base;
                issue_col_base = rsp_col_base;
                issue_reduce   = rsp_reduce;

                if ($unsigned(rsp_reduce) < SEQ_LEN-1) begin
                    issue_reduce = rsp_reduce + 1'b1;
                end else begin
                    issue_reduce = '0;
                    if ($unsigned(rsp_col_base) < HEAD_DIM-4) begin
                        issue_col_base = rsp_col_base + 4;
                    end else begin
                        issue_col_base = '0;
                        if ($unsigned(rsp_row_base) < SEQ_LEN-4) begin
                            issue_row_base = rsp_row_base + 4;
                        end else begin
                            issue_row_base = '0;
                            issue_head     = rsp_head + 1'b1;
                        end
                    end
                end
            end
        end

        issue_request_legal =
            ($unsigned(issue_head) < Q_HEADS) &&
            ($unsigned(issue_row_base) < SEQ_LEN) &&
            ($unsigned(issue_col_base) < HEAD_DIM) &&
            ($unsigned(issue_reduce) < SEQ_LEN) &&
            (($unsigned(issue_row_base) & 3) == 0) &&
            (($unsigned(issue_col_base) & 3) == 0);

        p_issue_addr = make_p_addr(
            drain_bank,
            issue_head,
            issue_row_base,
            issue_reduce
        );
        v_issue_addr = make_v_addr(
            drain_bank,
            issue_reduce,
            issue_col_base
        );
    end

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : GEN_REPACK_LANE
            (* ram_style = "block" *)
            logic [15:0] p_mem [0:P_MEM_DEPTH-1];
            (* ram_style = "block" *)
            logic [15:0] v_mem [0:V_MEM_DEPTH-1];

            always_ff @(posedge clk) begin
                if (!rst_n || start) begin
                    out_p_lane_reg[lane] <= '0;
                    out_v_lane_reg[lane] <= '0;
                end else begin
                    if (in_valid && in_ready &&
                        ($unsigned(in_feature_base) == 0)) begin
                        if ((($unsigned(in_row_base) & 3) == 0) &&
                            (lane < 2)) begin
                            p_mem[p_write_addr] <=
                                in_p_vec_bf16[(lane%2)*16 +: 16];
                        end else if (
                            (($unsigned(in_row_base) & 3) == 2) &&
                            (lane >= 2)
                        ) begin
                            p_mem[p_write_addr] <=
                                in_p_vec_bf16[(lane%2)*16 +: 16];
                        end
                    end

                    if (in_valid && in_ready &&
                        ($unsigned(in_head) == 0) &&
                        ($unsigned(in_row_base) == 0)) begin
                        if ((($unsigned(in_feature_base) & 3) == 0) &&
                            (lane < 2)) begin
                            v_mem[v_write_addr] <=
                                in_v_vec_bf16[(lane%2)*16 +: 16];
                        end else if (
                            (($unsigned(in_feature_base) & 3) == 2) &&
                            (lane >= 2)
                        ) begin
                            v_mem[v_write_addr] <=
                                in_v_vec_bf16[(lane%2)*16 +: 16];
                        end
                    end

                    if (issue_read && issue_request_legal) begin
                        out_p_lane_reg[lane] <= p_mem[p_issue_addr];
                        out_v_lane_reg[lane] <= v_mem[v_issue_addr];
                    end
                end
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            bank_state[0]         <= BANK_EMPTY;
            bank_state[1]         <= BANK_EMPTY;
            bank_group_id[0]      <= '0;
            bank_group_id[1]      <= '0;
            next_fill_bank        <= 1'b0;
            next_drain_bank       <= 1'b0;
            fill_bank             <= 1'b0;
            drain_bank            <= 1'b0;
            fill_active           <= 1'b0;
            drain_active          <= 1'b0;
            fill_group_id         <= '0;
            expected_head         <= '0;
            expected_row_base2    <= '0;
            expected_feature_base2 <= '0;
            expected_reduce       <= '0;
            capture_complete      <= 1'b0;
            capture_done          <= 1'b0;
            out_valid_reg         <= 1'b0;
            rsp_head              <= '0;
            rsp_row_base          <= '0;
            rsp_col_base          <= '0;
            rsp_reduce            <= '0;
            feed_complete         <= 1'b0;
            protocol_error        <= 1'b0;
        end else begin
            capture_complete <= 1'b0;
            capture_done     <= 1'b0;

            if (fill_start_valid && fill_start_ready) begin
                if ($unsigned(fill_start_group_id) >= GQA_GROUPS) begin
                    protocol_error <= 1'b1;
                end else begin
                    fill_bank                       <= next_fill_bank;
                    fill_group_id                   <= fill_start_group_id;
                    bank_group_id[next_fill_bank]   <= fill_start_group_id;
                    bank_state[next_fill_bank]      <= BANK_FILLING;
                    fill_active                     <= 1'b1;
                    expected_head                   <= '0;
                    expected_row_base2              <= '0;
                    expected_feature_base2          <= '0;
                    expected_reduce                 <= '0;
                end
            end

            if (in_valid && in_ready) begin
                if ((in_group_id       != fill_group_id) ||
                    (in_head           != expected_head) ||
                    (in_global_q_head  != expected_global_q_head) ||
                    (in_row_base       != expected_row_base2) ||
                    (in_feature_base   != expected_feature_base2) ||
                    (in_reduce_index   != expected_reduce) ||
                    (in_first          != expected_first) ||
                    (in_last           != expected_last) ||
                    (in_group_last     != expected_group_last)) begin
                    protocol_error <= 1'b1;
                end

                if (($unsigned(in_feature_base) == 0) &&
                    (($unsigned(in_row_base) & 3) != 0) &&
                    (($unsigned(in_row_base) & 3) != 2)) begin
                    protocol_error <= 1'b1;
                end

                if (($unsigned(in_head) == 0) &&
                    ($unsigned(in_row_base) == 0) &&
                    (($unsigned(in_feature_base) & 3) != 0) &&
                    (($unsigned(in_feature_base) & 3) != 2)) begin
                    protocol_error <= 1'b1;
                end

                if (expected_group_last) begin
                    bank_state[fill_bank] <= BANK_READY;
                    fill_active           <= 1'b0;
                    next_fill_bank        <= ~fill_bank;
                    capture_complete      <= 1'b1;
                    capture_done          <= 1'b1;
                end else if ($unsigned(expected_reduce) < SEQ_LEN-1) begin
                    expected_reduce <= expected_reduce + 1'b1;
                end else begin
                    expected_reduce <= '0;
                    if ($unsigned(expected_feature_base2) < HEAD_DIM-2) begin
                        expected_feature_base2 <=
                            expected_feature_base2 + 2;
                    end else begin
                        expected_feature_base2 <= '0;
                        if ($unsigned(expected_row_base2) < SEQ_LEN-2) begin
                            expected_row_base2 <= expected_row_base2 + 2;
                        end else begin
                            expected_row_base2 <= '0;
                            expected_head      <= expected_head + 1'b1;
                        end
                    end
                end
            end

            if (drain_valid && drain_ready) begin
                drain_bank                   <= next_drain_bank;
                bank_state[next_drain_bank]  <= BANK_DRAINING;
                drain_active                 <= 1'b1;
                out_valid_reg                <= 1'b0;
                feed_complete                <= 1'b0;
            end

            if (out_valid_reg && out_ready) begin
                if ((req_head     != rsp_head) ||
                    (req_row_base != rsp_row_base) ||
                    (req_col_base != rsp_col_base) ||
                    (req_reduce   != rsp_reduce)) begin
                    protocol_error <= 1'b1;
                end
                if (response_is_last)
                    feed_complete <= 1'b1;
                out_valid_reg <= 1'b0;
            end

            if (issue_read) begin
                if (!issue_request_legal) begin
                    protocol_error <= 1'b1;
                end else begin
                    out_valid_reg <= 1'b1;
                    rsp_head      <= issue_head;
                    rsp_row_base  <= issue_row_base;
                    rsp_col_base  <= issue_col_base;
                    rsp_reduce    <= issue_reduce;
                end
            end

            if (drain_release) begin
                if (!drain_active || out_valid_reg) begin
                    protocol_error <= 1'b1;
                end else begin
                    bank_state[drain_bank] <= BANK_EMPTY;
                    drain_active           <= 1'b0;
                    next_drain_bank        <= ~drain_bank;
                    feed_complete          <= 1'b0;
                end
            end

            if (in_valid && !fill_active)
                protocol_error <= 1'b1;
            if (feed_enable && !drain_active && !drain_valid)
                protocol_error <= 1'b1;
        end
    end

    initial begin
        if ((SEQ_LEN % 4) != 0)
            $error(
                "pv_tile2_to_tile4_pingpong_adapter: SEQ_LEN must divide by 4"
            );
        if ((HEAD_DIM % 4) != 0)
            $error(
                "pv_tile2_to_tile4_pingpong_adapter: HEAD_DIM must divide by 4"
            );
        if (Q_HEADS != 4)
            $error(
                "pv_tile2_to_tile4_pingpong_adapter: Q_HEADS must equal 4"
            );
        if (GQA_GROUPS < 1)
            $error(
                "pv_tile2_to_tile4_pingpong_adapter: GQA_GROUPS must be >= 1"
            );
    end

endmodule
