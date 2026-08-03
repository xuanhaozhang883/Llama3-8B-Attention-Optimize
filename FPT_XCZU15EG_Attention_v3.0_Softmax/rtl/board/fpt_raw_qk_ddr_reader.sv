`timescale 1ns/1ps

// One-line cache for the raw pre-RoPE Q/K request contract.
// Each cache fill fetches one complete [HEAD_DIM=128] token vector (256 B).
// RoPE uses split-half pairs: x0=dim[pair], x1=dim[pair+64].
module fpt_raw_qk_ddr_reader #(
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int GLOBAL_HEAD_W = 5,
    parameter int POS_W = 7,
    parameter int PAIR_W = 6
) (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic [31:0] q_base_addr,
    input  logic [31:0] k_base_addr,

    input  logic raw_req_valid,
    output logic raw_req_ready,
    input  logic raw_req_is_k,
    input  logic [GLOBAL_HEAD_W-1:0] raw_req_head,
    input  logic [POS_W-1:0] raw_req_token,
    input  logic [PAIR_W-1:0] raw_req_pair,
    output logic raw_rsp_valid,
    input  logic raw_rsp_ready,
    output logic [15:0] raw_rsp_x0,
    output logic [15:0] raw_rsp_x1,

    output logic rd_start,
    input  logic rd_ready,
    output logic [31:0] rd_addr,
    output logic [31:0] rd_len,
    input  logic rd_data_we,
    input  logic [63:0] rd_data,
    output logic rd_fifo_full,
    input  logic rd_done,
    input  logic rd_error,

    output logic busy,
    output logic error
);
    localparam int HALF_DIM = HEAD_DIM/2;
    localparam int LINE_BYTES = HEAD_DIM*2;
    localparam int LINE_BEATS = LINE_BYTES/8;
    localparam int BEAT_W = (LINE_BEATS <= 1) ? 1 : $clog2(LINE_BEATS+1);

    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_FILL} state_t;
    state_t state;

    (* ram_style = "distributed" *) logic [15:0] line_mem [0:HEAD_DIM-1];
    logic line_valid;
    logic line_is_k;
    logic [GLOBAL_HEAD_W-1:0] line_head;
    logic [POS_W-1:0] line_token;

    logic miss_is_k;
    logic [GLOBAL_HEAD_W-1:0] miss_head;
    logic [POS_W-1:0] miss_token;
    logic [BEAT_W-1:0] beat_count;

    logic line_match;
    logic [31:0] vector_number;
    logic [31:0] fill_base;

    assign line_match = line_valid &&
                        line_is_k == raw_req_is_k &&
                        line_head == raw_req_head &&
                        line_token == raw_req_token;

    assign raw_req_ready = enable && (state == S_IDLE) && line_match &&
                           !raw_rsp_valid;
    assign busy = (state != S_IDLE);
    assign rd_len = LINE_BYTES;
    assign rd_fifo_full = 1'b0;

    always_comb begin
        vector_number = $unsigned(miss_head) * SEQ_LEN +
                        $unsigned(miss_token);
        fill_base = (miss_is_k ? k_base_addr : q_base_addr) +
                    vector_number * LINE_BYTES;
        rd_addr = fill_base;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            line_valid    <= 1'b0;
            line_is_k     <= 1'b0;
            line_head     <= '0;
            line_token    <= '0;
            miss_is_k     <= 1'b0;
            miss_head     <= '0;
            miss_token    <= '0;
            beat_count    <= '0;
            rd_start      <= 1'b0;
            raw_rsp_valid <= 1'b0;
            raw_rsp_x0    <= '0;
            raw_rsp_x1    <= '0;
            error         <= 1'b0;
        end else begin
            rd_start <= 1'b0;

            if (raw_rsp_valid && raw_rsp_ready)
                raw_rsp_valid <= 1'b0;

            if (rd_error)
                error <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (enable && raw_req_valid && !line_match) begin
                        if ($unsigned(raw_req_token) >= SEQ_LEN ||
                            $unsigned(raw_req_pair) >= HALF_DIM ||
                            (!raw_req_is_k && $unsigned(raw_req_head) >= 32) ||
                            (raw_req_is_k && $unsigned(raw_req_head) >= 8)) begin
                            error <= 1'b1;
                        end else begin
                            miss_is_k  <= raw_req_is_k;
                            miss_head  <= raw_req_head;
                            miss_token <= raw_req_token;
                            line_valid <= 1'b0;
                            state      <= S_ISSUE;
                        end
                    end

                    if (raw_req_valid && raw_req_ready) begin
                        raw_rsp_x0    <= line_mem[$unsigned(raw_req_pair)];
                        raw_rsp_x1    <= line_mem[$unsigned(raw_req_pair)+HALF_DIM];
                        raw_rsp_valid <= 1'b1;
                    end
                end

                S_ISSUE: begin
                    if (rd_ready) begin
                        beat_count <= '0;
                        rd_start   <= 1'b1;
                        state      <= S_FILL;
                    end
                end

                S_FILL: begin
                    if (rd_data_we) begin
                        line_mem[$unsigned(beat_count)*4 + 0] <= rd_data[15:0];
                        line_mem[$unsigned(beat_count)*4 + 1] <= rd_data[31:16];
                        line_mem[$unsigned(beat_count)*4 + 2] <= rd_data[47:32];
                        line_mem[$unsigned(beat_count)*4 + 3] <= rd_data[63:48];
                        beat_count <= beat_count + 1'b1;
                    end

                    if (rd_done) begin
                        if (($unsigned(beat_count) + (rd_data_we ? 1 : 0)) != LINE_BEATS)
                            error <= 1'b1;
                        line_is_k  <= miss_is_k;
                        line_head  <= miss_head;
                        line_token <= miss_token;
                        line_valid <= 1'b1;
                        state      <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (HEAD_DIM != 128)
            $error("fpt_raw_qk_ddr_reader: this board version requires HEAD_DIM=128");
        if ((HEAD_DIM % 4) != 0)
            $error("fpt_raw_qk_ddr_reader: HEAD_DIM must divide into 64-bit beats");
    end
endmodule
