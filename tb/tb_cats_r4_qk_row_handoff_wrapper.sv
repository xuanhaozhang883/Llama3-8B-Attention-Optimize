`timescale 1ns/1ps

module tb_cats_r4_qk_row_handoff_wrapper;
    localparam int LANES = 4;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic txn_start_valid, txn_start_ready;
    logic [15:0] txn_epoch; logic [1:0] txn_numeric_mode;
    logic row_open_valid, row_open_ready;
    logic [15:0] row_open_epoch; logic [2:0] row_open_group;
    logic [4:0] row_open_global_q_head; logic [6:0] row_open_row;
    logic [1:0] row_open_slot_id, row_open_numeric_mode;
    logic block_valid, block_ready;
    logic [15:0] block_epoch; logic [2:0] block_group;
    logic [4:0] block_global_q_head; logic [6:0] block_row;
    logic [1:0] block_slot_id, block_numeric_mode, block_key_block;
    logic [LANES-1:0] block_lane_valid;
    logic [LANES*16-1:0] block_score_bf16;
    logic store_wr_valid, store_wr_ready;
    logic [1:0] store_wr_slot_id; logic [6:0] store_wr_key_base;
    logic [LANES-1:0] store_wr_lane_valid;
    logic [LANES*16-1:0] store_wr_score_bf16;
    logic score_rd_req_valid, score_rd_req_ready;
    logic [15:0] score_rd_req_epoch; logic [2:0] score_rd_req_group;
    logic [4:0] score_rd_req_global_q_head;
    logic [6:0] score_rd_req_row, score_rd_req_key;
    logic [1:0] score_rd_req_slot_id, score_rd_req_numeric_mode;
    logic score_rd_rsp_valid, score_rd_rsp_ready;
    logic [15:0] score_rd_rsp_epoch; logic [2:0] score_rd_rsp_group;
    logic [4:0] score_rd_rsp_global_q_head;
    logic [6:0] score_rd_rsp_row, score_rd_rsp_key;
    logic [1:0] score_rd_rsp_slot_id, score_rd_rsp_numeric_mode;
    logic [15:0] score_rd_rsp_bf16;
    logic b_row_valid, b_row_ready; logic [15:0] b_row_epoch;
    logic [2:0] b_row_group; logic [4:0] b_row_global_q_head;
    logic [6:0] b_row_index; logic [1:0] b_row_slot_id, b_row_numeric_mode;
    logic [15:0] b_row_max_bf16;
    logic b_score_valid, b_score_ready; logic [15:0] b_score_epoch;
    logic [2:0] b_score_group; logic [4:0] b_score_global_q_head;
    logic [6:0] b_score_row, b_score_key;
    logic [1:0] b_score_slot_id, b_score_numeric_mode;
    logic [15:0] b_score_bf16; logic b_score_last;
    logic final_release_valid, final_release_ready;
    logic [15:0] final_release_epoch; logic [2:0] final_release_group;
    logic [4:0] final_release_global_q_head; logic [6:0] final_release_row;
    logic [1:0] final_release_slot_id, final_release_numeric_mode;
    logic row_abort_valid, row_abort_ready; logic [15:0] row_abort_epoch;
    logic [2:0] row_abort_group; logic [4:0] row_abort_global_q_head;
    logic [6:0] row_abort_row, row_abort_error_key;
    logic [1:0] row_abort_slot_id, row_abort_numeric_mode;
    logic [2:0] row_abort_error_code;
    logic [5:0] slot_owner;
    logic [63:0] rows_completed, scores_transferred, rows_transferred, aborts, owner_errors;
    logic protocol_error_sticky;

    cats_r4_qk_row_handoff_wrapper #(.SEQ_LEN(8), .LANES(LANES), .SLOTS(3)) dut (.*);
    task automatic tick; @(posedge clk); #1; endtask

    logic [15:0] mem [0:2][0:7];
    logic pending; logic [6:0] pending_key; logic [1:0] pending_slot;
    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin pending <= 0; score_rd_rsp_valid <= 0; end
        else begin
            if (store_wr_valid && store_wr_ready)
                for (i=0;i<LANES;i=i+1)
                    if (store_wr_lane_valid[i])
                        mem[store_wr_slot_id][store_wr_key_base+i] <= store_wr_score_bf16[i*16 +: 16];
            if (score_rd_rsp_valid && score_rd_rsp_ready) score_rd_rsp_valid <= 0;
            if (pending && (!score_rd_rsp_valid || score_rd_rsp_ready)) begin
                score_rd_rsp_valid <= 1; pending <= 0;
                score_rd_rsp_epoch <= score_rd_req_epoch;
                score_rd_rsp_group <= score_rd_req_group;
                score_rd_rsp_global_q_head <= score_rd_req_global_q_head;
                score_rd_rsp_row <= score_rd_req_row;
                score_rd_rsp_slot_id <= pending_slot;
                score_rd_rsp_numeric_mode <= score_rd_req_numeric_mode;
                score_rd_rsp_key <= pending_key;
                score_rd_rsp_bf16 <= mem[pending_slot][pending_key];
            end
            if (score_rd_req_valid && score_rd_req_ready) begin
                pending <= 1; pending_key <= score_rd_req_key;
                pending_slot <= score_rd_req_slot_id;
            end
        end
    end

    task automatic send_block(input [1:0] kb, input [63:0] scores);
        begin
            @(negedge clk); block_key_block=kb; block_score_bf16=scores;
            block_lane_valid=4'b1111; block_valid=1; #1;
            while (!block_ready) tick();
            tick(); @(negedge clk); block_valid=0;
        end
    endtask

    initial begin
        txn_start_valid=0; txn_epoch=16'h5505; txn_numeric_mode=1;
        row_open_valid=0; row_open_epoch=16'h5505; row_open_group=1;
        row_open_global_q_head=6; row_open_row=7; row_open_slot_id=0; row_open_numeric_mode=1;
        block_valid=0; block_epoch=16'h5505; block_group=1;
        block_global_q_head=6; block_row=7; block_slot_id=0; block_numeric_mode=1;
        store_wr_ready=1; score_rd_req_ready=1; score_rd_rsp_valid=0; pending=0;
        b_row_ready=1; b_score_ready=1; row_abort_ready=1;
        final_release_valid=0; final_release_epoch=16'h5505; final_release_group=1;
        final_release_global_q_head=6; final_release_row=7; final_release_slot_id=0;
        final_release_numeric_mode=1;
        repeat(3) tick(); rst_n=1;
        @(negedge clk); txn_start_valid=1; tick(); @(negedge clk); txn_start_valid=0;
        @(negedge clk); row_open_valid=1; #1;
        if(!row_open_ready) $fatal(1,"row reserve failed");
        tick(); @(negedge clk); row_open_valid=0;
        send_block(0,{16'h3f83,16'h3f82,16'h3f81,16'h3f80});
        send_block(1,{16'h3f87,16'h3f86,16'h3f85,16'h3f84});
        while(rows_transferred!=1) tick();
        if(rows_completed!=1 || scores_transferred!=8 || b_row_max_bf16!=16'h3f87 ||
           slot_owner[1:0]!=2 || row_abort_valid)
            $fatal(1,"integrated row/handoff mismatch");
        @(negedge clk); row_open_valid=1; #1;
        if(row_open_ready) $fatal(1,"slot reused while B owns it");
        row_open_valid=0;
        @(negedge clk); final_release_valid=1; #1;
        if(!final_release_ready) $fatal(1,"final release rejected");
        tick(); @(negedge clk); final_release_valid=0; #1;
        if(!row_open_ready || slot_owner[1:0]!=0 || owner_errors!=0 || protocol_error_sticky)
            $fatal(1,"slot not reusable after release");

        // Mode mismatch is accepted at row_open, reserved in owner=A, and
        // then reported as an assembler abort.  Backpressure must preserve
        // both the abort payload and ownership until the external transfer.
        row_abort_ready=0;
        row_open_numeric_mode=0;
        @(negedge clk); row_open_valid=1; #1;
        if(!row_open_ready) $fatal(1,"abort-path row reserve failed");
        tick(); @(negedge clk); row_open_valid=0;
        while(!row_abort_valid) tick();
        if(row_abort_epoch!=16'h5505 || row_abort_group!=1 ||
           row_abort_global_q_head!=6 || row_abort_row!=7 ||
           row_abort_slot_id!=0 || row_abort_numeric_mode!=0 ||
           row_abort_error_code!=3 || slot_owner[1:0]!=1)
            $fatal(1,"stalled abort payload or A ownership mismatch");
        repeat(2) begin
            tick();
            if(!row_abort_valid || row_abort_epoch!=16'h5505 ||
               row_abort_row!=7 || row_abort_slot_id!=0 ||
               row_abort_numeric_mode!=0 || slot_owner[1:0]!=1 || aborts!=0)
                $fatal(1,"abort stall was not stable");
        end
        @(negedge clk); row_abort_ready=1; #1;
        if(!row_abort_valid || slot_owner[1:0]!=1)
            $fatal(1,"abort disappeared before acceptance");
        tick();
        @(negedge clk); row_open_numeric_mode=1; #1;
        if(slot_owner[1:0]!=0 || aborts!=1 || owner_errors!=0 ||
           !row_open_ready || !protocol_error_sticky)
            $fatal(1,"accepted abort did not release and recycle slot");
        $display("PASS: CATS-R4 normal handoff plus stalled abort slot recycle");
        $finish;
    end
endmodule
