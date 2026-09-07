`timescale 1ns/1ps
module tb_cats_r4_slot_bank;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, clear=0;
    logic [31:0] owner_release='0;
    logic [1:0] wr_valid='0, wr_ready;
    logic [1:0][1:0] wr_owner='0, wr_slot='0;
    logic [1:0][4:0] wr_bank='0; logic [1:0][3:0] wr_row='0;
    logic [1:0][15:0] wr_data='0;
    logic [1:0] rd_valid='0, rd_ready, rd_rsp_valid, rd_rsp_ready='0;
    logic [1:0][1:0] rd_owner='0, rd_slot='0;
    logic [1:0][4:0] rd_bank='0; logic [1:0][3:0] rd_row='0;
    logic [1:0][15:0] rd_rsp_data;
    logic acc_wr_valid=0,acc_wr_ready; logic [1:0] acc_wr_owner=0; logic [4:0] acc_wr_bank=0; logic [3:0] acc_wr_row=0; logic [31:0] acc_wr_data=0;
    logic acc_rd_valid=0,acc_rd_ready; logic [1:0] acc_rd_owner=0; logic [4:0] acc_rd_bank=0; logic [3:0] acc_rd_row=0; logic acc_rsp_valid,acc_rsp_ready=0; logic [31:0] acc_rsp_data;
    logic collision_seen,protocol_error;
    cats_r4_slot_bank dut(.*);
    task tick; @(posedge clk); #1; endtask
    initial begin
        rd_rsp_ready='1; acc_rsp_ready=1;
        tick; rst_n=1;
        // owner 1 writes A[bank3,row2], then reads it back.
        wr_valid[0]=1; wr_owner[0]=1; wr_slot[0]=0; wr_bank[0]=3; wr_row[0]=2; wr_data[0]=16'h1234;
        #1 if (!wr_ready[0]) $fatal(1,"initial write backpressured"); tick; wr_valid='0;
        rd_valid[0]=1; rd_owner[0]=1; rd_slot[0]=0; rd_bank[0]=3; rd_row[0]=2;
        tick; rd_valid='0; if (!rd_rsp_valid[0] || rd_rsp_data[0]!==16'h1234) $fatal(1,"slot readback failed"); tick;
        // A stalled response must block a later read on the same response
        // port and must keep both valid and data stable until transfer.
        wr_valid[0]=1; wr_owner[0]=1; wr_slot[0]=0; wr_bank[0]=3; wr_row[0]=3; wr_data[0]=16'h5678;
        tick; wr_valid='0;
        rd_rsp_ready[0]=0; rd_valid[0]=1; rd_owner[0]=1; rd_slot[0]=0; rd_bank[0]=3; rd_row[0]=3;
        #1 if (!rd_ready[0]) $fatal(1,"backpressure setup read not accepted"); tick; rd_valid='0;
        if (!rd_rsp_valid[0] || rd_rsp_data[0]!==16'h5678) $fatal(1,"backpressure setup response missing");
        rd_valid[0]=1; rd_row[0]=2; #1;
        if (rd_ready[0]) $fatal(1,"read accepted over stalled response");
        tick;
        if (!rd_rsp_valid[0] || rd_rsp_data[0]!==16'h5678) $fatal(1,"stalled response was overwritten");
        rd_valid='0; rd_rsp_ready[0]=1; tick;
        if (rd_rsp_valid[0]) $fatal(1,"stalled response did not transfer");
        // Different owners cannot steal a held bank until release.
        wr_valid[1]=1; wr_owner[1]=2; wr_slot[1]=1; wr_bank[1]=3; wr_row[1]=0; wr_data[1]=16'habcd;
        if (wr_ready[1]) $fatal(1,"owner isolation failed"); tick; wr_valid='0;
        owner_release[3]=1; tick; owner_release='0;
        wr_valid[1]=1; #1 if (!wr_ready[1]) $fatal(1,"owner release did not unblock"); tick; wr_valid='0;
        // Two writes to one bank: port 0 wins, collision is sticky.
        wr_valid='1; wr_owner[0]=2; wr_owner[1]=2; wr_bank[0]=7; wr_bank[1]=7; wr_slot='0; wr_row='0; wr_data[0]=16'h55aa; wr_data[1]=16'h66bb;
        #1 if (wr_ready[1]) $fatal(1,"collision arbiter failed"); tick; wr_valid='0; if (!collision_seen) $fatal(1,"collision flag missing");
        // Accumulator independent 1R1W path.
        acc_wr_valid=1; acc_wr_owner=1; acc_wr_bank=9; acc_wr_row=4; acc_wr_data=32'h3f800000; tick; acc_wr_valid=0;
        acc_rd_valid=1; acc_rd_owner=1; acc_rd_bank=9; acc_rd_row=4; tick; acc_rd_valid=0; if (!acc_rsp_valid || acc_rsp_data!==32'h3f800000) $fatal(1,"acc readback failed");
        if (protocol_error) $fatal(1,"unexpected protocol error");
        $display("PASS cats_r4_slot_bank collision/owner/backpressure"); $finish;
    end
endmodule
