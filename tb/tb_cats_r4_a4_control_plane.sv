`timescale 1ns/1ps
module tb_cats_r4_a4_control_plane;
    localparam integer CLUSTERS=2;
    logic clk=0;always #1 clk=~clk;
    logic rst_n=0,clear=0,counter_clear=0;

    logic txn_start_valid,txn_start_ready;
    logic [15:0] txn_epoch;
    logic [1:0] txn_numeric_mode;
    logic [1:0] cluster_start_valid,cluster_start_ready,cluster_started;
    logic [15:0] cluster_start_epoch,txn_epoch_locked;
    logic [1:0] cluster_start_numeric_mode,txn_numeric_mode_locked;
    logic txn_active,all_clusters_started,txn_drain_complete;
    logic txn_error_valid,txn_error_ready;
    logic [3:0] txn_error_code;
    logic [15:0] txn_error_epoch;
    logic [1:0] txn_error_mode;

    logic [1:0] group_cmd_valid,group_cmd_ready,group_cmd_kv_buffer;
    logic [15:0] group_cmd_epoch [0:1];
    logic [2:0] group_cmd_group [0:1];
    logic [2:0] group_cmd_local_index [0:1];
    logic [1:0] group_cmd_mode [0:1];
    logic [1:0] job_valid,job_ready,group_kv_buffer;
    logic [15:0] job_epoch [0:1];
    logic [2:0] job_group [0:1];
    logic [4:0] job_head [0:1];
    logic [2:0] job_window [0:1];
    logic [1:0] retire_valid,retire_ready;
    logic [15:0] retire_epoch [0:1];
    logic [2:0] retire_group [0:1];
    logic [4:0] retire_head [0:1];
    logic [2:0] retire_window [0:1];
    logic [63:0] context_words [0:1];
    logic [63:0] release_count [0:1];
    logic [5:0] slot_owner [0:1];
    logic [1:0] cluster_quiescent,cluster_error_seen,group_abort;
    logic [1:0] group_done_valid,group_done_ready;
    logic [15:0] group_done_epoch [0:1];
    logic [2:0] group_done_group [0:1];
    logic [2:0] group_done_local_index [0:1];
    logic [1:0] group_done_mode [0:1];
    logic [1:0] group_done_aborted,group_done_error;
    logic [1:0] adapter_error_valid,adapter_error_ready;
    logic [3:0] adapter_error_code [0:1];
    logic [15:0] adapter_error_epoch [0:1];
    logic [2:0] adapter_error_group [0:1];
    logic [2:0] adapter_error_local_index [0:1];
    logic [1:0] adapter_busy;
    logic [63:0] groups_accepted [0:1];
    logic [63:0] groups_completed [0:1];
    logic [63:0] groups_aborted [0:1];
    logic [63:0] jobs_accepted [0:1];
    logic [63:0] retires_accepted [0:1];
    integer issued [0:1];
    integer retired [0:1];
    integer cycle_i,cluster_i;
    logic [25:0] held_done;

    cats_r4_a4_txn_fanout #(.CLUSTERS(CLUSTERS)) u_txn (
        .clk,.rst_n,.clear,.txn_start_valid,.txn_start_ready,.txn_epoch,
        .txn_numeric_mode,.cluster_start_valid,.cluster_start_ready,
        .cluster_start_epoch,.cluster_start_numeric_mode,.txn_active,
        .txn_epoch_locked,.txn_numeric_mode_locked,.cluster_started,
        .all_clusters_started,.txn_drain_complete,.cluster_quiescent,
        .protocol_error_valid(txn_error_valid),
        .protocol_error_ready(txn_error_ready),
        .protocol_error_code(txn_error_code),
        .protocol_error_epoch(txn_error_epoch),
        .protocol_error_numeric_mode(txn_error_mode)
    );

    generate
        for(genvar g=0;g<CLUSTERS;g=g+1) begin: GEN_ADAPTER
            cats_r4_a4_group_job_adapter #(
                .CLUSTERS(CLUSTERS),.CLUSTER_ID(g)
            ) u_adapter (
                .clk,.rst_n,.clear,.counter_clear,.txn_active,
                .txn_epoch(txn_epoch_locked),
                .txn_numeric_mode(txn_numeric_mode_locked),
                .group_cmd_valid(group_cmd_valid[g]),
                .group_cmd_ready(group_cmd_ready[g]),
                .group_cmd_epoch(group_cmd_epoch[g]),
                .group_cmd_group(group_cmd_group[g]),
                .group_cmd_local_index(group_cmd_local_index[g]),
                .group_cmd_numeric_mode(group_cmd_mode[g]),
                .group_cmd_kv_buffer(group_cmd_kv_buffer[g]),
                .job_valid(job_valid[g]),.job_ready(job_ready[g]),
                .job_epoch(job_epoch[g]),.job_group(job_group[g]),
                .job_global_q_head(job_head[g]),
                .job_row_window(job_window[g]),
                .group_kv_buffer(group_kv_buffer[g]),
                .retire_valid(retire_valid[g]),.retire_ready(retire_ready[g]),
                .retire_epoch(retire_epoch[g]),.retire_group(retire_group[g]),
                .retire_head(retire_head[g]),.retire_window(retire_window[g]),
                .context_words(context_words[g]),
                .final_release_count(release_count[g]),
                .slot_owner(slot_owner[g]),
                .cluster_quiescent(cluster_quiescent[g]),
                .cluster_error_seen(cluster_error_seen[g]),
                .group_abort(group_abort[g]),
                .group_done_valid(group_done_valid[g]),
                .group_done_ready(group_done_ready[g]),
                .group_done_epoch(group_done_epoch[g]),
                .group_done_group(group_done_group[g]),
                .group_done_local_index(group_done_local_index[g]),
                .group_done_numeric_mode(group_done_mode[g]),
                .group_done_aborted(group_done_aborted[g]),
                .group_done_error(group_done_error[g]),
                .protocol_error_valid(adapter_error_valid[g]),
                .protocol_error_ready(adapter_error_ready[g]),
                .protocol_error_code(adapter_error_code[g]),
                .protocol_error_epoch(adapter_error_epoch[g]),
                .protocol_error_group(adapter_error_group[g]),
                .protocol_error_local_index(adapter_error_local_index[g]),
                .busy(adapter_busy[g]),.groups_accepted(groups_accepted[g]),
                .groups_completed(groups_completed[g]),
                .groups_aborted(groups_aborted[g]),
                .jobs_accepted(jobs_accepted[g]),
                .retires_accepted(retires_accepted[g])
            );
        end
    endgenerate

    task automatic submit_txn(input logic [15:0] epoch,input logic [1:0] mode);
        begin
            while(!txn_start_ready)@(posedge clk);
            @(negedge clk);txn_epoch=epoch;txn_numeric_mode=mode;
            txn_start_valid=1;@(posedge clk);@(negedge clk);txn_start_valid=0;
        end
    endtask

    initial begin
        txn_start_valid=0;txn_epoch=0;txn_numeric_mode=0;
        cluster_start_ready=0;txn_drain_complete=0;txn_error_ready=1;
        group_cmd_valid=0;group_cmd_kv_buffer=2'b10;job_ready=0;
        retire_valid=0;retire_ready=2'b11;cluster_quiescent=0;
        cluster_error_seen=0;group_abort=0;group_done_ready=0;
        adapter_error_ready=0;issued[0]=0;issued[1]=0;
        retired[0]=0;retired[1]=0;
        for(cluster_i=0;cluster_i<2;cluster_i=cluster_i+1) begin
            group_cmd_epoch[cluster_i]=16'h5200;
            group_cmd_group[cluster_i]=cluster_i;
            group_cmd_local_index[cluster_i]=0;
            group_cmd_mode[cluster_i]=1;
            context_words[cluster_i]=0;release_count[cluster_i]=0;
            slot_owner[cluster_i]=0;retire_epoch[cluster_i]=16'h5200;
            retire_group[cluster_i]=cluster_i;retire_head[cluster_i]=0;
            retire_window[cluster_i]=0;
        end
        repeat(4)@(posedge clk);rst_n=1;

        submit_txn(16'h5200,2'd1);
        @(negedge clk);cluster_start_ready=2'b01;@(posedge clk);
        @(negedge clk);cluster_start_ready=2'b10;@(posedge clk);
        @(negedge clk);cluster_start_ready=0;
        if(!all_clusters_started||cluster_started!=2'b11)
            $fatal(1,"control-plane child starts did not complete independently");

        group_cmd_valid=2'b11;@(posedge clk);@(negedge clk);group_cmd_valid=0;
        if(groups_accepted[0]!=1||groups_accepted[1]!=1||
           !adapter_busy[0]||!adapter_busy[1])
            $fatal(1,"parallel group commands were not accepted");

        cycle_i=0;
        while(issued[0]<32||issued[1]<32) begin
            job_ready[0]=(cycle_i%3)!=0;
            job_ready[1]=(cycle_i%2)==0;
            for(cluster_i=0;cluster_i<2;cluster_i=cluster_i+1)
                if(job_valid[cluster_i]&&job_ready[cluster_i]) begin
                    if(job_epoch[cluster_i]!=16'h5200||
                       job_group[cluster_i]!=cluster_i||
                       job_head[cluster_i]!=(4*cluster_i+(issued[cluster_i]>>3))||
                       job_window[cluster_i]!=(issued[cluster_i]&7)||
                       group_kv_buffer[cluster_i]!=group_cmd_kv_buffer[cluster_i])
                        $fatal(1,"cluster %0d job token crossed at index %0d",
                               cluster_i,issued[cluster_i]);
                end
            @(posedge clk);
            for(cluster_i=0;cluster_i<2;cluster_i=cluster_i+1)
                if(job_valid[cluster_i]&&job_ready[cluster_i])
                    issued[cluster_i]=issued[cluster_i]+1;
            @(negedge clk);cycle_i=cycle_i+1;
            if(cycle_i>200)$fatal(1,"parallel jobs made no progress");
        end
        job_ready=0;

        while(retired[0]<32||retired[1]<32) begin
            for(cluster_i=0;cluster_i<2;cluster_i=cluster_i+1) begin
                retire_valid[cluster_i]=retired[cluster_i]<32;
                retire_epoch[cluster_i]=16'h5200;
                retire_group[cluster_i]=cluster_i;
                retire_head[cluster_i]=4*cluster_i+(retired[cluster_i]>>3);
                retire_window[cluster_i]=retired[cluster_i]&7;
            end
            @(posedge clk);
            for(cluster_i=0;cluster_i<2;cluster_i=cluster_i+1)
                if(retire_valid[cluster_i])retired[cluster_i]=retired[cluster_i]+1;
            @(negedge clk);
        end
        retire_valid=0;

        // Cluster 0 completes while cluster 1 still lacks its service counters.
        context_words[0]=65536;release_count[0]=512;
        cluster_quiescent=2'b11;
        @(posedge clk);@(negedge clk);
        if(!group_done_valid[0]||group_done_valid[1])
            $fatal(1,"cluster-local completion was globally coupled");
        held_done={group_done_epoch[0],group_done_group[0],
                   group_done_local_index[0],group_done_mode[0],
                   group_done_aborted[0],group_done_error[0]};
        repeat(3) begin
            @(posedge clk);
            if(!group_done_valid[0]||
               {group_done_epoch[0],group_done_group[0],
                group_done_local_index[0],group_done_mode[0],
                group_done_aborted[0],group_done_error[0]}!==held_done)
                $fatal(1,"cluster 0 completion changed under backpressure");
        end
        @(negedge clk);context_words[1]=65536;release_count[1]=512;
        @(posedge clk);@(negedge clk);
        if(!group_done_valid[1])$fatal(1,"cluster 1 did not complete independently");
        group_done_ready=2'b11;@(posedge clk);@(negedge clk);group_done_ready=0;
        if(adapter_busy||groups_completed[0]!=1||groups_completed[1]!=1||
           jobs_accepted[0]!=32||jobs_accepted[1]!=32||
           retires_accepted[0]!=32||retires_accepted[1]!=32)
            $fatal(1,"dual-cluster conservation mismatch");

        txn_drain_complete=1;@(posedge clk);@(negedge clk);txn_drain_complete=0;
        if(txn_active)$fatal(1,"completed control plane did not drain transaction");

        // Wrongly route group 1 to cluster 0; cluster 1 must remain untouched.
        submit_txn(16'h5201,2'd1);
        cluster_start_ready=2'b11;@(posedge clk);@(negedge clk);
        cluster_start_ready=0;
        group_cmd_epoch[0]=16'h5201;group_cmd_group[0]=1;
        group_cmd_local_index[0]=0;group_cmd_valid=2'b01;
        @(posedge clk);@(negedge clk);group_cmd_valid=0;
        if(!adapter_error_valid[0]||adapter_error_code[0]!=4||
           adapter_error_valid[1]||groups_accepted[1]!=1)
            $fatal(1,"wrong-route error was not isolated to cluster 0");
        adapter_error_ready=2'b01;@(posedge clk);@(negedge clk);
        adapter_error_ready=0;clear=1;@(posedge clk);@(negedge clk);clear=0;

        // A root fault wins over a simultaneous abort.  A peer that only sees
        // the global abort reports aborted, never both terminal flags.
        submit_txn(16'h5202,2'd1);
        cluster_start_ready=2'b11;@(posedge clk);@(negedge clk);
        cluster_start_ready=0;
        for(cluster_i=0;cluster_i<2;cluster_i=cluster_i+1) begin
            group_cmd_epoch[cluster_i]=16'h5202;
            group_cmd_group[cluster_i]=cluster_i;
            group_cmd_local_index[cluster_i]=0;
        end
        group_cmd_valid=2'b11;@(posedge clk);@(negedge clk);group_cmd_valid=0;
        if(!adapter_busy[0]||!adapter_busy[1])
            $fatal(1,"terminal-status commands were not accepted");
        cluster_error_seen=2'b01;group_abort=2'b11;
        @(posedge clk);@(negedge clk);
        cluster_error_seen=0;group_abort=0;
        repeat(2)@(posedge clk);
        @(negedge clk);
        if(group_done_valid!==2'b11||
           !group_done_error[0]||group_done_aborted[0]||
           group_done_error[1]||!group_done_aborted[1])
            $fatal(1,"root-error/peer-abort terminal flags are not exclusive");
        group_done_ready=2'b11;@(posedge clk);@(negedge clk);group_done_ready=0;
        if(adapter_busy)
            $fatal(1,"terminal-status adapters did not retire");

        $display("PASS A4 CONTROL PLANE clusters=2 groups=2 jobs=64 retires=64 async_completion=1 done_stall=3 wrong_route_isolated=1 terminal_exclusive=1");
        $finish;
    end
endmodule
