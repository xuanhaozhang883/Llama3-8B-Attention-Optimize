`timescale 1ns/1ps

// Traverses 4Q/1K for one GQA Group, requests split-half raw pairs, rotates
// them with the elastic BF16 pipeline and emits one cache write per pair.
module rope_group_prepare #(
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int Q_HEADS = 4,
    parameter int GQA_GROUPS = 8,
    parameter int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W = ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
                                      $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int PAIR_W = ((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2),
    parameter int ROM_DEPTH = SEQ_LEN*(HEAD_DIM/2),
    parameter SIN_ROM_FILE = "sin_bf16.hex",
    parameter COS_ROM_FILE = "cos_bf16.hex"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [GROUP_W-1:0] group_id,
    output logic start_ready,
    output logic busy,
    output logic done,
    output logic cache_clear,

    output logic raw_req_valid,
    input  logic raw_req_ready,
    output logic raw_req_is_k,
    output logic [GLOBAL_Q_HEAD_W-1:0] raw_req_head,
    output logic [POS_W-1:0] raw_req_token,
    output logic [PAIR_W-1:0] raw_req_pair,
    input  logic raw_rsp_valid,
    output logic raw_rsp_ready,
    input  logic [15:0] raw_rsp_x0,
    input  logic [15:0] raw_rsp_x1,

    output logic cache_wr_valid,
    input  logic cache_wr_ready,
    output logic cache_wr_is_k,
    output logic [HEAD_W-1:0] cache_wr_head,
    output logic [POS_W-1:0] cache_wr_token,
    output logic [PAIR_W-1:0] cache_wr_pair,
    output logic [15:0] cache_wr_y0,
    output logic [15:0] cache_wr_y1,
    output logic cache_mark_complete
);
    localparam int HALF_DIM = HEAD_DIM/2;
    localparam int ROM_ADDR_W = (ROM_DEPTH <= 1) ? 1 : $clog2(ROM_DEPTH);
    typedef enum logic [1:0] {S_IDLE, S_REQUEST, S_RESPONSE, S_RESULT} state_t;
    state_t state;

    logic [GROUP_W-1:0] group_reg;
    logic is_k_reg;
    logic [HEAD_W-1:0] head_reg;
    logic [POS_W-1:0] token_reg;
    logic [PAIR_W-1:0] pair_reg;
    logic [15:0] sin_rom [0:ROM_DEPTH-1];
    logic [15:0] cos_rom [0:ROM_DEPTH-1];
    logic [ROM_ADDR_W-1:0] rom_addr;

    logic pipe_in_valid, pipe_in_ready;
    logic pipe_out_valid, pipe_out_ready;
    logic [15:0] pipe_y0, pipe_y1;
    logic final_pair;

    assign start_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE);
    assign raw_req_valid = (state == S_REQUEST);
    assign raw_req_is_k = is_k_reg;
    assign raw_req_head = is_k_reg ? $unsigned(group_reg) :
                          ($unsigned(group_reg)*Q_HEADS + $unsigned(head_reg));
    assign raw_req_token = token_reg;
    assign raw_req_pair = pair_reg;
    assign rom_addr = $unsigned(token_reg)*HALF_DIM + $unsigned(pair_reg);

    assign pipe_in_valid = (state == S_RESPONSE) && raw_rsp_valid;
    assign raw_rsp_ready = (state == S_RESPONSE) && pipe_in_ready;
    assign pipe_out_ready = (state == S_RESULT) && cache_wr_ready;
    assign cache_wr_valid = (state == S_RESULT) && pipe_out_valid;
    assign cache_wr_is_k = is_k_reg;
    assign cache_wr_head = head_reg;
    assign cache_wr_token = token_reg;
    assign cache_wr_pair = pair_reg;
    assign cache_wr_y0 = pipe_y0;
    assign cache_wr_y1 = pipe_y1;
    assign final_pair = is_k_reg && (token_reg == SEQ_LEN-1) &&
                        (pair_reg == HALF_DIM-1);
    assign cache_mark_complete = cache_wr_valid && cache_wr_ready && final_pair;

    initial begin
        $readmemh(SIN_ROM_FILE, sin_rom);
        $readmemh(COS_ROM_FILE, cos_rom);
    end

    rope_pair_pipeline u_pair_pipeline (
        .clk(clk), .rst_n(rst_n),
        .in_valid(pipe_in_valid), .in_ready(pipe_in_ready),
        .in_x0(raw_rsp_x0), .in_x1(raw_rsp_x1),
        .in_sin(sin_rom[rom_addr]), .in_cos(cos_rom[rom_addr]),
        .out_valid(pipe_out_valid), .out_ready(pipe_out_ready),
        .out_y0(pipe_y0), .out_y1(pipe_y1)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            group_reg <= '0;
            is_k_reg <= 1'b0;
            head_reg <= '0;
            token_reg <= '0;
            pair_reg <= '0;
            done <= 1'b0;
            cache_clear <= 1'b0;
        end else begin
            done <= 1'b0;
            cache_clear <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    group_reg <= group_id;
                    is_k_reg <= 1'b0;
                    head_reg <= '0;
                    token_reg <= '0;
                    pair_reg <= '0;
                    cache_clear <= 1'b1;
                    state <= S_REQUEST;
                end
                S_REQUEST: if (raw_req_valid && raw_req_ready)
                    state <= S_RESPONSE;
                S_RESPONSE: if (raw_rsp_valid && raw_rsp_ready)
                    state <= S_RESULT;
                S_RESULT: if (cache_wr_valid && cache_wr_ready) begin
                    if (final_pair) begin
                        done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        if (pair_reg == HALF_DIM-1) begin
                            pair_reg <= '0;
                            if (token_reg == SEQ_LEN-1) begin
                                token_reg <= '0;
                                if (!is_k_reg && head_reg == Q_HEADS-1) begin
                                    is_k_reg <= 1'b1;
                                    head_reg <= '0;
                                end else begin
                                    head_reg <= head_reg + 1'b1;
                                end
                            end else begin
                                token_reg <= token_reg + 1'b1;
                            end
                        end else begin
                            pair_reg <= pair_reg + 1'b1;
                        end
                        state <= S_REQUEST;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if ((HEAD_DIM % 2) != 0)
            $error("rope_group_prepare: HEAD_DIM must be even");
        if (ROM_DEPTH < SEQ_LEN*HALF_DIM)
            $error("rope_group_prepare: ROM_DEPTH is too small");
    end
endmodule
