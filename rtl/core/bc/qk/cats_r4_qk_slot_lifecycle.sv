`timescale 1ns/1ps

// Logical ownership only. Physical score/weight storage remains C-owned.
// owner: 0=FREE, 1=A/QK, 2=B/Softmax-PV.
module cats_r4_qk_slot_lifecycle (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,

    input  logic          reserve_valid,
    output logic          reserve_ready,
    input  logic [15:0]   reserve_epoch,
    input  logic [2:0]    reserve_group,
    input  logic [4:0]    reserve_global_q_head,
    input  logic [6:0]    reserve_row,
    input  logic [1:0]    reserve_slot_id,
    input  logic [1:0]    reserve_numeric_mode,

    input  logic          handoff_valid,
    output logic          handoff_ready,
    input  logic [15:0]   handoff_epoch,
    input  logic [2:0]    handoff_group,
    input  logic [4:0]    handoff_global_q_head,
    input  logic [6:0]    handoff_row,
    input  logic [1:0]    handoff_slot_id,
    input  logic [1:0]    handoff_numeric_mode,

    // Cancel a row that failed while A still owns the score slot. The
    // external abort transfer and this transition must commit together.
    input  logic          abort_valid,
    output logic          abort_ready,
    input  logic [15:0]   abort_epoch,
    input  logic [2:0]    abort_group,
    input  logic [4:0]    abort_global_q_head,
    input  logic [6:0]    abort_row,
    input  logic [1:0]    abort_slot_id,
    input  logic [1:0]    abort_numeric_mode,

    input  logic          release_valid,
    output logic          release_ready,
    input  logic [15:0]   release_epoch,
    input  logic [2:0]    release_group,
    input  logic [4:0]    release_global_q_head,
    input  logic [6:0]    release_row,
    input  logic [1:0]    release_slot_id,
    input  logic [1:0]    release_numeric_mode,

    output logic [5:0]    slot_owner,
    output logic [63:0]   reserves,
    output logic [63:0]   handoffs,
    output logic [63:0]   aborts,
    output logic [63:0]   releases,
    output logic [63:0]   owner_errors,
    output logic          owner_error_sticky
);
    logic [1:0] owner [0:3];
    logic [15:0] token_epoch [0:3];
    logic [2:0] token_group [0:3];
    logic [4:0] token_head [0:3];
    logic [6:0] token_row [0:3];
    logic [1:0] token_mode [0:3];
    logic release_reject_seen;
    logic abort_reject_seen;
    logic release_reject_event;
    logic abort_reject_event;
    integer i;

    function automatic logic token_matches(
        input logic [1:0] slot,
        input logic [15:0] epoch,
        input logic [2:0] group_id,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] mode
    );
        begin
            token_matches = slot < 3 &&
                            token_epoch[slot] == epoch &&
                            token_group[slot] == group_id &&
                            token_head[slot] == head &&
                            token_row[slot] == row_id &&
                            token_mode[slot] == mode;
        end
    endfunction

    always_comb begin
        reserve_ready = reserve_slot_id < 3 &&
                        reserve_global_q_head[4:2] == reserve_group &&
                        reserve_numeric_mode < 2 &&
                        owner[reserve_slot_id] == 0;
        abort_ready = abort_slot_id < 3 &&
                      owner[abort_slot_id] == 1 &&
                      token_matches(abort_slot_id, abort_epoch,
                                    abort_group, abort_global_q_head,
                                    abort_row, abort_numeric_mode);
        // For one slot an accepted abort has priority over a competing
        // final-score ownership handoff.
        handoff_ready = handoff_slot_id < 3 &&
                        owner[handoff_slot_id] == 1 &&
                        token_matches(handoff_slot_id, handoff_epoch,
                                      handoff_group, handoff_global_q_head,
                                      handoff_row, handoff_numeric_mode) &&
                        !(abort_valid && abort_ready &&
                          abort_slot_id == handoff_slot_id);
        release_ready = release_slot_id < 3 &&
                        owner[release_slot_id] == 2 &&
                        token_matches(release_slot_id, release_epoch,
                                      release_group, release_global_q_head,
                                      release_row, release_numeric_mode);
        slot_owner = {owner[2], owner[1], owner[0]};
        release_reject_event = release_valid && !release_ready &&
                               !release_reject_seen;
        abort_reject_event = abort_valid && !abort_ready &&
                             !abort_reject_seen;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            for (i = 0; i < 4; i = i + 1) begin
                owner[i] <= 0;
                token_epoch[i] <= 0;
                token_group[i] <= 0;
                token_head[i] <= 0;
                token_row[i] <= 0;
                token_mode[i] <= 0;
            end
        end else begin
            if (reserve_valid && reserve_ready) begin
                owner[reserve_slot_id] <= 1;
                token_epoch[reserve_slot_id] <= reserve_epoch;
                token_group[reserve_slot_id] <= reserve_group;
                token_head[reserve_slot_id] <= reserve_global_q_head;
                token_row[reserve_slot_id] <= reserve_row;
                token_mode[reserve_slot_id] <= reserve_numeric_mode;
            end
            if (handoff_valid && handoff_ready)
                owner[handoff_slot_id] <= 2;
            if (abort_valid && abort_ready)
                owner[abort_slot_id] <= 0;
            if (release_valid && release_ready)
                owner[release_slot_id] <= 0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || counter_clear) begin
            reserves <= 0;
            handoffs <= 0;
            aborts <= 0;
            releases <= 0;
            owner_errors <= 0;
            owner_error_sticky <= 0;
            release_reject_seen <= 0;
            abort_reject_seen <= 0;
        end else if (clear) begin
            release_reject_seen <= 0;
            abort_reject_seen <= 0;
        end else begin
            if (reserve_valid && reserve_ready)
                reserves <= reserves + 1'b1;
            if (handoff_valid && handoff_ready)
                handoffs <= handoffs + 1'b1;
            if (abort_valid && abort_ready)
                aborts <= aborts + 1'b1;
            if (release_valid && release_ready)
                releases <= releases + 1'b1;
            if (!release_valid)
                release_reject_seen <= 1'b0;
            else if (release_reject_event) begin
                release_reject_seen <= 1'b1;
            end
            if (!abort_valid)
                abort_reject_seen <= 1'b0;
            else if (abort_reject_event)
                abort_reject_seen <= 1'b1;
            if (release_reject_event || abort_reject_event) begin
                owner_errors <= owner_errors + release_reject_event +
                                abort_reject_event;
                owner_error_sticky <= 1'b1;
            end
        end
    end
endmodule
