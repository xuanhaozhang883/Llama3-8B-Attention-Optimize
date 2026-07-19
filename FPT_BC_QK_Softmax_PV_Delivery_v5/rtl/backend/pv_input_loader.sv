`timescale 1ns/1ps

// Creates the vector stream required by a TILE x TILE PV outer-product engine:
//   p_vec[i] = P[row_base+i][reduce_index]
//   v_vec[j] = V[kv_head][reduce_index][feature_base+j]
//
// Schedule:
//   P row tile -> feature tile -> reduce index.
// Therefore each P row tile is reread once for every feature tile.
module pv_input_loader #(
    parameter int Q_HEADS = 4,
    parameter int KV_HEADS = 1,
    parameter int V_KV_HEADS = KV_HEADS,
    parameter bit USE_GROUP_ID_FOR_KV = 1'b0,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int TILE = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [2:0] group_id,

    input  logic        p_tile_valid,
    output logic        p_tile_ready,
    input  logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] p_tile_head,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] p_tile_row_base,
    output logic        p_tile_release,

    output logic        p_req_valid,
    input  logic        p_req_ready,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] p_req_reduce_index,
    input  logic        p_rsp_valid,
    output logic        p_rsp_ready,
    input  logic [TILE*16-1:0] p_rsp_data,

    output logic        v_req_valid,
    input  logic        v_req_ready,
    output logic [((V_KV_HEADS <= 1) ? 1 : $clog2(V_KV_HEADS))-1:0] v_req_kv_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] v_req_reduce_index,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] v_req_feature_base,
    output logic [(((V_KV_HEADS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 : $clog2(V_KV_HEADS*SEQ_LEN*HEAD_DIM))-1:0] v_req_addr,
    input  logic        v_rsp_valid,
    output logic        v_rsp_ready,
    input  logic [TILE*16-1:0] v_rsp_data,

    output logic [TILE*16-1:0] p_vec_bf16,
    output logic [TILE*16-1:0] v_vec_bf16,
    output logic        vec_valid,
    input  logic        vec_ready,
    output logic        vec_first,
    output logic        vec_last,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] vec_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] vec_row_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] vec_feature_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] vec_reduce_index,

    output logic        done,
    output logic        busy,
    output logic        protocol_error
);

    localparam int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int V_KV_W = (V_KV_HEADS <= 1) ? 1 : $clog2(V_KV_HEADS);
    localparam int SEQ_W  = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);
    localparam int FEAT_W = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int V_ELEMENTS = V_KV_HEADS * SEQ_LEN * HEAD_DIM;
    localparam int V_ADDR_W = (V_ELEMENTS <= 1) ? 1 : $clog2(V_ELEMENTS);
    localparam int GROUP_SIZE = Q_HEADS / KV_HEADS;
    localparam int GROUP_SHIFT = (GROUP_SIZE <= 1) ? 0 : $clog2(GROUP_SIZE);
    localparam bit GROUP_IS_POW2 =
        (GROUP_SIZE >= 1) && ((GROUP_SIZE & (GROUP_SIZE - 1)) == 0);
    localparam int KV_STRIDE = SEQ_LEN * HEAD_DIM;
    localparam int KV_STRIDE_SHIFT = (KV_STRIDE <= 1) ? 0 : $clog2(KV_STRIDE);
    localparam bit KV_STRIDE_IS_POW2 =
        (KV_STRIDE >= 1) && ((KV_STRIDE & (KV_STRIDE - 1)) == 0);

    typedef enum logic [1:0] {
        S_IDLE    = 2'd0,
        S_REQUEST = 2'd1,
        S_OUTPUT  = 2'd2,
        S_RELEASE = 2'd3
    } state_t;

    state_t state;

    logic [HEAD_W-1:0] head_reg;
    logic [V_KV_W-1:0] kv_head_reg;
    logic [V_KV_W-1:0] mapped_kv_head;
    logic [2:0] group_id_reg;
    logic [SEQ_W-1:0] row_base_reg;
    logic [FEAT_W-1:0] feature_base_reg;
    logic [SEQ_W-1:0] reduce_reg;
    logic [V_ADDR_W-1:0] mapped_kv_wide;
    logic [V_ADDR_W-1:0] mapped_kv_base;
    logic [V_ADDR_W-1:0] kv_base_reg;
    logic [V_ADDR_W-1:0] v_addr_reg;
    logic [SEQ_W-1:0] next_reduce;
    logic [FEAT_W-1:0] next_feature_base;
    logic [V_ADDR_W-1:0] next_v_addr;
    logic tile_has_next;
    logic preissue_next;

    logic p_req_sent;
    logic v_req_sent;
    logic p_data_valid;
    logic v_data_valid;
    logic [TILE*16-1:0] p_data_reg;
    logic [TILE*16-1:0] v_data_reg;

    // Group-mode C uses the externally latched global KV head. The standalone
    // 32Q/8KV OOC path retains local Q-head-to-KV-head mapping.
    generate
        if (USE_GROUP_ID_FOR_KV) begin : g_external_group_kv
            assign mapped_kv_head = group_id_reg;
        end else if (GROUP_IS_POW2) begin : g_group_shift
            assign mapped_kv_head = $unsigned(p_tile_head) >> GROUP_SHIFT;
        end else begin : g_group_divide
            assign mapped_kv_head = $unsigned(p_tile_head) / GROUP_SIZE;
        end
    endgenerate

    always_comb begin
        mapped_kv_wide = '0;
        mapped_kv_wide[V_KV_W-1:0] = mapped_kv_head;
    end

    // The target stride is 128*128=16384, therefore this elaborates as a
    // left shift instead of an address multiplier on KV260.
    generate
        if (KV_STRIDE_IS_POW2) begin : g_kv_base_shift
            assign mapped_kv_base = mapped_kv_wide << KV_STRIDE_SHIFT;
        end else begin : g_kv_base_multiply
            assign mapped_kv_base = mapped_kv_wide * KV_STRIDE;
        end
    endgenerate

    assign p_tile_ready = (state == S_IDLE);
    assign p_tile_release = (state == S_RELEASE);

    // When PV accepts the current vector, use that same edge to launch the
    // next P/V read. This preserves one outstanding request while removing
    // the otherwise idle REQUEST-entry cycle between adjacent vectors.
    assign preissue_next = (state == S_OUTPUT) && vec_ready && tile_has_next;

    assign p_req_valid = ((state == S_REQUEST) && !p_req_sent) || preissue_next;
    assign p_req_reduce_index = preissue_next ? next_reduce : reduce_reg;
    assign p_rsp_ready = (state == S_REQUEST) && !p_data_valid;

    assign v_req_valid = ((state == S_REQUEST) && !v_req_sent) || preissue_next;
    assign v_req_kv_head = kv_head_reg;
    assign v_req_reduce_index = preissue_next ? next_reduce : reduce_reg;
    assign v_req_feature_base = preissue_next ? next_feature_base :
                                                        feature_base_reg;
    assign v_rsp_ready = (state == S_REQUEST) && !v_data_valid;

    // v_addr_reg starts at the KV-head base, advances by HEAD_DIM for every
    // reduction beat, and returns to the next feature base after each pass.
    assign v_req_addr = preissue_next ? next_v_addr : v_addr_reg;

    assign p_vec_bf16 = p_data_reg;
    assign v_vec_bf16 = v_data_reg;
    assign vec_valid = (state == S_OUTPUT);
    assign vec_first = (state == S_OUTPUT) && (reduce_reg == 0);
    assign vec_last  = (state == S_OUTPUT) && (reduce_reg == SEQ_LEN-1);
    assign vec_head = head_reg;
    assign vec_row_base = row_base_reg;
    assign vec_feature_base = feature_base_reg;
    assign vec_reduce_index = reduce_reg;

    assign busy = (state != S_IDLE);

    always_comb begin
        next_reduce       = reduce_reg;
        next_feature_base = feature_base_reg;
        next_v_addr       = v_addr_reg;
        tile_has_next     = 1'b1;

        if (reduce_reg == SEQ_LEN-1) begin
            next_reduce = '0;
            if (feature_base_reg + TILE < HEAD_DIM) begin
                next_feature_base = feature_base_reg + TILE;
                next_v_addr = kv_base_reg +
                              $unsigned(feature_base_reg) + TILE;
            end else begin
                tile_has_next = 1'b0;
            end
        end else begin
            next_reduce = reduce_reg + 1'b1;
            next_v_addr = v_addr_reg + HEAD_DIM;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            state              <= S_IDLE;
            head_reg           <= '0;
            kv_head_reg        <= '0;
            group_id_reg       <= group_id;
            row_base_reg       <= '0;
            feature_base_reg   <= '0;
            reduce_reg         <= '0;
            kv_base_reg        <= '0;
            v_addr_reg         <= '0;
            p_req_sent         <= 1'b0;
            v_req_sent         <= 1'b0;
            p_data_valid       <= 1'b0;
            v_data_valid       <= 1'b0;
            p_data_reg         <= '0;
            v_data_reg         <= '0;
            done               <= 1'b0;
            protocol_error     <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (p_tile_valid && p_tile_ready) begin
                        head_reg         <= p_tile_head;
                        kv_head_reg      <= mapped_kv_head;
                        row_base_reg     <= p_tile_row_base;
                        feature_base_reg <= '0;
                        reduce_reg       <= '0;
                        kv_base_reg      <= mapped_kv_base;
                        v_addr_reg       <= mapped_kv_base;
                        p_req_sent       <= 1'b0;
                        v_req_sent       <= 1'b0;
                        p_data_valid     <= 1'b0;
                        v_data_valid     <= 1'b0;
                        state            <= S_REQUEST;

                        if (($unsigned(p_tile_head) >= Q_HEADS) ||
                            ($unsigned(p_tile_row_base) >= SEQ_LEN) ||
                            (($unsigned(p_tile_row_base) & (TILE - 1)) != 0) ||
                            (USE_GROUP_ID_FOR_KV &&
                             ($unsigned(group_id_reg) >= V_KV_HEADS))) begin
                            protocol_error <= 1'b1;
                        end
                    end
                end

                S_REQUEST: begin
                    if (p_req_valid && p_req_ready)
                        p_req_sent <= 1'b1;
                    if (v_req_valid && v_req_ready)
                        v_req_sent <= 1'b1;

                    if (p_rsp_valid && p_rsp_ready) begin
                        p_data_reg   <= p_rsp_data;
                        p_data_valid <= 1'b1;
                        if (!p_req_sent && !(p_req_valid && p_req_ready))
                            protocol_error <= 1'b1;
                    end

                    if (v_rsp_valid && v_rsp_ready) begin
                        v_data_reg   <= v_rsp_data;
                        v_data_valid <= 1'b1;
                        if (!v_req_sent && !(v_req_valid && v_req_ready))
                            protocol_error <= 1'b1;
                    end

                    // Enter OUTPUT on the same edge that captures the last
                    // response. The data registers are valid immediately
                    // after that edge, avoiding one idle cycle per PV vector.
                    if ((p_req_sent || (p_req_valid && p_req_ready)) &&
                        (v_req_sent || (v_req_valid && v_req_ready)) &&
                        (p_data_valid || (p_rsp_valid && p_rsp_ready)) &&
                        (v_data_valid || (v_rsp_valid && v_rsp_ready))) begin
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    if (vec_valid && vec_ready) begin
                        p_data_valid <= 1'b0;
                        v_data_valid <= 1'b0;

                        if (tile_has_next) begin
                            reduce_reg       <= next_reduce;
                            feature_base_reg <= next_feature_base;
                            v_addr_reg       <= next_v_addr;
                            p_req_sent       <= p_req_valid && p_req_ready;
                            v_req_sent       <= v_req_valid && v_req_ready;
                            state            <= S_REQUEST;
                        end else begin
                            reduce_reg   <= '0;
                            p_req_sent   <= 1'b0;
                            v_req_sent   <= 1'b0;
                            state        <= S_RELEASE;
                        end
                    end
                end

                // Hold release for a complete cycle. The P buffer clears its
                // bank on this edge, so done can never overlap busy.
                S_RELEASE: begin
                    state <= S_IDLE;
                    if ((head_reg == Q_HEADS-1) &&
                        (row_base_reg == SEQ_LEN-TILE)) begin
                        done <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if ((Q_HEADS < 1) || (KV_HEADS < 1) || (V_KV_HEADS < 1))
            $error("pv_input_loader: head counts must be >= 1");
        if (Q_HEADS < KV_HEADS)
            $error("pv_input_loader: Q_HEADS must be >= KV_HEADS");
        if ((Q_HEADS % KV_HEADS) != 0)
            $error("pv_input_loader: Q_HEADS must be divisible by KV_HEADS");
        if ((SEQ_LEN % TILE) != 0)
            $error("pv_input_loader: SEQ_LEN must be divisible by TILE");
        if ((HEAD_DIM % TILE) != 0)
            $error("pv_input_loader: HEAD_DIM must be divisible by TILE");
        if ((TILE < 1) || ((TILE & (TILE - 1)) != 0))
            $error("pv_input_loader: TILE must be a positive power of two");
    end

endmodule
