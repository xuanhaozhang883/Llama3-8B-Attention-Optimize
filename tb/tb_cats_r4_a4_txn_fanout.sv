`timescale 1ns/1ps
module tb_cats_r4_a4_txn_fanout;
    localparam integer CLUSTERS=2;
    logic clk=0;always #1 clk=~clk;
    logic rst_n=0,clear=0,txn_start_valid,txn_start_ready;
    logic [15:0] txn_epoch,cluster_start_epoch,txn_epoch_locked;
    logic [1:0] txn_numeric_mode,cluster_start_numeric_mode;
    logic [1:0] txn_numeric_mode_locked;
    logic [CLUSTERS-1:0] cluster_start_valid,cluster_start_ready;
    logic [CLUSTERS-1:0] cluster_started;
    logic txn_active,all_clusters_started;
    logic txn_drain_complete;
    logic [CLUSTERS-1:0] cluster_quiescent;
    logic protocol_error_valid,protocol_error_ready;
    logic [3:0] protocol_error_code;
    logic [15:0] protocol_error_epoch;
    logic [1:0] protocol_error_numeric_mode;
    integer errors_seen;

    cats_r4_a4_txn_fanout #(.CLUSTERS(CLUSTERS)) dut(.*);

    task automatic submit(input logic [15:0] epoch,input logic [1:0] mode);
        begin
            while(!txn_start_ready)@(posedge clk);
            @(negedge clk);txn_epoch=epoch;txn_numeric_mode=mode;
            txn_start_valid=1;@(posedge clk);@(negedge clk);txn_start_valid=0;
        end
    endtask

    task automatic expect_error(input logic [3:0] code,
                                input logic [15:0] epoch);
        begin
            while(!protocol_error_valid)@(posedge clk);
            if(protocol_error_code!==code||protocol_error_epoch!==epoch)
                $fatal(1,"protocol error mismatch code=%h/%h epoch=%h/%h",
                       protocol_error_code,code,protocol_error_epoch,epoch);
            errors_seen=errors_seen+1;
            @(negedge clk);protocol_error_ready=1;
            @(posedge clk);@(negedge clk);protocol_error_ready=0;
        end
    endtask

    initial begin
        txn_start_valid=0;txn_epoch=0;txn_numeric_mode=0;
        cluster_start_ready=0;protocol_error_ready=0;errors_seen=0;
        txn_drain_complete=0;cluster_quiescent=0;
        repeat(4)@(posedge clk);rst_n=1;

        submit(16'h4100,2'd1);
        txn_epoch=16'hffff;txn_numeric_mode=0;
        if(!txn_active||cluster_start_valid!==2'b11||
           cluster_start_epoch!=16'h4100||cluster_start_numeric_mode!=1)
            $fatal(1,"transaction was not captured before child delivery");

        // Cluster 1 starts first; cluster 0 remains independently pending.
        cluster_start_ready=2'b10;@(posedge clk);@(negedge clk);
        cluster_start_ready=0;
        if(cluster_start_valid!==2'b01||cluster_started!==2'b10||
           cluster_start_epoch!=16'h4100||cluster_start_numeric_mode!=1)
            $fatal(1,"asynchronous child start tracking mismatch");
        repeat(3) begin
            @(posedge clk);
            if(cluster_start_valid!==2'b01||cluster_start_epoch!=16'h4100||
               cluster_start_numeric_mode!=1)
                $fatal(1,"pending child start changed under backpressure");
        end
        @(negedge clk);cluster_start_ready=2'b01;
        @(posedge clk);@(negedge clk);cluster_start_ready=0;
        if(!all_clusters_started||cluster_started!==2'b11)
            $fatal(1,"all child starts were not accounted");

        // A busy request is reported once even while valid remains asserted.
        txn_epoch=16'h4101;txn_numeric_mode=0;txn_start_valid=1;
        expect_error(4'h2,16'h4101);
        repeat(3) begin
            @(posedge clk);
            if(protocol_error_valid)$fatal(1,"busy request reported repeatedly");
        end
        @(negedge clk);txn_start_valid=0;

        // Completion cannot unlock until every cluster is quiescent.
        txn_drain_complete=1;cluster_quiescent=2'b01;
        @(posedge clk);@(negedge clk);
        if(!txn_active)$fatal(1,"transaction unlocked before global quiescence");
        cluster_quiescent=2'b11;@(posedge clk);@(negedge clk);
        txn_drain_complete=0;cluster_quiescent=0;
        if(txn_active||!txn_start_ready)
            $fatal(1,"normal global drain did not unlock transaction");
        submit(16'h4100,2'd1);expect_error(4'h3,16'h4100);
        if(txn_active)$fatal(1,"same epoch restart became active");
        submit(16'h4102,2'd2);expect_error(4'h1,16'h4102);
        if(txn_active)$fatal(1,"illegal numeric mode became active");

        submit(16'h4102,2'd0);
        if(!txn_active||txn_epoch_locked!=16'h4102||
           txn_numeric_mode_locked!=0||errors_seen!=3)
            $fatal(1,"new epoch did not start cleanly");
        clear=1;@(posedge clk);@(negedge clk);clear=0;
        if(txn_active||cluster_start_valid||!txn_start_ready)
            $fatal(1,"coordinated clear did not return fanout idle");
        $display("PASS A4 TXN FANOUT clusters=2 async_start=1 stall_stable=3 busy_once=1 drain_gate=1 epoch_reuse=1 invalid_mode=1 clear=1");
        $finish;
    end
endmodule
