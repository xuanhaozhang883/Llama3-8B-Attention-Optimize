`timescale 1ns/1ps

// Fully pipelined 32-feature-lane PV MAC service.
// Each lane performs binary32 multiply followed by a separately rounded
// binary32 add.  The controller supplies one request per independent RAW
// context; this service preserves request order through explicit metadata
// FIFOs and keeps 16x32 FP32 accumulator state.
module cats_r4_b3_pv_mac_32lane #(
    parameter int CONTEXTS = 16,
    parameter int LANES = 32,
    parameter int META_DEPTH = 32
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,
    input  logic          mac_valid,
    output logic          mac_ready,
    input  logic [3:0]    mac_context_tag,
    input  logic [6:0]    mac_key,
    input  logic          mac_first,
    input  logic          mac_last,
    input  logic [1:0]    mac_numeric_mode,
    input  logic [31:0]   mac_weight_data,
    input  logic [511:0]  mac_v_vec_bf16,
    output logic          mac_rsp_valid,
    input  logic          mac_rsp_ready,
    output logic [3:0]    mac_rsp_context_tag,
    output logic [6:0]    mac_rsp_key,
    output logic          mac_rsp_last,
    output logic [1023:0] mac_rsp_accum_fp32,
    output logic [63:0]   vector_issue_count,
    output logic [63:0]   lane_product_count,
    output logic [63:0]   lane_commit_count,
    output logic [63:0]   input_stall_cycles,
    output logic [63:0]   output_stall_cycles,
    output logic [63:0]   protocol_error_count,
    output logic          error_sticky
);
    localparam int PTR_W = $clog2(META_DEPTH);

    // One packed 32-lane word per RAW context avoids vendor-tool 3D-RAM
    // elaboration while retaining 32 independently addressable lane slices.
    logic [LANES*32-1:0] accum_mem [0:CONTEXTS-1];
    logic context_initialized [0:CONTEXTS-1];
    logic [6:0] context_last_key [0:CONTEXTS-1];

    logic [3:0] mul_meta_context [0:META_DEPTH-1];
    logic [6:0] mul_meta_key [0:META_DEPTH-1];
    logic mul_meta_first [0:META_DEPTH-1];
    logic mul_meta_last [0:META_DEPTH-1];
    logic [PTR_W-1:0] mul_meta_wr_ptr, mul_meta_rd_ptr;
    logic [PTR_W:0] mul_meta_count;

    logic [3:0] add_meta_context [0:META_DEPTH-1];
    logic [6:0] add_meta_key [0:META_DEPTH-1];
    logic add_meta_last [0:META_DEPTH-1];
    logic [PTR_W-1:0] add_meta_wr_ptr, add_meta_rd_ptr;
    logic [PTR_W:0] add_meta_count;

    logic [LANES-1:0] mul_a_ready, mul_b_ready;
    logic [LANES-1:0] mul_result_valid, mul_result_ready;
    logic [LANES*32-1:0] mul_result_data;
    logic [LANES-1:0] add_a_ready, add_b_ready;
    logic [LANES-1:0] add_result_valid, add_result_ready;
    logic [LANES*32-1:0] add_result_data;
    logic [31:0] weight_fp32;
    logic mul_all_input_ready, mul_all_result_valid;
    logic add_all_input_ready, add_all_result_valid;
    logic input_fire, mul_to_add_fire, add_commit_fire;
    logic output_room;
    logic request_order_legal;
    logic [3:0] mac_context_safe;
    logic [1023:0] mac_rsp_accum_reg;
    logic arithmetic_rst_n;

    integer seq_lane;
    integer seq_context;
    integer store_lane;

    assign weight_fp32 = mac_numeric_mode == 0 ?
                         {mac_weight_data[15:0],16'd0} : mac_weight_data;
    // clear is the transaction/epoch flush.  It must also flush the opaque
    // Floating Point Operator pipelines; clearing only the metadata FIFOs
    // would allow a pre-clear result to be paired with post-clear metadata.
    assign arithmetic_rst_n = rst_n && !clear;
    assign mul_all_input_ready = &mul_a_ready && &mul_b_ready;
    assign mac_ready = mul_all_input_ready && mul_meta_count < META_DEPTH &&
                       !error_sticky;
    assign input_fire = mac_valid && mac_ready;
    assign mul_all_result_valid = &mul_result_valid;
    assign add_all_input_ready = &add_a_ready && &add_b_ready;
    assign mul_to_add_fire = mul_meta_count != 0 &&
                             mul_all_result_valid &&
                             add_all_input_ready &&
                             add_meta_count < META_DEPTH;
    assign add_all_result_valid = &add_result_valid;
    assign output_room = !mac_rsp_valid || mac_rsp_ready;
    assign add_commit_fire = add_meta_count != 0 &&
                             add_all_result_valid && output_room;

    assign mac_context_safe = mac_context_tag < CONTEXTS ?
                              mac_context_tag : 0;
    assign request_order_legal = mac_context_tag < CONTEXTS &&
        (mac_first ? mac_key == 0 :
         context_initialized[mac_context_safe] &&
         mac_key == context_last_key[mac_context_safe] + 1'b1) &&
        mac_first == (mac_key == 0) && mac_numeric_mode < 2;

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : GEN_PV_LANE
            logic [31:0] v_fp32;
            assign v_fp32 = {mac_v_vec_bf16[lane*16 +: 16],16'd0};

            fp32_mul_ip #(.IP_ID(0)) u_mul (
                .clk(clk), .rst_n(arithmetic_rst_n),
                .a_valid(mac_valid && mac_ready),
                .a_ready(mul_a_ready[lane]), .a_data(weight_fp32),
                .b_valid(mac_valid && mac_ready),
                .b_ready(mul_b_ready[lane]), .b_data(v_fp32),
                .result_valid(mul_result_valid[lane]),
                .result_ready(mul_result_ready[lane]),
                .result_data(mul_result_data[lane*32 +: 32])
            );

            fp32_add_ip u_add (
                .clk(clk), .rst_n(arithmetic_rst_n),
                .a_valid(mul_to_add_fire),
                .a_ready(add_a_ready[lane]),
                .a_data(mul_meta_first[mul_meta_rd_ptr] ? 32'd0 :
                    accum_mem[mul_meta_context[mul_meta_rd_ptr]]
                             [lane*32 +: 32]),
                .b_valid(mul_to_add_fire),
                .b_ready(add_b_ready[lane]),
                .b_data(mul_result_data[lane*32 +: 32]),
                .result_valid(add_result_valid[lane]),
                .result_ready(add_result_ready[lane]),
                .result_data(add_result_data[lane*32 +: 32])
            );

            assign mul_result_ready[lane] = mul_meta_count == 0 ? 1'b1 :
                                            mul_to_add_fire;
            assign add_result_ready[lane] = add_meta_count == 0 ? 1'b1 :
                                            add_commit_fire;
        end
    endgenerate

    assign mac_rsp_accum_fp32 = mac_rsp_accum_reg;

    always_ff @(posedge clk or negedge rst_n) begin : p_service
        if (!rst_n) begin
            mul_meta_wr_ptr <= '0;
            mul_meta_rd_ptr <= '0;
            mul_meta_count <= '0;
            add_meta_wr_ptr <= '0;
            add_meta_rd_ptr <= '0;
            add_meta_count <= '0;
            mac_rsp_valid <= 1'b0;
            mac_rsp_context_tag <= '0;
            mac_rsp_key <= '0;
            mac_rsp_last <= 1'b0;
            mac_rsp_accum_reg <= '0;
            for (seq_context = 0; seq_context < CONTEXTS;
                 seq_context = seq_context + 1) begin
                context_initialized[seq_context] <= 1'b0;
                context_last_key[seq_context] <= '0;
            end
        end else if (clear) begin
            mul_meta_wr_ptr <= '0;
            mul_meta_rd_ptr <= '0;
            mul_meta_count <= '0;
            add_meta_wr_ptr <= '0;
            add_meta_rd_ptr <= '0;
            add_meta_count <= '0;
            mac_rsp_valid <= 1'b0;
            for (seq_context = 0; seq_context < CONTEXTS;
                 seq_context = seq_context + 1)
                context_initialized[seq_context] <= 1'b0;
        end else begin
            if (mac_rsp_valid && mac_rsp_ready)
                mac_rsp_valid <= 1'b0;

            if (input_fire) begin
                mul_meta_wr_ptr <= mul_meta_wr_ptr + 1'b1;
            end
            if (mul_to_add_fire) begin
                add_meta_wr_ptr <= add_meta_wr_ptr + 1'b1;
                mul_meta_rd_ptr <= mul_meta_rd_ptr + 1'b1;
            end
            case ({input_fire,mul_to_add_fire})
                2'b10: mul_meta_count <= mul_meta_count + 1'b1;
                2'b01: mul_meta_count <= mul_meta_count - 1'b1;
                default: mul_meta_count <= mul_meta_count;
            endcase

            if (add_commit_fire) begin
                context_initialized[add_meta_context[add_meta_rd_ptr]] <=
                    1'b1;
                context_last_key[add_meta_context[add_meta_rd_ptr]] <=
                    add_meta_key[add_meta_rd_ptr];
                mac_rsp_valid <= 1'b1;
                mac_rsp_context_tag <= add_meta_context[add_meta_rd_ptr];
                mac_rsp_key <= add_meta_key[add_meta_rd_ptr];
                mac_rsp_last <= add_meta_last[add_meta_rd_ptr];
                for (seq_lane = 0; seq_lane < LANES;
                     seq_lane = seq_lane + 1)
                    mac_rsp_accum_reg[seq_lane*32 +: 32] <=
                        add_result_data[seq_lane*32 +: 32];
                add_meta_rd_ptr <= add_meta_rd_ptr + 1'b1;
            end
            case ({mul_to_add_fire,add_commit_fire})
                2'b10: add_meta_count <= add_meta_count + 1'b1;
                2'b01: add_meta_count <= add_meta_count - 1'b1;
                default: add_meta_count <= add_meta_count;
            endcase
        end
    end

    // Payload memories intentionally have no reset.  Pointer/valid state is
    // reset above, so stale words are unreachable.  Keeping storage writes in
    // a reset-free process permits 32 independent depth-16 accumulator banks
    // and the shallow metadata FIFOs to infer RAM instead of thousands of FFs.
    always_ff @(posedge clk) begin : p_payload_storage
        if (rst_n && !clear) begin
            if (input_fire) begin
                mul_meta_context[mul_meta_wr_ptr] <= mac_context_safe;
                mul_meta_key[mul_meta_wr_ptr] <= mac_key;
                mul_meta_first[mul_meta_wr_ptr] <= mac_first;
                mul_meta_last[mul_meta_wr_ptr] <= mac_last;
            end
            if (mul_to_add_fire) begin
                add_meta_context[add_meta_wr_ptr] <=
                    mul_meta_context[mul_meta_rd_ptr];
                add_meta_key[add_meta_wr_ptr] <=
                    mul_meta_key[mul_meta_rd_ptr];
                add_meta_last[add_meta_wr_ptr] <=
                    mul_meta_last[mul_meta_rd_ptr];
            end
            if (add_commit_fire)
                for (store_lane = 0; store_lane < LANES;
                     store_lane = store_lane + 1)
                    accum_mem[add_meta_context[add_meta_rd_ptr]]
                             [store_lane*32 +: 32] <=
                        add_result_data[store_lane*32 +: 32];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_counters
        if (!rst_n) begin
            vector_issue_count <= '0;
            lane_product_count <= '0;
            lane_commit_count <= '0;
            input_stall_cycles <= '0;
            output_stall_cycles <= '0;
            protocol_error_count <= '0;
            error_sticky <= 1'b0;
        end else if (clear || counter_clear) begin
            vector_issue_count <= '0;
            lane_product_count <= '0;
            lane_commit_count <= '0;
            input_stall_cycles <= '0;
            output_stall_cycles <= '0;
            protocol_error_count <= '0;
            error_sticky <= 1'b0;
        end else begin
            if (input_fire) begin
                vector_issue_count <= vector_issue_count + 1'b1;
                if (!request_order_legal) begin
                    protocol_error_count <= protocol_error_count + 1'b1;
                    error_sticky <= 1'b1;
                end
            end
            if (mul_to_add_fire)
                lane_product_count <= lane_product_count + LANES;
            if (add_commit_fire)
                lane_commit_count <= lane_commit_count + LANES;
            if (mac_valid && !mac_ready)
                input_stall_cycles <= input_stall_cycles + 1'b1;
            if (mac_rsp_valid && !mac_rsp_ready)
                output_stall_cycles <= output_stall_cycles + 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !clear) begin
            if (mul_meta_count > META_DEPTH || add_meta_count > META_DEPTH)
                $fatal(1, "B3 PV MAC metadata FIFO overflow");
            if (mul_to_add_fire && !mul_all_result_valid)
                $fatal(1, "B3 PV multiplier lanes lost alignment");
            if (add_commit_fire && !add_all_result_valid)
                $fatal(1, "B3 PV adder lanes lost alignment");
        end
    end
`endif

    initial begin
        if (CONTEXTS != 16 || LANES != 32 || META_DEPTH < 16)
            $error("B3 PV MAC requires R=16, 32 lanes, metadata depth >=16");
    end
endmodule
