`timescale 1ns/1ps

// Fixed-layout single-GQA Q/K/V ingress and memory service.
//
// DMA frame order, all BF16 and little-lane-first inside each AXIS beat:
//   Q[4][SEQ_LEN][HEAD_DIM]
//   K[1][SEQ_LEN][HEAD_DIM]
//   V[1][SEQ_LEN][HEAD_DIM]
//
// The frame must be full-width, contiguous, and assert TLAST only on the
// final beat. The stored Q/K memories implement the production core's
// one-outstanding raw pre-RoPE request contract. V is replayed through the
// production v_load interface before compute starts.
module axis_qkv_memory_bridge #(
    parameter int AXIS_DATA_W = 128,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int Q_HEADS = 4,
    parameter int GLOBAL_Q_HEAD_W =
        ((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS)),
    parameter int POS_W = ((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN)),
    parameter int PAIR_W =
        (((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2)),
    parameter int V_ADDR_W =
        (((SEQ_LEN*HEAD_DIM) <= 1) ? 1 : $clog2(SEQ_LEN*HEAD_DIM))
) (
    input  logic                       aclk,
    input  logic                       aresetn,
    input  logic                       frame_clear,

    input  logic [AXIS_DATA_W-1:0]     s_axis_tdata,
    input  logic [AXIS_DATA_W/8-1:0]   s_axis_tkeep,
    input  logic                       s_axis_tlast,
    input  logic                       s_axis_tvalid,
    output logic                       s_axis_tready,

    output logic                       frame_loaded,
    output logic                       ingress_protocol_error,
    output logic [31:0]                input_beats,

    input  logic                       raw_req_valid,
    output logic                       raw_req_ready,
    input  logic                       raw_req_is_k,
    input  logic [GLOBAL_Q_HEAD_W-1:0] raw_req_head,
    input  logic [POS_W-1:0]           raw_req_token,
    input  logic [PAIR_W-1:0]          raw_req_pair,
    output logic                       raw_rsp_valid,
    input  logic                       raw_rsp_ready,
    output logic [15:0]                raw_rsp_x0,
    output logic [15:0]                raw_rsp_x1,

    input  logic                       preload_start,
    output logic                       preload_busy,
    output logic                       preload_done_pulse,
    output logic                       v_load_valid,
    input  logic                       v_load_ready,
    output logic [V_ADDR_W-1:0]        v_load_addr,
    output logic [31:0]                v_load_data
);
    localparam int LANES = AXIS_DATA_W / 16;
    localparam int HALF_DIM = HEAD_DIM / 2;
    localparam int Q_WORDS = Q_HEADS*SEQ_LEN*HEAD_DIM;
    localparam int K_WORDS = SEQ_LEN*HEAD_DIM;
    localparam int V_WORDS = SEQ_LEN*HEAD_DIM;
    localparam int TOTAL_WORDS = Q_WORDS + K_WORDS + V_WORDS;
    localparam int BEATS_PER_VECTOR = HEAD_DIM / LANES;
    localparam int HALF_BEATS_PER_VECTOR = HALF_DIM / LANES;
    localparam int Q_BEATS = Q_WORDS / LANES;
    localparam int K_BEATS = K_WORDS / LANES;
    localparam int V_BEATS = V_WORDS / LANES;
    localparam int TOTAL_BEATS = TOTAL_WORDS / LANES;
    localparam int BEAT_W =
        ((TOTAL_BEATS <= 1) ? 1 : $clog2(TOTAL_BEATS));
    localparam int Q_BEAT_ADDR_W =
        ((Q_BEATS <= 1) ? 1 : $clog2(Q_BEATS));
    localparam int K_BEAT_ADDR_W =
        ((K_BEATS <= 1) ? 1 : $clog2(K_BEATS));
    localparam int V_BEAT_ADDR_W =
        ((V_BEATS <= 1) ? 1 : $clog2(V_BEATS));
    localparam int LANE_W =
        ((LANES <= 1) ? 1 : $clog2(LANES));
    localparam int V_PAIRS_PER_BEAT = LANES / 2;
    localparam int V_PAIR_W =
        ((V_PAIRS_PER_BEAT <= 1) ? 1 : $clog2(V_PAIRS_PER_BEAT));

    logic [BEAT_W-1:0] ingress_beat;
    logic ingress_fire;

    typedef enum logic [1:0] {
        RAW_IDLE, RAW_WAIT_X0, RAW_WAIT_X1
    } raw_state_t;
    raw_state_t raw_state;
    logic raw_saved_is_k;
    logic [LANE_W-1:0] raw_saved_lane;
    logic [Q_BEAT_ADDR_W-1:0] raw_saved_x1_addr;
    logic [15:0] raw_x0_hold;
    logic [AXIS_DATA_W-1:0] q_read_data;
    logic [AXIS_DATA_W-1:0] k_read_data;

    logic [Q_BEAT_ADDR_W-1:0] q_x0_addr;
    logic [Q_BEAT_ADDR_W-1:0] q_x1_addr;
    logic [K_BEAT_ADDR_W-1:0] k_x0_addr;
    logic [K_BEAT_ADDR_W-1:0] k_x1_addr;
    logic [Q_BEAT_ADDR_W-1:0] q_write_addr;
    logic [K_BEAT_ADDR_W-1:0] k_write_addr;
    logic [V_BEAT_ADDR_W-1:0] v_write_addr;
    logic q_mem_write_enable;
    logic k_mem_write_enable;
    logic v_mem_write_enable;
    logic q_mem_read_enable;
    logic k_mem_read_enable;
    logic v_mem_read_enable;
    logic [Q_BEAT_ADDR_W-1:0] q_read_addr;
    logic [K_BEAT_ADDR_W-1:0] k_read_addr;
    logic [V_BEAT_ADDR_W-1:0] v_read_addr;
    logic [AXIS_DATA_W-1:0] v_read_data;

    typedef enum logic [1:0] {
        V_IDLE, V_FETCH, V_SEND
    } v_state_t;
    v_state_t v_state;
    logic [V_BEAT_ADDR_W-1:0] v_beat_index;
    logic [V_PAIR_W-1:0] v_pair_in_beat;
    function automatic logic [15:0] select_bf16_lane (
        input logic [AXIS_DATA_W-1:0] beat,
        input logic [LANE_W-1:0] lane_select
    );
        select_bf16_lane = beat[lane_select*16 +: 16];
    endfunction

    initial begin
        if ((AXIS_DATA_W < 16) || ((AXIS_DATA_W % 16) != 0))
            $error("axis_qkv_memory_bridge: AXIS_DATA_W must be a multiple of 16");
        if ((TOTAL_WORDS % LANES) != 0)
            $error("axis_qkv_memory_bridge: Q/K/V frame must fill complete AXIS beats");
        if ((HEAD_DIM % 2) != 0)
            $error("axis_qkv_memory_bridge: HEAD_DIM must be even");
        if ((HEAD_DIM % LANES) != 0)
            $error("axis_qkv_memory_bridge: HEAD_DIM must align to AXIS lanes");
        if ((HALF_DIM % LANES) != 0)
            $error("axis_qkv_memory_bridge: HEAD_DIM/2 must align to AXIS lanes");
        if ((LANES % 2) != 0)
            $error("axis_qkv_memory_bridge: AXIS beat must contain BF16 pairs");
    end

    assign s_axis_tready = aresetn && !frame_loaded &&
                           !ingress_protocol_error;
    assign ingress_fire = s_axis_tvalid && s_axis_tready;
    assign raw_req_ready = frame_loaded && (raw_state == RAW_IDLE) &&
                           !raw_rsp_valid;
    assign preload_busy = (v_state != V_IDLE);
    assign v_load_valid = (v_state == V_SEND);
    assign v_load_addr =
        (v_beat_index * LANES) + (v_pair_in_beat * 2);
    assign v_load_data =
        v_read_data[v_pair_in_beat*32 +: 32];
    assign q_write_addr = ingress_beat;
    assign k_write_addr = ingress_beat - Q_BEATS;
    assign v_write_addr = ingress_beat - Q_BEATS - K_BEATS;
    assign q_mem_write_enable =
        ingress_fire && (ingress_beat < Q_BEATS);
    assign k_mem_write_enable =
        ingress_fire && (ingress_beat >= Q_BEATS) &&
        (ingress_beat < (Q_BEATS + K_BEATS));
    assign v_mem_write_enable =
        ingress_fire && (ingress_beat >= (Q_BEATS + K_BEATS));
    assign q_mem_read_enable =
        (raw_req_valid && raw_req_ready && !raw_req_is_k) ||
        ((raw_state == RAW_WAIT_X0) && !raw_saved_is_k);
    assign k_mem_read_enable =
        (raw_req_valid && raw_req_ready && raw_req_is_k) ||
        ((raw_state == RAW_WAIT_X0) && raw_saved_is_k);
    assign q_read_addr =
        (raw_state == RAW_WAIT_X0) ?
        raw_saved_x1_addr : q_x0_addr;
    assign k_read_addr =
        (raw_state == RAW_WAIT_X0) ?
        raw_saved_x1_addr[K_BEAT_ADDR_W-1:0] : k_x0_addr;
    assign v_mem_read_enable = (v_state == V_FETCH);
    assign v_read_addr = v_beat_index;

    rk_xpm_sdpram #(
        .DATA_WIDTH(AXIS_DATA_W),
        .DEPTH(Q_BEATS),
        .ADDR_WIDTH(Q_BEAT_ADDR_W)
    ) u_q_memory (
        .clk(aclk),
        .rst(!aresetn),
        .write_enable(q_mem_write_enable),
        .write_address(q_write_addr),
        .write_data(s_axis_tdata),
        .read_enable(q_mem_read_enable),
        .read_address(q_read_addr),
        .read_data(q_read_data)
    );

    rk_xpm_sdpram #(
        .DATA_WIDTH(AXIS_DATA_W),
        .DEPTH(K_BEATS),
        .ADDR_WIDTH(K_BEAT_ADDR_W)
    ) u_k_memory (
        .clk(aclk),
        .rst(!aresetn),
        .write_enable(k_mem_write_enable),
        .write_address(k_write_addr),
        .write_data(s_axis_tdata),
        .read_enable(k_mem_read_enable),
        .read_address(k_read_addr),
        .read_data(k_read_data)
    );

    rk_xpm_sdpram #(
        .DATA_WIDTH(AXIS_DATA_W),
        .DEPTH(V_BEATS),
        .ADDR_WIDTH(V_BEAT_ADDR_W)
    ) u_v_memory (
        .clk(aclk),
        .rst(!aresetn),
        .write_enable(v_mem_write_enable),
        .write_address(v_write_addr),
        .write_data(s_axis_tdata),
        .read_enable(v_mem_read_enable),
        .read_address(v_read_addr),
        .read_data(v_read_data)
    );

    always_comb begin
        q_x0_addr =
            (((raw_req_head*SEQ_LEN) + raw_req_token) *
             BEATS_PER_VECTOR) +
            (raw_req_pair / LANES);
        q_x1_addr = q_x0_addr + HALF_BEATS_PER_VECTOR;
        k_x0_addr =
            (raw_req_token * BEATS_PER_VECTOR) +
            (raw_req_pair / LANES);
        k_x1_addr = k_x0_addr + HALF_BEATS_PER_VECTOR;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            frame_loaded <= 1'b0;
            ingress_protocol_error <= 1'b0;
            ingress_beat <= '0;
            input_beats <= '0;
        end else if (frame_clear) begin
            frame_loaded <= 1'b0;
            ingress_protocol_error <= 1'b0;
            ingress_beat <= '0;
        end else if (ingress_fire) begin
            if (ingress_beat == 0)
                input_beats <= 1;
            else
                input_beats <= input_beats + 1'b1;
            if (s_axis_tkeep != {AXIS_DATA_W/8{1'b1}})
                ingress_protocol_error <= 1'b1;

            if (ingress_beat == TOTAL_BEATS-1) begin
                if (s_axis_tlast &&
                    (s_axis_tkeep == {AXIS_DATA_W/8{1'b1}}))
                    frame_loaded <= 1'b1;
                else
                    ingress_protocol_error <= 1'b1;
            end else begin
                if (s_axis_tlast)
                    ingress_protocol_error <= 1'b1;
                ingress_beat <= ingress_beat + 1'b1;
            end
        end
    end

    // Q/K reads are deliberately serialized because the production core
    // allows only one outstanding raw request.  Two synchronous XPM reads
    // fetch x0 and x1 from the two vector halves without duplicating BRAM.
    always_ff @(posedge aclk) begin
        if (!aresetn || frame_clear) begin
            raw_state <= RAW_IDLE;
            raw_rsp_valid <= 1'b0;
            raw_rsp_x0 <= '0;
            raw_rsp_x1 <= '0;
            raw_saved_is_k <= 1'b0;
            raw_saved_lane <= '0;
            raw_saved_x1_addr <= '0;
            raw_x0_hold <= '0;
        end else begin
            if (raw_rsp_valid && raw_rsp_ready)
                raw_rsp_valid <= 1'b0;

            case (raw_state)
                RAW_IDLE: if (raw_req_valid && raw_req_ready) begin
                    raw_saved_is_k <= raw_req_is_k;
                    raw_saved_lane <= raw_req_pair % LANES;
                    if (raw_req_is_k)
                        raw_saved_x1_addr <= k_x1_addr;
                    else
                        raw_saved_x1_addr <= q_x1_addr;
                    raw_state <= RAW_WAIT_X0;
                end
                RAW_WAIT_X0: begin
                    if (raw_saved_is_k)
                        raw_x0_hold <= select_bf16_lane(
                            k_read_data, raw_saved_lane);
                    else
                        raw_x0_hold <= select_bf16_lane(
                            q_read_data, raw_saved_lane);
                    raw_state <= RAW_WAIT_X1;
                end
                RAW_WAIT_X1: begin
                    raw_rsp_x0 <= raw_x0_hold;
                    if (raw_saved_is_k)
                        raw_rsp_x1 <= select_bf16_lane(
                            k_read_data, raw_saved_lane);
                    else
                        raw_rsp_x1 <= select_bf16_lane(
                            q_read_data, raw_saved_lane);
                    raw_rsp_valid <= 1'b1;
                    raw_state <= RAW_IDLE;
                end
                default: raw_state <= RAW_IDLE;
            endcase
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn || frame_clear) begin
            v_state <= V_IDLE;
            v_beat_index <= '0;
            v_pair_in_beat <= '0;
            preload_done_pulse <= 1'b0;
        end else begin
            preload_done_pulse <= 1'b0;
            case (v_state)
                V_IDLE: if (preload_start && frame_loaded) begin
                    v_beat_index <= '0;
                    v_pair_in_beat <= '0;
                    v_state <= V_FETCH;
                end
                V_FETCH: begin
                    v_state <= V_SEND;
                end
                V_SEND: if (v_load_ready) begin
                    if (v_pair_in_beat == V_PAIRS_PER_BEAT-1) begin
                        v_pair_in_beat <= '0;
                        if (v_beat_index == V_BEATS-1) begin
                            preload_done_pulse <= 1'b1;
                            v_state <= V_IDLE;
                        end else begin
                            v_beat_index <= v_beat_index + 1'b1;
                            v_state <= V_FETCH;
                        end
                    end else begin
                        v_pair_in_beat <= v_pair_in_beat + 1'b1;
                    end
                end
                default: v_state <= V_IDLE;
            endcase
        end
    end
endmodule
