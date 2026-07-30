`timescale 1ns/1ps

// Board-independent, hardware-resident one-GQA-group golden-vector test.
// The DUT is the production RoPE -> QK -> causal mask -> Softmax -> PV chain.
module attention_pl_selftest_core #(
    parameter Q_LO_FILE = "q_before_lo.hex",
    parameter Q_HI_FILE = "q_before_hi.hex",
    parameter K_LO_FILE = "k_before_lo.hex",
    parameter K_HI_FILE = "k_before_hi.hex",
    parameter V_FILE = "v_beats.hex",
    parameter CONTEXT_FILE = "context_expected.hex"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        restart,
    output logic [63:0] status,
    output logic        busy_o,
    output logic        done_o,
    output logic        pass_o,
    output logic        fail_o,
    output logic [16:0] error_count_o,
    output logic [16:0] first_error_index_o,
    output logic [63:0] cycle_count_o,
    output logic        start_debug_o,
    output logic        raw_req_valid_debug_o,
    output logic        raw_req_ready_debug_o,
    output logic        compare_valid_debug_o
);
    localparam int SEQ_LEN = 128;
    localparam int HEAD_DIM = 128;
    localparam int HALF_DIM = 64;
    localparam int Q_HEADS = 4;
    localparam int Q_BANK_WORDS = Q_HEADS*SEQ_LEN*HALF_DIM;
    localparam int K_BANK_WORDS = SEQ_LEN*HALF_DIM;
    localparam int V_BEATS = SEQ_LEN*HEAD_DIM/2;
    localparam int CONTEXT_WORDS = Q_HEADS*SEQ_LEN*HEAD_DIM;
    localparam int RAW_REQUESTS =
        Q_HEADS*SEQ_LEN*HALF_DIM + SEQ_LEN*HALF_DIM;
    localparam logic [16:0] NO_ERROR_INDEX = 17'h1ffff;

    logic [15:0] q_lo_rom [0:Q_BANK_WORDS-1];
    logic [15:0] q_hi_rom [0:Q_BANK_WORDS-1];
    logic [15:0] k_lo_rom [0:K_BANK_WORDS-1];
    logic [15:0] k_hi_rom [0:K_BANK_WORDS-1];
    logic [31:0] v_rom [0:V_BEATS-1];
    logic [15:0] context_rom [0:CONTEXT_WORDS-1];

    initial begin
        $readmemh(Q_LO_FILE, q_lo_rom);
        $readmemh(Q_HI_FILE, q_hi_rom);
        $readmemh(K_LO_FILE, k_lo_rom);
        $readmemh(K_HI_FILE, k_hi_rom);
        $readmemh(V_FILE, v_rom);
        $readmemh(CONTEXT_FILE, context_rom);
    end

    typedef enum logic [2:0] {
        ST_V_FETCH, ST_V_SEND, ST_WAIT_READY, ST_START, ST_RUN, ST_DONE
    } state_t;
    state_t state;

    wire dut_rst_n = rst_n && !restart;
    logic start;
    logic start_ready;
    logic busy;
    logic done;

    logic raw_req_valid;
    logic raw_req_ready;
    logic raw_req_is_k;
    logic [1:0] raw_req_head;
    logic [6:0] raw_req_token;
    logic [5:0] raw_req_pair;
    logic raw_rsp_valid;
    logic raw_rsp_ready;
    logic [15:0] raw_rsp_x0;
    logic [15:0] raw_rsp_x1;

    logic v_load_valid;
    logic v_load_ready;
    logic [13:0] v_load_addr;
    logic [31:0] v_load_data;
    logic [12:0] v_beat_index;
    logic [31:0] v_load_data_reg;

    logic context_valid;
    logic [15:0] context_bf16;
    logic [1:0] context_head;
    logic [6:0] context_row;
    logic [6:0] context_col;

    logic start_while_busy_error;
    logic controller_error;
    logic bc_protocol_error;
    logic v_cache_error;
    logic repack_error;
    logic protocol_error;

    logic [15:0] actual_d;
    logic [15:0] expected_d;
    logic compare_valid;
    logic [16:0] context_count;
    logic [16:0] compared_count;
    logic [16:0] mismatch_count;
    logic [16:0] first_error_index;
    logic [15:0] raw_request_count;
    logic done_seen;
    logic test_pass;
    logic test_fail;
    logic [63:0] run_cycle_count;
    logic [63:0] final_cycle_count;

    function automatic signed [23:0] bf16_to_q20(input logic [15:0] value);
        logic signed [23:0] magnitude;
        logic [7:0] mantissa;
        begin
            mantissa = {1'b1, value[6:0]};
            case (value[14:7])
                8'd107: magnitude = $signed({16'd0, mantissa}) >>> 7;
                8'd108: magnitude = $signed({16'd0, mantissa}) >>> 6;
                8'd109: magnitude = $signed({16'd0, mantissa}) >>> 5;
                8'd110: magnitude = $signed({16'd0, mantissa}) >>> 4;
                8'd111: magnitude = $signed({16'd0, mantissa}) >>> 3;
                8'd112: magnitude = $signed({16'd0, mantissa}) >>> 2;
                8'd113: magnitude = $signed({16'd0, mantissa}) >>> 1;
                8'd114: magnitude = $signed({16'd0, mantissa});
                8'd115: magnitude = $signed({16'd0, mantissa}) <<< 1;
                8'd116: magnitude = $signed({16'd0, mantissa}) <<< 2;
                8'd117: magnitude = $signed({16'd0, mantissa}) <<< 3;
                8'd118: magnitude = $signed({16'd0, mantissa}) <<< 4;
                8'd119: magnitude = $signed({16'd0, mantissa}) <<< 5;
                8'd120: magnitude = $signed({16'd0, mantissa}) <<< 6;
                8'd121: magnitude = $signed({16'd0, mantissa}) <<< 7;
                8'd122: magnitude = $signed({16'd0, mantissa}) <<< 8;
                8'd123: magnitude = $signed({16'd0, mantissa}) <<< 9;
                8'd124: magnitude = $signed({16'd0, mantissa}) <<< 10;
                8'd125: magnitude = $signed({16'd0, mantissa}) <<< 11;
                8'd126: magnitude = $signed({16'd0, mantissa}) <<< 12;
                8'd127: magnitude = $signed({16'd0, mantissa}) <<< 13;
                8'd128: magnitude = $signed({16'd0, mantissa}) <<< 14;
                8'd129: magnitude = $signed({16'd0, mantissa}) <<< 15;
                default: magnitude = ($unsigned(value[14:7]) < 107) ?
                                     24'sd0 : 24'sh7fffff;
            endcase
            bf16_to_q20 = value[15] ? -magnitude : magnitude;
        end
    endfunction

    function automatic logic bf16_within_abs_tolerance(
        input logic [15:0] actual,
        input logic [15:0] expected
    );
        logic signed [23:0] actual_q20;
        logic signed [23:0] expected_q20;
        logic signed [24:0] difference;
        begin
            actual_q20 = bf16_to_q20(actual);
            expected_q20 = bf16_to_q20(expected);
            difference = actual_q20 - expected_q20;
            if (difference < 0)
                difference = -difference;
            // 0.0001 * 2^20 = 104.8576; use the strict integer bound.
            bf16_within_abs_tolerance = (difference <= 25'sd104);
        end
    endfunction

    assign start = (state == ST_START);
    assign v_load_valid = (state == ST_V_SEND);
    assign v_load_addr = {v_beat_index, 1'b0};
    assign v_load_data = v_load_data_reg;
    assign raw_req_ready = dut_rst_n && !raw_rsp_valid;

    assign busy_o = (state != ST_DONE);
    assign done_o = (state == ST_DONE);
    assign pass_o = test_pass;
    assign fail_o = test_fail;
    assign error_count_o = mismatch_count;
    assign first_error_index_o = first_error_index;
    assign cycle_count_o = final_cycle_count;
    assign start_debug_o = start;
    assign raw_req_valid_debug_o = raw_req_valid;
    assign raw_req_ready_debug_o = raw_req_ready;
    assign compare_valid_debug_o = compare_valid;

    always_ff @(posedge clk) begin
        if (!dut_rst_n) begin
            raw_rsp_valid <= 1'b0;
            raw_rsp_x0 <= '0;
            raw_rsp_x1 <= '0;
            raw_request_count <= '0;
        end else begin
            if (raw_rsp_valid && raw_rsp_ready)
                raw_rsp_valid <= 1'b0;
            if (raw_req_valid && raw_req_ready) begin
                if (raw_req_is_k) begin
                    raw_rsp_x0 <=
                        k_lo_rom[raw_req_token*HALF_DIM + raw_req_pair];
                    raw_rsp_x1 <=
                        k_hi_rom[raw_req_token*HALF_DIM + raw_req_pair];
                end else begin
                    raw_rsp_x0 <= q_lo_rom[
                        (raw_req_head*SEQ_LEN + raw_req_token)*HALF_DIM
                        + raw_req_pair
                    ];
                    raw_rsp_x1 <= q_hi_rom[
                        (raw_req_head*SEQ_LEN + raw_req_token)*HALF_DIM
                        + raw_req_pair
                    ];
                end
                raw_rsp_valid <= 1'b1;
                raw_request_count <= raw_request_count + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!dut_rst_n) begin
            state <= ST_V_FETCH;
            v_beat_index <= '0;
            v_load_data_reg <= '0;
            context_count <= '0;
            compared_count <= '0;
            mismatch_count <= '0;
            first_error_index <= NO_ERROR_INDEX;
            actual_d <= '0;
            expected_d <= '0;
            compare_valid <= 1'b0;
            done_seen <= 1'b0;
            test_pass <= 1'b0;
            test_fail <= 1'b0;
            run_cycle_count <= '0;
            final_cycle_count <= '0;
        end else begin
            compare_valid <= context_valid;
            if (context_valid) begin
                actual_d <= context_bf16;
                expected_d <= context_rom[
                    (context_head*SEQ_LEN + context_row)*HEAD_DIM
                    + context_col
                ];
                context_count <= context_count + 1'b1;
            end
            if (compare_valid) begin
                compared_count <= compared_count + 1'b1;
                if (!bf16_within_abs_tolerance(actual_d, expected_d)) begin
                    mismatch_count <= mismatch_count + 1'b1;
                    if (mismatch_count == 0)
                        first_error_index <= compared_count;
                end
            end
            if (done)
                done_seen <= 1'b1;

            if (state == ST_START)
                run_cycle_count <= '0;
            else if (state == ST_RUN)
                run_cycle_count <= run_cycle_count + 1'b1;

            case (state)
                ST_V_FETCH: begin
                    v_load_data_reg <= v_rom[v_beat_index];
                    state <= ST_V_SEND;
                end
                ST_V_SEND: if (v_load_ready) begin
                    if (v_beat_index == V_BEATS-1)
                        state <= ST_WAIT_READY;
                    else begin
                        v_beat_index <= v_beat_index + 1'b1;
                        state <= ST_V_FETCH;
                    end
                end
                ST_WAIT_READY: if (start_ready)
                    state <= ST_START;
                ST_START: state <= ST_RUN;
                ST_RUN: if (done_seen &&
                               (compared_count == CONTEXT_WORDS)) begin
                    test_pass <= (mismatch_count == 0) &&
                                 (raw_request_count == RAW_REQUESTS) &&
                                 !start_while_busy_error &&
                                 !controller_error &&
                                 !bc_protocol_error &&
                                 !v_cache_error &&
                                 !repack_error &&
                                 !protocol_error;
                    test_fail <= (mismatch_count != 0) ||
                                 (raw_request_count != RAW_REQUESTS) ||
                                 start_while_busy_error ||
                                 controller_error ||
                                 bc_protocol_error ||
                                 v_cache_error ||
                                 repack_error ||
                                 protocol_error;
                    final_cycle_count <= run_cycle_count;
                    state <= ST_DONE;
                end
                ST_DONE: state <= ST_DONE;
                default: state <= ST_V_FETCH;
            endcase
        end
    end

    always_comb begin
        status = '0;
        status[0] = (state != ST_DONE);
        status[1] = (state == ST_DONE);
        status[2] = test_pass;
        status[3] = test_fail;
        status[20:4] = mismatch_count;
        status[37:21] = context_count;
        status[53:38] = raw_request_count;
        status[54] = busy;
        status[55] = done_seen;
        status[61:56] = {protocol_error, repack_error, v_cache_error,
                         bc_protocol_error, controller_error,
                         start_while_busy_error};
        status[63:62] = state[1:0];
    end

    attention_system_with_rope_pv_top #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(1),
        .RUN_GQA_GROUPS(1),
        .ALLOW_REDUCED_GQA(1'b1)
    ) dut (
        .clk(clk), .rst_n(dut_rst_n),
        .start(start), .start_ready(start_ready), .busy(busy), .done(done),
        .causal_en(1'b1),
        .raw_req_valid(raw_req_valid), .raw_req_ready(raw_req_ready),
        .raw_req_is_k(raw_req_is_k), .raw_req_head(raw_req_head),
        .raw_req_token(raw_req_token), .raw_req_pair(raw_req_pair),
        .raw_rsp_valid(raw_rsp_valid), .raw_rsp_ready(raw_rsp_ready),
        .raw_rsp_x0(raw_rsp_x0), .raw_rsp_x1(raw_rsp_x1),
        .req_head(), .req_group_id(), .req_global_q_head(), .req_kv_head(),
        .req_row_base(), .req_col_base(), .req_dim(),
        .v_load_valid(v_load_valid), .v_load_ready(v_load_ready),
        .v_load_addr(v_load_addr), .v_load_data(v_load_data),
        .context_valid(context_valid), .context_ready(1'b1),
        .context_bf16(context_bf16), .context_fp32_debug(),
        .context_group_id(), .context_head(context_head),
        .context_global_q_head(), .context_row(context_row),
        .context_col(context_col), .context_group_last(),
        .context_global_last(),
        .mon_prob_valid(), .mon_prob_ready(), .mon_prob_data(),
        .mon_prob_group_id(), .mon_prob_head(), .mon_prob_row(),
        .mon_prob_col(), .mon_prob_first(), .mon_prob_last(),
        .mon_prob_group_last(),
        .mon_bc_pv_valid(), .mon_bc_pv_ready(), .mon_bc_p_vec_bf16(),
        .mon_bc_v_vec_bf16(), .mon_bc_pv_group_id(), .mon_bc_pv_head(),
        .mon_bc_pv_row_base(), .mon_bc_pv_feature_base(),
        .mon_bc_pv_reduce_index(),
        .mon_real_pv_valid(), .mon_real_pv_ready(), .mon_real_p_vec_bf16(),
        .mon_real_v_vec_bf16(), .mon_real_pv_req_head(),
        .mon_real_pv_req_row_base(), .mon_real_pv_req_col_base(),
        .mon_real_pv_req_reduce(),
        .group_complete(), .completed_group_id(), .active_group_id(),
        .bc_group_done(), .capture_complete(), .pv_group_done(),
        .bc_busy(), .pv_busy(),
        .start_while_busy_error(start_while_busy_error),
        .controller_error(controller_error),
        .bc_protocol_error(bc_protocol_error),
        .v_cache_error(v_cache_error), .repack_error(repack_error),
        .protocol_error(protocol_error)
    );
endmodule
