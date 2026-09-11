`timescale 1ns/1ps

// CATS-R4 IF_V3 software-B replay adapter.
// It turns deterministic software-Golden weights into the frozen B->C stream.
// Verification stimulus only: intentionally absent from the production manifest.
module cats_r4_if_v3_replay_adapter #(
    parameter int KEYS = 128
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic        start_valid,
    output logic        start_ready,
    input  logic [15:0] start_epoch,
    input  logic [2:0]  start_group,
    input  logic [4:0]  start_global_q_head,
    input  logic [6:0]  start_row,
    input  logic [1:0]  start_slot_id,
    input  logic [1:0]  start_numeric_mode,
    input  logic [31:0] start_sum_fp32,
    input  logic [31:0] start_inv_sum_fp32,

    output logic        weight_wr_valid,
    input  logic        weight_wr_ready,
    output logic [15:0] weight_wr_epoch,
    output logic [2:0]  weight_wr_group,
    output logic [4:0]  weight_wr_global_q_head,
    output logic [6:0]  weight_wr_row,
    output logic [1:0]  weight_wr_slot_id,
    output logic [1:0]  weight_wr_numeric_mode,
    output logic [6:0]  weight_wr_key,
    output logic        weight_wr_mask,
    output logic [31:0] weight_wr_data,
    output logic        weight_wr_last,

    output logic        row_commit_valid,
    input  logic        row_commit_ready,
    output logic [15:0] row_commit_epoch,
    output logic [2:0]  row_commit_group,
    output logic [4:0]  row_commit_global_q_head,
    output logic [6:0]  row_commit_row,
    output logic [1:0]  row_commit_slot_id,
    output logic [1:0]  row_commit_numeric_mode,
    output logic [31:0] row_commit_sum_fp32,
    output logic [31:0] row_commit_inv_sum_fp32,

    input  logic [31:0] weight_data [0:KEYS-1]
);
    typedef enum logic [1:0] {ST_IDLE, ST_WRITE, ST_COMMIT} state_t;
    state_t state;
    logic [15:0] epoch_reg;
    logic [2:0] group_reg;
    logic [4:0] head_reg;
    logic [6:0] row_reg;
    logic [1:0] slot_reg;
    logic [1:0] mode_reg;
    logic [31:0] sum_reg, inv_sum_reg;
    logic [6:0] key_reg;

    assign start_ready = state == ST_IDLE;
    assign weight_wr_valid = state == ST_WRITE;
    assign weight_wr_epoch = epoch_reg;
    assign weight_wr_group = group_reg;
    assign weight_wr_global_q_head = head_reg;
    assign weight_wr_row = row_reg;
    assign weight_wr_slot_id = slot_reg;
    assign weight_wr_numeric_mode = mode_reg;
    assign weight_wr_key = key_reg;
    assign weight_wr_mask = key_reg > row_reg;
    assign weight_wr_data = weight_wr_mask ? 32'd0 : weight_data[key_reg];
    assign weight_wr_last = key_reg == KEYS-1;

    assign row_commit_valid = state == ST_COMMIT;
    assign row_commit_epoch = epoch_reg;
    assign row_commit_group = group_reg;
    assign row_commit_global_q_head = head_reg;
    assign row_commit_row = row_reg;
    assign row_commit_slot_id = slot_reg;
    assign row_commit_numeric_mode = mode_reg;
    assign row_commit_sum_fp32 = sum_reg;
    assign row_commit_inv_sum_fp32 = inv_sum_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            state <= ST_IDLE;
            epoch_reg <= '0;
            group_reg <= '0;
            head_reg <= '0;
            row_reg <= '0;
            slot_reg <= '0;
            mode_reg <= '0;
            sum_reg <= '0;
            inv_sum_reg <= '0;
            key_reg <= '0;
        end else begin
            case (state)
                ST_IDLE: if (start_valid && start_ready) begin
                    epoch_reg <= start_epoch;
                    group_reg <= start_group;
                    head_reg <= start_global_q_head;
                    row_reg <= start_row;
                    slot_reg <= start_slot_id;
                    mode_reg <= start_numeric_mode;
                    sum_reg <= start_sum_fp32;
                    inv_sum_reg <= start_inv_sum_fp32;
                    key_reg <= '0;
                    state <= ST_WRITE;
                end
                ST_WRITE: if (weight_wr_valid && weight_wr_ready) begin
                    if (key_reg == KEYS-1)
                        state <= ST_COMMIT;
                    else
                        key_reg <= key_reg + 1'b1;
                end
                ST_COMMIT: if (row_commit_valid && row_commit_ready)
                    state <= ST_IDLE;
                default: state <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if (KEYS != 128)
            $error("cats_r4_if_v3_replay_adapter: IF_V3 requires 128 keys");
    end
endmodule
