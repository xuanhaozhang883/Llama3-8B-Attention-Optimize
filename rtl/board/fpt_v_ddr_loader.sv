`timescale 1ns/1ps

// Streams V from PS DDR into a parameterized 2-, 4- or 8-lane BF16 V cache.
// The physical DDR read beat is 64 bits (four BF16 values).  Eight-lane mode
// atomically joins two adjacent beats before asserting v_load_valid.
// DDR layout: V[kv_head][token][dim], contiguous uint16/BF16, little-endian.
module fpt_v_ddr_loader #(
    parameter int RUN_GROUPS = 1,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int V_ADDR_W = 17,
    parameter int LOAD_LANES = 4
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [31:0] v_base_addr,

    output logic busy,
    output logic done,
    output logic error,

    output logic rd_start,
    input  logic rd_ready,
    output logic [31:0] rd_addr,
    output logic [31:0] rd_len,
    input  logic rd_data_we,
    input  logic [63:0] rd_data,
    output logic rd_fifo_full,
    input  logic rd_done,
    input  logic rd_error,

    output logic v_load_valid,
    input  logic v_load_ready,
    output logic [V_ADDR_W-1:0] v_load_addr,
    output logic [LOAD_LANES*16-1:0] v_load_data
);
    localparam int TOTAL_SCALARS = RUN_GROUPS * SEQ_LEN * HEAD_DIM;
    localparam int TOTAL_BYTES   = TOTAL_SCALARS * 2;
    localparam int VECTORS_PER_BEAT =
        (LOAD_LANES <= 4) ? (4/LOAD_LANES) : 1;
    localparam int BEATS_PER_VECTOR =
        (LOAD_LANES <= 4) ? 1 : (LOAD_LANES/4);
    localparam int HOLD_W = (LOAD_LANES*16 < 64) ? 64 : LOAD_LANES*16;

    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_STREAM, S_FINISH} state_t;
    state_t state;

    logic [HOLD_W-1:0] beat_hold;
    logic beat_valid;
    logic [1:0] vector_index;
    logic [1:0] beat_index;
    logic read_done_seen;
    logic [V_ADDR_W:0] scalar_addr;

    assign busy = (state != S_IDLE);
    assign rd_addr = v_base_addr;
    assign rd_len = TOTAL_BYTES;
    assign rd_fifo_full = beat_valid;

    assign v_load_valid = beat_valid;
    assign v_load_addr = scalar_addr[V_ADDR_W-1:0];
    assign v_load_data =
        beat_hold[vector_index*LOAD_LANES*16 +: LOAD_LANES*16];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            done           <= 1'b0;
            error          <= 1'b0;
            rd_start       <= 1'b0;
            beat_hold      <= '0;
            beat_valid     <= 1'b0;
            vector_index   <= '0;
            beat_index     <= '0;
            read_done_seen <= 1'b0;
            scalar_addr    <= '0;
        end else begin
            done     <= 1'b0;
            rd_start <= 1'b0;

            if (rd_error)
                error <= 1'b1;

            case (state)
                S_IDLE: begin
                    beat_valid     <= 1'b0;
                    vector_index   <= '0;
                    beat_index     <= '0;
                    read_done_seen <= 1'b0;
                    scalar_addr    <= '0;
                    if (start) begin
                        error <= 1'b0;
                        state <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    if (rd_ready) begin
                        rd_start <= 1'b1;
                        state    <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    if (rd_data_we) begin
                        if (beat_valid) begin
                            error <= 1'b1;
                        end else if (LOAD_LANES <= 4) begin
                            beat_hold[63:0] <= rd_data;
                            beat_valid <= 1'b1;
                            vector_index <= '0;
                        end else begin
                            beat_hold[beat_index*64 +: 64] <= rd_data;
                            if ($unsigned(beat_index) ==
                                BEATS_PER_VECTOR-1) begin
                                beat_index <= '0;
                                beat_valid <= 1'b1;
                            end else begin
                                beat_index <= beat_index + 1'b1;
                            end
                        end
                    end

                    if (beat_valid && v_load_ready) begin
                        scalar_addr <= scalar_addr + LOAD_LANES;
                        if ($unsigned(vector_index) ==
                            VECTORS_PER_BEAT-1) begin
                            vector_index <= '0;
                            beat_valid  <= 1'b0;
                        end else begin
                            vector_index <= vector_index + 1'b1;
                        end
                    end

                    if (rd_done)
                        read_done_seen <= 1'b1;

                    if ((read_done_seen || rd_done) &&
                        !beat_valid && !rd_data_we) begin
                        state <= S_FINISH;
                    end
                end

                S_FINISH: begin
                    if (scalar_addr != TOTAL_SCALARS)
                        error <= 1'b1;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (RUN_GROUPS < 1 || RUN_GROUPS > 8)
            $error("fpt_v_ddr_loader: RUN_GROUPS must be 1..8");
        if ((TOTAL_SCALARS % 4) != 0)
            $error("fpt_v_ddr_loader: scalar count must be divisible by four");
        if (TOTAL_SCALARS > (1 << V_ADDR_W))
            $error("fpt_v_ddr_loader: V_ADDR_W is too small");
        if ((LOAD_LANES != 2) && (LOAD_LANES != 4) && (LOAD_LANES != 8))
            $error("fpt_v_ddr_loader: LOAD_LANES must be 2, 4 or 8");
        if ((LOAD_LANES <= 4) && ((4 % LOAD_LANES) != 0))
            $error("fpt_v_ddr_loader: narrow LOAD_LANES must divide a DDR beat");
        if ((LOAD_LANES > 4) && ((LOAD_LANES % 4) != 0))
            $error("fpt_v_ddr_loader: wide LOAD_LANES must contain whole DDR beats");
    end
endmodule
