`timescale 1ns/1ps

module tb_cats_r4_a4_n2_wrapper;
    logic clk=0; always #1 clk=~clk;
    logic rst_n=0,clear=0,counter_clear=0;
    logic txn_start_valid,txn_start_ready;
    logic [15:0] txn_epoch;
    logic [1:0] txn_numeric_mode;
    logic txn_drain_complete,abort_request,txn_active;
    logic [15:0] txn_epoch_locked;
    logic [1:0] txn_numeric_mode_locked,cluster_started;
    logic all_clusters_started,global_halt;

    logic [1:0] q_slab_need_valid,q_slab_need_ready;
    logic [1:0][15:0] q_slab_need_epoch;
    logic [1:0][2:0] q_slab_need_group;
    logic [1:0][4:0] q_slab_need_global_q_head;
    logic [1:0][2:0] q_slab_need_row_window;
    logic [1:0] q_slab_ready_valid,q_slab_ready_ready;
    logic [1:0][15:0] q_slab_ready_epoch;
    logic [1:0][2:0] q_slab_ready_group;
    logic [1:0][4:0] q_slab_ready_global_q_head;
    logic [1:0][2:0] q_slab_ready_row_window;
    logic [1:0] q_slab_ready_buffer;
    logic [1:0] q_slab_retire_valid;
    logic [1:0] q_req_valid,q_req_ready,k_req_valid,k_req_ready;
    logic [1:0][3:0] q_req_context_tag,k_req_context_tag;
    logic [1:0][6:0] q_req_d,k_req_d;
    logic [1:0][1:0] k_req_key_block;

    logic [1:0] group_cmd_valid,group_cmd_ready;
    logic [1:0][15:0] group_cmd_epoch;
    logic [1:0][2:0] group_cmd_group,group_cmd_local_index;
    logic [1:0][1:0] group_cmd_numeric_mode;
    logic [1:0] group_cmd_kv_buffer,group_kv_buffer;
    logic [1:0] cluster_quiescent,cluster_group_done_valid;
    logic [1:0][15:0] cluster_group_done_epoch;
    logic [1:0][2:0] cluster_group_done_group;
    logic [1:0][2:0] cluster_group_done_local_index;
    logic [1:0][1:0] cluster_group_done_numeric_mode;
    logic [1:0] cluster_group_done_aborted,cluster_group_done_error;
    logic [1:0] cluster_adapter_busy,cluster_txn_active;
    logic [1:0][63:0] cluster_groups_accepted,cluster_groups_completed;
    logic [1:0][63:0] cluster_groups_aborted,cluster_jobs_accepted;
    logic [1:0][63:0] cluster_retires_accepted,cluster_context_words;
    logic [1:0][63:0] cluster_final_releases;

    logic done_event_valid,error_event_valid,control_event_valid,txn_error_valid;
    logic done_event_source,error_event_source,control_event_source;
    logic [25:0] done_event_payload,control_event_payload;
    logic [47:0] error_event_payload;
    logic [3:0] txn_error_code;
    logic [15:0] txn_error_epoch;
    logic [1:0] txn_error_numeric_mode;

    logic telemetry_snapshot_req_valid,telemetry_snapshot_req_ready;
    logic telemetry_snapshot_valid,telemetry_snapshot_ready;
    logic telemetry_first_issue_valid,telemetry_last_commit_valid;
    logic [63:0] telemetry_first_issue_cycle,telemetry_last_commit_cycle;
    logic [63:0] telemetry_groups_accepted,telemetry_groups_completed;
    logic [63:0] telemetry_groups_aborted,telemetry_group_wait_cycles;
    logic [63:0] telemetry_output_stall_cycles;
    logic [63:0] telemetry_service_stall_cycles,telemetry_active_cycles;
    logic telemetry_all_done;
    logic control_event_seen,control_event_seen_source;
    logic txn_error_seen;
    logic [3:0] txn_error_seen_code;

    integer q_accept [0:1];
    integer k_accept [0:1];
    integer watchdog,c;

    cats_r4_a4_compute_array_n2 #(.SCALE_FP32(32'h00000000)) dut (
        .clk,.rst_n,.clear,.counter_clear,.txn_start_valid,.txn_start_ready,
        .txn_epoch,.txn_numeric_mode,.txn_drain_complete,.abort_request,
        .txn_active,.txn_epoch_locked,.txn_numeric_mode_locked,.cluster_started,
        .all_clusters_started,.global_halt,
        .q_slab_need_valid,.q_slab_need_ready,.q_slab_need_epoch,
        .q_slab_need_group,.q_slab_need_global_q_head,.q_slab_need_row_window,
        .q_slab_ready_valid,.q_slab_ready_ready,.q_slab_ready_epoch,
        .q_slab_ready_group,.q_slab_ready_global_q_head,.q_slab_ready_row_window,
        .q_slab_ready_buffer,.q_slab_retire_valid,
        .q_slab_retire_ready(2'b11),.q_slab_retire_epoch(),
        .q_slab_retire_group(),.q_slab_retire_global_q_head(),
        .q_slab_retire_row_window(),.q_slab_retire_buffer(),
        .q_req_valid,.q_req_ready,.q_req_context_tag,.q_req_d,
        .q_rsp_valid(2'b00),.q_rsp_context_tag(8'b0),.q_rsp_bf16(32'b0),
        .k_req_valid,.k_req_ready,.k_req_context_tag,.k_req_key_block,.k_req_d,
        .k_rsp_valid(2'b00),.k_rsp_context_tag(8'b0),.k_rsp_vec(1024'b0),
        .weight_wr_valid(),.weight_wr_ready(2'b11),.weight_wr_epoch(),
        .weight_wr_group(),.weight_wr_global_q_head(),.weight_wr_row(),
        .weight_wr_slot_id(),.weight_wr_numeric_mode(),.weight_wr_key(),
        .weight_wr_mask(),.weight_wr_data(),.weight_wr_last(),
        .row_commit_valid(),.row_commit_ready(2'b11),.row_commit_epoch(),
        .row_commit_group(),.row_commit_global_q_head(),.row_commit_row(),
        .row_commit_slot_id(),.row_commit_numeric_mode(),
        .row_commit_sum_fp32(),.row_commit_inv_sum_fp32(),
        .pv_row_valid(2'b00),.pv_row_ready(),.pv_row_epoch(32'b0),
        .pv_row_group(6'b0),.pv_row_global_q_head(10'b0),.pv_row_row(14'b0),
        .pv_row_slot_id(4'b0),.pv_row_numeric_mode(4'b0),
        .pv_row_sum_fp32(64'b0),.pv_row_inv_sum_fp32(64'b0),
        .weight_rd_req_valid(),.weight_rd_req_ready(2'b11),
        .weight_rd_req_epoch(),.weight_rd_req_group(),
        .weight_rd_req_global_q_head(),.weight_rd_req_row(),
        .weight_rd_req_slot_id(),.weight_rd_req_numeric_mode(),
        .weight_rd_req_key(),.weight_rd_rsp_valid(2'b00),
        .weight_rd_rsp_epoch(32'b0),.weight_rd_rsp_group(6'b0),
        .weight_rd_rsp_global_q_head(10'b0),.weight_rd_rsp_row(14'b0),
        .weight_rd_rsp_slot_id(4'b0),.weight_rd_rsp_numeric_mode(4'b0),
        .weight_rd_rsp_key(14'b0),.weight_rd_rsp_mask(2'b0),
        .weight_rd_rsp_data(64'b0),
        .v_req_valid(),.v_req_ready(2'b11),.v_req_context_tag(),
        .v_req_key(),.v_req_feature_block(),.v_rsp_valid(2'b00),
        .v_rsp_context_tag(8'b0),.v_rsp_vec_bf16(1024'b0),
        .out_valid(),.out_ready(2'b11),.out_epoch(),.out_seq(),
        .out_global_q_head(),.out_row(),.out_feature_block(),
        .out_data_bf16(),.out_row_last(),.out_tensor_last(),
        .weight_release_valid(),.weight_release_ready(2'b11),
        .weight_release_epoch(),.weight_release_group(),
        .weight_release_global_q_head(),.weight_release_row(),
        .weight_release_slot_id(),.weight_release_numeric_mode(),
        .group_cmd_valid,.group_cmd_ready,.group_cmd_epoch,.group_cmd_group,
        .group_cmd_local_index,.group_cmd_numeric_mode,.group_cmd_kv_buffer,
        .group_kv_buffer,.cluster_quiescent,.cluster_group_done_valid,
        .cluster_group_done_epoch,.cluster_group_done_group,
        .cluster_group_done_local_index,.cluster_group_done_numeric_mode,
        .cluster_group_done_aborted,.cluster_group_done_error,
        .cluster_adapter_busy,.cluster_txn_active,.cluster_groups_accepted,
        .cluster_groups_completed,.cluster_groups_aborted,
        .cluster_jobs_accepted,.cluster_retires_accepted,
        .cluster_context_words,.cluster_final_releases,
        .done_event_valid,.done_event_ready(1'b1),.done_event_source,
        .done_event_payload,.error_event_valid,.error_event_ready(1'b1),
        .error_event_source,.error_event_payload,.control_event_valid,
        .control_event_ready(1'b1),.control_event_source,
        .control_event_payload,.txn_error_valid,.txn_error_ready(1'b1),
        .txn_error_code,.txn_error_epoch,.txn_error_numeric_mode,
        .telemetry_snapshot_req_valid,.telemetry_snapshot_req_ready,
        .telemetry_expected_groups(4'd8),.telemetry_snapshot_valid,
        .telemetry_snapshot_ready,.telemetry_first_issue_valid,
        .telemetry_first_issue_cycle,.telemetry_last_commit_valid,
        .telemetry_last_commit_cycle,.telemetry_groups_accepted,
        .telemetry_groups_completed,.telemetry_groups_aborted,
        .telemetry_group_wait_cycles,.telemetry_output_stall_cycles,
        .telemetry_service_stall_cycles,.telemetry_active_cycles,
        .telemetry_all_done
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n || clear) begin
            q_slab_ready_valid <= '0;
            q_slab_ready_epoch <= '0;
            q_slab_ready_group <= '0;
            q_slab_ready_global_q_head <= '0;
            q_slab_ready_row_window <= '0;
            q_slab_ready_buffer <= '0;
            q_accept[0] <= 0;q_accept[1] <= 0;
            k_accept[0] <= 0;k_accept[1] <= 0;
            control_event_seen <= 1'b0;
            control_event_seen_source <= 1'b0;
            txn_error_seen <= 1'b0;
            txn_error_seen_code <= '0;
        end else begin
            if(control_event_valid) begin
                control_event_seen <= 1'b1;
                control_event_seen_source <= control_event_source;
            end
            if(txn_error_valid) begin
                txn_error_seen <= 1'b1;
                txn_error_seen_code <= txn_error_code;
            end
            for(c=0;c<2;c=c+1) begin
                if(q_slab_ready_valid[c] && q_slab_ready_ready[c])
                    q_slab_ready_valid[c] <= 1'b0;
                if(q_slab_need_valid[c] && q_slab_need_ready[c] &&
                   !q_slab_ready_valid[c]) begin
                    q_slab_ready_valid[c] <= 1'b1;
                    q_slab_ready_epoch[c] <= q_slab_need_epoch[c];
                    q_slab_ready_group[c] <= q_slab_need_group[c];
                    q_slab_ready_global_q_head[c] <=
                        q_slab_need_global_q_head[c];
                    q_slab_ready_row_window[c] <= q_slab_need_row_window[c];
                    q_slab_ready_buffer[c] <= 1'b0;
                end
                if(q_req_valid[c] && q_req_ready[c])
                    q_accept[c] <= q_accept[c] + 1;
                if(k_req_valid[c] && k_req_ready[c])
                    k_accept[c] <= k_accept[c] + 1;
            end
        end
    end

    initial begin
        txn_start_valid=0;txn_epoch=16'h6100;txn_numeric_mode=0;
        txn_drain_complete=0;abort_request=0;q_slab_need_ready=2'b11;
        q_req_ready=2'b10;k_req_ready=2'b10;group_cmd_valid=0;
        group_cmd_epoch[0]=16'h6100;group_cmd_epoch[1]=16'h6100;
        group_cmd_group[0]=0;group_cmd_group[1]=1;
        group_cmd_local_index[0]=0;group_cmd_local_index[1]=0;
        group_cmd_numeric_mode[0]=0;group_cmd_numeric_mode[1]=0;
        group_cmd_kv_buffer=2'b10;
        telemetry_snapshot_req_valid=0;telemetry_snapshot_ready=0;

        repeat(5)@(posedge clk);rst_n=1;@(negedge clk);
        txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        watchdog=0;
        while(!all_clusters_started && watchdog<20) begin
            @(posedge clk);watchdog=watchdog+1;
        end
        if(!all_clusters_started || cluster_started!==2'b11 ||
           cluster_txn_active!==2'b11 || txn_epoch_locked!==16'h6100)
            $fatal(1,"N2 transaction fanout did not start both real clusters");

        @(negedge clk);group_cmd_valid=2'b11;
        watchdog=0;
        while((group_cmd_valid&group_cmd_ready)!=group_cmd_valid && watchdog<20) begin
            @(posedge clk);watchdog=watchdog+1;
        end
        @(posedge clk);@(negedge clk);group_cmd_valid=0;
        if(cluster_groups_accepted[0]!=1||cluster_groups_accepted[1]!=1||
           !cluster_adapter_busy[0]||!cluster_adapter_busy[1])
            $fatal(1,"N2 static group commands were not accepted");

        watchdog=0;
        while((q_accept[1]==0 || k_accept[1]==0 ||
               !q_req_valid[0] || !k_req_valid[0]) && watchdog<500) begin
            @(posedge clk);watchdog=watchdog+1;
        end
        if(watchdog==500 || q_accept[0]!=0 || k_accept[0]!=0 ||
           q_accept[1]==0 || k_accept[1]==0)
            $fatal(1,"peer service stall did not isolate real cluster progress");

        @(negedge clk);telemetry_snapshot_req_valid=1;
        @(posedge clk);@(negedge clk);telemetry_snapshot_req_valid=0;
        watchdog=0;
        while(!telemetry_snapshot_valid && watchdog<10) begin
            @(posedge clk);watchdog=watchdog+1;
        end
        if(!telemetry_snapshot_valid||telemetry_groups_accepted!=2||
           telemetry_groups_completed!=0||telemetry_all_done||
           telemetry_active_cycles==0||telemetry_service_stall_cycles==0)
            $fatal(1,"N2 telemetry was not connected to live cluster activity");
        telemetry_snapshot_ready=1;@(posedge clk);@(negedge clk);
        telemetry_snapshot_ready=0;

        abort_request=1;@(posedge clk);@(negedge clk);abort_request=0;
        @(posedge clk);@(negedge clk);
        if(!global_halt || group_cmd_ready!=0)
            $fatal(1,"global halt did not block new group commands");

        clear=1;@(posedge clk);@(negedge clk);clear=0;
        @(posedge clk);@(negedge clk);
        if(global_halt||txn_active||cluster_txn_active!=0)
            $fatal(1,"coordinated clear did not reset N2 transaction state");

        // A wrong-owner command must traverse the real control-event join and
        // stop both clusters, even though the root is cluster 0 only.
        txn_epoch=16'h6101;
        txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        wait(all_clusters_started);
        @(negedge clk);
        group_cmd_epoch[0]=16'h6101;
        group_cmd_group[0]=3'd1;
        group_cmd_local_index[0]=0;
        group_cmd_numeric_mode[0]=0;
        group_cmd_valid=2'b01;
        do @(posedge clk); while(!group_cmd_ready[0]);
        @(negedge clk);group_cmd_valid=0;
        watchdog=0;
        while((!control_event_seen || !global_halt) && watchdog<20) begin
            @(posedge clk);watchdog=watchdog+1;
        end
        if(!control_event_seen || control_event_seen_source!=0 ||
           !global_halt || group_cmd_ready!=0)
            $fatal(1,"joined control root error did not globally halt N2");

        clear=1;@(posedge clk);@(negedge clk);clear=0;
        @(posedge clk);@(negedge clk);
        if(global_halt||txn_active||cluster_txn_active!=0)
            $fatal(1,"clear after root error did not recover N2");

        // The fanout's exact +1 rule is part of the N2 top, not only its unit.
        txn_epoch=16'h6103;
        txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        repeat(3)@(posedge clk);@(negedge clk);
        if(!txn_error_seen || txn_error_seen_code!=4'h3 || !global_halt ||
           txn_active || cluster_started!=0)
            $fatal(1,"N2 skipped-epoch error did not fail closed");

        $display("PASS A4 N2 WRAPPER real_clusters=2 static_groups=0/1 peer_stall=1 telemetry_live=1 control_error_halt=1 txn_error_halt=1 clear=1");
        $finish;
    end
endmodule
