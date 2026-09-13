`timescale 1ns/1ps

module cats_r4_qk_score_slot_mem (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,

    input  logic          store_wr_valid,
    output logic          store_wr_ready,
    input  logic [1:0]    store_wr_slot_id,
    input  logic [6:0]    store_wr_key_base,
    input  logic [31:0]   store_wr_lane_valid,
    input  logic [511:0]  store_wr_score_bf16,

    input  logic          score_rd_req_valid,
    output logic          score_rd_req_ready,
    input  logic [15:0]   score_rd_req_epoch,
    input  logic [2:0]    score_rd_req_group,
    input  logic [4:0]    score_rd_req_global_q_head,
    input  logic [6:0]    score_rd_req_row,
    input  logic [6:0]    score_rd_req_key,
    input  logic [1:0]    score_rd_req_slot_id,
    input  logic [1:0]    score_rd_req_numeric_mode,

    output logic          score_rd_rsp_valid,
    input  logic          score_rd_rsp_ready,
    output logic [15:0]   score_rd_rsp_epoch,
    output logic [2:0]    score_rd_rsp_group,
    output logic [4:0]    score_rd_rsp_global_q_head,
    output logic [6:0]    score_rd_rsp_row,
    output logic [6:0]    score_rd_rsp_key,
    output logic [1:0]    score_rd_rsp_slot_id,
    output logic [1:0]    score_rd_rsp_numeric_mode,
    output logic [15:0]   score_rd_rsp_bf16,

    output logic [63:0]   write_vectors,
    output logic [63:0]   write_scores,
    output logic [63:0]   read_requests,
    output logic [63:0]   read_responses,
    output logic [63:0]   read_stall_cycles,
    output logic [63:0]   protocol_errors,
    output logic          protocol_error_sticky
);
    (* ram_style = "distributed" *) logic [15:0] slot_mem_0 [0:127];
    (* ram_style = "distributed" *) logic [15:0] slot_mem_1 [0:127];
    (* ram_style = "distributed" *) logic [15:0] slot_mem_2 [0:127];

    logic rsp_can_accept;
    logic store_wr_fire;
    logic score_rd_req_fire;
    logic score_rd_rsp_fire;
    logic illegal_write_attempt;
    logic illegal_read_attempt;
    logic [15:0] selected_read_bf16;
    integer lane_index;

    function automatic logic [5:0] count_valid_lanes(
        input logic [31:0] lane_valid
    );
        integer count_index;
        begin
            count_valid_lanes = 0;
            for (count_index = 0; count_index < 32;
                 count_index = count_index + 1)
                count_valid_lanes = count_valid_lanes + lane_valid[count_index];
        end
    endfunction

    assign rsp_can_accept = !score_rd_rsp_valid || score_rd_rsp_ready;
    assign score_rd_req_ready = rsp_can_accept && score_rd_req_slot_id < 3;
    assign store_wr_ready = store_wr_slot_id < 3 &&
                            store_wr_key_base[4:0] == 5'd0;

    assign store_wr_fire = store_wr_valid && store_wr_ready;
    assign score_rd_req_fire = score_rd_req_valid && score_rd_req_ready;
    assign score_rd_rsp_fire = score_rd_rsp_valid && score_rd_rsp_ready;
    assign illegal_write_attempt = store_wr_valid &&
                                   (store_wr_slot_id >= 3 ||
                                    store_wr_key_base[4:0] != 5'd0);
    assign illegal_read_attempt = score_rd_req_valid &&
                                  score_rd_req_slot_id >= 3;

    always_comb begin
        case (score_rd_req_slot_id)
            2'd0: selected_read_bf16 = slot_mem_0[score_rd_req_key];
            2'd1: selected_read_bf16 = slot_mem_1[score_rd_req_key];
            2'd2: selected_read_bf16 = slot_mem_2[score_rd_req_key];
            default: selected_read_bf16 = 16'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst_n && !clear && store_wr_fire) begin
            for (lane_index = 0; lane_index < 32;
                 lane_index = lane_index + 1) begin
                if (store_wr_lane_valid[lane_index]) begin
                    case (store_wr_slot_id)
                        2'd0: slot_mem_0[store_wr_key_base + lane_index] <=
                               store_wr_score_bf16[lane_index*16 +: 16];
                        2'd1: slot_mem_1[store_wr_key_base + lane_index] <=
                               store_wr_score_bf16[lane_index*16 +: 16];
                        2'd2: slot_mem_2[store_wr_key_base + lane_index] <=
                               store_wr_score_bf16[lane_index*16 +: 16];
                        default: begin end
                    endcase
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            score_rd_rsp_valid <= 1'b0;
        end else begin
            if (score_rd_req_fire) begin
                score_rd_rsp_valid <= 1'b1;
                score_rd_rsp_epoch <= score_rd_req_epoch;
                score_rd_rsp_group <= score_rd_req_group;
                score_rd_rsp_global_q_head <= score_rd_req_global_q_head;
                score_rd_rsp_row <= score_rd_req_row;
                score_rd_rsp_key <= score_rd_req_key;
                score_rd_rsp_slot_id <= score_rd_req_slot_id;
                score_rd_rsp_numeric_mode <= score_rd_req_numeric_mode;
                score_rd_rsp_bf16 <= selected_read_bf16;
            end else if (score_rd_rsp_fire) begin
                score_rd_rsp_valid <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || counter_clear) begin
            write_vectors <= 0;
            write_scores <= 0;
            read_requests <= 0;
            read_responses <= 0;
            read_stall_cycles <= 0;
            protocol_errors <= 0;
            protocol_error_sticky <= 1'b0;
        end else if (!clear) begin
            if (store_wr_fire) begin
                write_vectors <= write_vectors + 1'b1;
                write_scores <= write_scores +
                                count_valid_lanes(store_wr_lane_valid);
            end
            if (score_rd_req_fire)
                read_requests <= read_requests + 1'b1;
            if (score_rd_rsp_fire)
                read_responses <= read_responses + 1'b1;
            if (score_rd_rsp_valid && !score_rd_rsp_ready)
                read_stall_cycles <= read_stall_cycles + 1'b1;
            if (illegal_write_attempt || illegal_read_attempt) begin
                protocol_errors <= protocol_errors +
                                   {63'd0, illegal_write_attempt} +
                                   {63'd0, illegal_read_attempt};
                protocol_error_sticky <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic held_rsp;
    logic [57:0] held_rsp_payload;
    wire [57:0] rsp_payload = {
        score_rd_rsp_epoch,
        score_rd_rsp_group,
        score_rd_rsp_global_q_head,
        score_rd_rsp_row,
        score_rd_rsp_key,
        score_rd_rsp_slot_id,
        score_rd_rsp_numeric_mode,
        score_rd_rsp_bf16
    };

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            held_rsp <= 1'b0;
            held_rsp_payload <= 0;
        end else begin
            if (held_rsp &&
                (!score_rd_rsp_valid || rsp_payload != held_rsp_payload))
                $fatal(1, "A3 score response changed while stalled");
            if (store_wr_valid && store_wr_slot_id >= 3)
                $fatal(1, "A3 score write used invalid slot");
            if (score_rd_req_valid && score_rd_req_slot_id >= 3)
                $fatal(1, "A3 score read used invalid slot");

            held_rsp <= score_rd_rsp_valid && !score_rd_rsp_ready;
            if (score_rd_rsp_valid && !score_rd_rsp_ready)
                held_rsp_payload <= rsp_payload;
        end
    end
`endif
endmodule
