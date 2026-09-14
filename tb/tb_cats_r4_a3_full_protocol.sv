`timescale 1ns/1ps

module tb_cats_r4_a3_full_protocol #(
    parameter integer MODE=0,
    parameter logic [31:0] SEED=32'd3019898881,
    parameter integer SMOKE_ONLY=0,
    parameter integer JOB_COUNT=256
);
    localparam logic [15:0] EPOCH=16'ha308;
    logic clk=0; always #1 clk=~clk;
    logic rst_n=0,clear=0,counter_clear=0;
    logic txn_start_valid,txn_start_ready; logic [15:0] txn_epoch=EPOCH;
    logic [1:0] txn_numeric_mode;
    logic job_valid,job_ready; logic [15:0] job_epoch=EPOCH;
    logic [2:0] job_group; logic [4:0] job_global_q_head;
    logic [2:0] job_row_window;
    logic q_slab_need_valid,q_slab_need_ready; logic [15:0] q_slab_need_epoch;
    logic [2:0] q_slab_need_group; logic [4:0] q_slab_need_global_q_head;
    logic [2:0] q_slab_need_row_window;
    logic q_slab_ready_valid,q_slab_ready_ready; logic [15:0] q_slab_ready_epoch;
    logic [2:0] q_slab_ready_group; logic [4:0] q_slab_ready_global_q_head;
    logic [2:0] q_slab_ready_row_window; logic q_slab_ready_buffer;
    logic q_slab_retire_valid,q_slab_retire_ready; logic [15:0] q_slab_retire_epoch;
    logic [2:0] q_slab_retire_group; logic [4:0] q_slab_retire_global_q_head;
    logic [2:0] q_slab_retire_row_window; logic q_slab_retire_buffer;
    logic q_req_valid,q_req_ready; logic [3:0] q_req_context_tag; logic [6:0] q_req_d;
    logic q_rsp_valid; logic [3:0] q_rsp_context_tag; logic [15:0] q_rsp_bf16;
    logic k_req_valid,k_req_ready; logic [3:0] k_req_context_tag;
    logic [1:0] k_req_key_block; logic [6:0] k_req_d;
    logic k_rsp_valid; logic [3:0] k_rsp_context_tag; logic [511:0] k_rsp_vec;
    logic weight_wr_valid,weight_wr_ready; logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group; logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row; logic [1:0] weight_wr_slot_id,weight_wr_numeric_mode;
    logic [6:0] weight_wr_key; logic weight_wr_mask; logic [31:0] weight_wr_data;
    logic weight_wr_last,row_commit_valid,row_commit_ready;
    logic [15:0] row_commit_epoch; logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head; logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id,row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32,row_commit_inv_sum_fp32;
    logic pv_row_valid,pv_row_ready; logic [15:0] pv_row_epoch;
    logic [2:0] pv_row_group; logic [4:0] pv_row_global_q_head;
    logic [6:0] pv_row_row; logic [1:0] pv_row_slot_id,pv_row_numeric_mode;
    logic [31:0] pv_row_sum_fp32,pv_row_inv_sum_fp32;
    logic weight_rd_req_valid,weight_rd_req_ready; logic [15:0] weight_rd_req_epoch;
    logic [2:0] weight_rd_req_group; logic [4:0] weight_rd_req_global_q_head;
    logic [6:0] weight_rd_req_row; logic [1:0] weight_rd_req_slot_id;
    logic [1:0] weight_rd_req_numeric_mode; logic [6:0] weight_rd_req_key;
    logic weight_rd_rsp_valid; logic [15:0] weight_rd_rsp_epoch;
    logic [2:0] weight_rd_rsp_group; logic [4:0] weight_rd_rsp_global_q_head;
    logic [6:0] weight_rd_rsp_row; logic [1:0] weight_rd_rsp_slot_id;
    logic [1:0] weight_rd_rsp_numeric_mode; logic [6:0] weight_rd_rsp_key;
    logic weight_rd_rsp_mask; logic [31:0] weight_rd_rsp_data;
    logic v_req_valid,v_req_ready; logic [3:0] v_req_context_tag;
    logic [6:0] v_req_key; logic [1:0] v_req_feature_block;
    logic v_rsp_valid; logic [3:0] v_rsp_context_tag; logic [511:0] v_rsp_vec_bf16;
    logic out_valid,out_ready; logic [15:0] out_epoch; logic [11:0] out_seq;
    logic [4:0] out_global_q_head; logic [6:0] out_row;
    logic [1:0] out_feature_block; logic [511:0] out_data_bf16;
    logic out_row_last,out_tensor_last;
    logic weight_release_valid,weight_release_ready; logic [15:0] weight_release_epoch;
    logic [2:0] weight_release_group; logic [4:0] weight_release_global_q_head;
    logic [6:0] weight_release_row; logic [1:0] weight_release_slot_id;
    logic [1:0] weight_release_numeric_mode;
    logic error_valid,error_ready; logic [1:0] error_source; logic [15:0] error_epoch;
    logic [2:0] error_group; logic [4:0] error_global_q_head; logic [6:0] error_row;
    logic [1:0] error_slot_id,error_numeric_mode; logic [3:0] error_code;
    logic [6:0] error_bad_key; logic [5:0] slot_owner;
    logic [1:0] txn_numeric_mode_locked; logic qk_fault_hold;
    logic [63:0] q_slab_jobs_accepted,engine_jobs_started,qk_valid_macs;
    logic [63:0] rows_transferred,scores_transferred,b2_exp_commit,b2_weight_writes;
    logic [63:0] b3_pv_commit,b3_context_words,final_release_count;
    logic [63:0] c_weight_writes,c_row_commits,c_pv_rows,c_weight_requests;
    logic [63:0] c_weight_responses,c_weight_releases; logic c_error_sticky;
    logic [31:0] lfsr;
    logic q_pending,k_pending; integer q_delay,k_delay;
    logic [3:0] q_pending_tag,k_pending_tag;
    logic [6:0] q_pending_d,k_pending_d; logic [1:0] k_pending_block;
    logic q_req_stalled,k_req_stalled;
    logic [10:0] held_q_req; logic [12:0] held_k_req;
    logic need_pending; integer need_delay;
    logic [15:0] need_epoch_r; logic [2:0] need_group_r;
    logic [4:0] need_head_r; logic [2:0] need_window_r;
    logic [1:0] vpipe; logic [3:0] vtag0,vtag1;
    integer outputs,releases,retires,jobs_sent,cycles,quiet;
    integer prelude_stalls,prelude_watchdog;
    logic [1:0] prelude_ready_mode;
    integer heartbeat;
    integer qk_idle_cycles,qk_run_cycles,qk_emit_cycles,qk_done_cycles;
    logic out_stalled,release_stalled; logic [555:0] held_out; logic [34:0] held_release;

    cats_r4_a3_compute_cluster #(.HEAD_DIM(128),.SCALE_FP32(32'h00000000)) dut (
        .clk,.rst_n,.clear,.counter_clear,.txn_start_valid,.txn_start_ready,
        .txn_epoch,.txn_numeric_mode,.job_valid,.job_ready,.job_epoch,.job_group,
        .job_global_q_head,.job_row_window,.q_slab_need_valid,.q_slab_need_ready,
        .q_slab_need_epoch,.q_slab_need_group,.q_slab_need_global_q_head,
        .q_slab_need_row_window,.q_slab_ready_valid,.q_slab_ready_ready,
        .q_slab_ready_epoch,.q_slab_ready_group,.q_slab_ready_global_q_head,
        .q_slab_ready_row_window,.q_slab_ready_buffer,.q_slab_retire_valid,
        .q_slab_retire_ready,.q_slab_retire_epoch,.q_slab_retire_group,
        .q_slab_retire_global_q_head,.q_slab_retire_row_window,.q_slab_retire_buffer,
        .q_req_valid,.q_req_ready,.q_req_context_tag,.q_req_d,.q_rsp_valid,
        .q_rsp_context_tag,.q_rsp_bf16,.k_req_valid,.k_req_ready,.k_req_context_tag,
        .k_req_key_block,.k_req_d,.k_rsp_valid,.k_rsp_context_tag,.k_rsp_vec,
        .weight_wr_valid,.weight_wr_ready,.weight_wr_epoch,.weight_wr_group,
        .weight_wr_global_q_head,.weight_wr_row,.weight_wr_slot_id,
        .weight_wr_numeric_mode,.weight_wr_key,.weight_wr_mask,.weight_wr_data,
        .weight_wr_last,.row_commit_valid,.row_commit_ready,.row_commit_epoch,
        .row_commit_group,.row_commit_global_q_head,.row_commit_row,
        .row_commit_slot_id,.row_commit_numeric_mode,.row_commit_sum_fp32,
        .row_commit_inv_sum_fp32,.pv_row_valid,.pv_row_ready,.pv_row_epoch,
        .pv_row_group,.pv_row_global_q_head,.pv_row_row,.pv_row_slot_id,
        .pv_row_numeric_mode,.pv_row_sum_fp32,.pv_row_inv_sum_fp32,
        .weight_rd_req_valid,.weight_rd_req_ready,.weight_rd_req_epoch,
        .weight_rd_req_group,.weight_rd_req_global_q_head,.weight_rd_req_row,
        .weight_rd_req_slot_id,.weight_rd_req_numeric_mode,.weight_rd_req_key,
        .weight_rd_rsp_valid,.weight_rd_rsp_epoch,.weight_rd_rsp_group,
        .weight_rd_rsp_global_q_head,.weight_rd_rsp_row,.weight_rd_rsp_slot_id,
        .weight_rd_rsp_numeric_mode,.weight_rd_rsp_key,.weight_rd_rsp_mask,
        .weight_rd_rsp_data,.v_req_valid,.v_req_ready,.v_req_context_tag,.v_req_key,
        .v_req_feature_block,.v_rsp_valid,.v_rsp_context_tag,.v_rsp_vec_bf16,
        .out_valid,.out_ready,.out_epoch,.out_seq,.out_global_q_head,.out_row,
        .out_feature_block,.out_data_bf16,.out_row_last,.out_tensor_last,
        .weight_release_valid,.weight_release_ready,.weight_release_epoch,
        .weight_release_group,.weight_release_global_q_head,.weight_release_row,
        .weight_release_slot_id,.weight_release_numeric_mode,.error_valid,.error_ready,
        .error_source,.error_epoch,.error_group,.error_global_q_head,.error_row,
        .error_slot_id,.error_numeric_mode,.error_code,.error_bad_key,.slot_owner,
        .txn_numeric_mode_locked,.qk_fault_hold,.q_slab_jobs_accepted,
        .engine_jobs_started,.qk_valid_macs,.rows_transferred,.scores_transferred,
        .b2_exp_commit,.b2_weight_writes,.b3_pv_commit,.b3_context_words,
        .final_release_count
    );

    tb_cats_r4_b4_c_weight_model #(.SEED(SEED)) c_model (
        .clk,.rst_n,.clear,.counter_clear,.weight_wr_valid,.weight_wr_ready,
        .weight_wr_epoch,.weight_wr_group,.weight_wr_global_q_head,.weight_wr_row,
        .weight_wr_slot_id,.weight_wr_numeric_mode,.weight_wr_key,.weight_wr_mask,
        .weight_wr_data,.weight_wr_last,.row_commit_valid,.row_commit_ready,
        .row_commit_epoch,.row_commit_group,.row_commit_global_q_head,.row_commit_row,
        .row_commit_slot_id,.row_commit_numeric_mode,.row_commit_sum_fp32,
        .row_commit_inv_sum_fp32,.pv_row_valid,.pv_row_ready,.pv_row_epoch,
        .pv_row_group,.pv_row_global_q_head,.pv_row_row,.pv_row_slot_id,
        .pv_row_numeric_mode,.pv_row_sum_fp32,.pv_row_inv_sum_fp32,
        .weight_rd_req_valid,.weight_rd_req_ready,.weight_rd_req_epoch,
        .weight_rd_req_group,.weight_rd_req_global_q_head,.weight_rd_req_row,
        .weight_rd_req_slot_id,.weight_rd_req_numeric_mode,.weight_rd_req_key,
        .weight_rd_rsp_valid,.weight_rd_rsp_epoch,.weight_rd_rsp_group,
        .weight_rd_rsp_global_q_head,.weight_rd_rsp_row,.weight_rd_rsp_slot_id,
        .weight_rd_rsp_numeric_mode,.weight_rd_rsp_key,.weight_rd_rsp_mask,
        .weight_rd_rsp_data,.weight_release_valid,.weight_release_ready,
        .weight_release_epoch,.weight_release_group,.weight_release_global_q_head,
        .weight_release_row,.weight_release_slot_id,.weight_release_numeric_mode,
        .c_weight_writes,.c_row_commits,.c_pv_rows,.c_weight_requests,
        .c_weight_responses,.c_weight_releases,.c_error_sticky
    );

    assign q_req_ready=(prelude_ready_mode==1)?1'b1:
        (prelude_ready_mode==2)?1'b0:
        (|lfsr[15:0]);
    assign k_req_ready=(prelude_ready_mode!=0)?1'b0:
        (|lfsr[31:16]);
    assign q_rsp_valid=q_pending;
    assign q_rsp_context_tag=q_pending_tag;
    assign q_rsp_bf16={5'b10101,q_pending_tag,q_pending_d};
    assign k_rsp_valid=k_pending;
    assign k_rsp_context_tag=k_pending_tag;
    assign k_rsp_vec={32{{1'b1,k_pending_block,k_pending_d,
                          k_pending_tag,2'b10}}};
    assign q_slab_need_ready=!need_pending && (lfsr[0]||lfsr[5]||lfsr[20]);
    assign q_slab_retire_ready=lfsr[1]||lfsr[7]||lfsr[21];
    assign v_req_ready=lfsr[2]||lfsr[9]||lfsr[22];
    assign out_ready=lfsr[3]||lfsr[12]||lfsr[23];
    assign error_ready=lfsr[4]||lfsr[13]||lfsr[24];
    assign v_rsp_vec_bf16={32{16'h3f80}};

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            lfsr<=SEED;need_pending<=0;need_delay<=0;q_slab_ready_valid<=0;
            q_slab_ready_epoch<=0;q_slab_ready_group<=0;
            q_slab_ready_global_q_head<=0;q_slab_ready_row_window<=0;
            q_slab_ready_buffer<=0;vpipe<=0;v_rsp_valid<=0;v_rsp_context_tag<=0;
            q_pending<=0;k_pending<=0;q_delay<=0;k_delay<=0;
            q_pending_tag<=0;k_pending_tag<=0;q_pending_d<=0;k_pending_d<=0;
            k_pending_block<=0;
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            q_pending<=q_req_valid&&q_req_ready;
            k_pending<=k_req_valid&&k_req_ready;
            if(q_req_valid&&q_req_ready) begin
                q_pending_tag<=q_req_context_tag;q_pending_d<=q_req_d;
            end
            if(k_req_valid&&k_req_ready) begin
                k_pending_tag<=k_req_context_tag;k_pending_block<=k_req_key_block;
                k_pending_d<=k_req_d;
            end
            if(q_slab_need_valid&&q_slab_need_ready) begin
                need_pending<=1;need_delay<=2;need_epoch_r<=q_slab_need_epoch;
                need_group_r<=q_slab_need_group;need_head_r<=q_slab_need_global_q_head;
                need_window_r<=q_slab_need_row_window;
            end
            if(need_pending&&need_delay>0) need_delay<=need_delay-1;
            if(need_pending&&need_delay==1) begin
                q_slab_ready_valid<=1;q_slab_ready_epoch<=need_epoch_r;
                q_slab_ready_group<=need_group_r;q_slab_ready_global_q_head<=need_head_r;
                q_slab_ready_row_window<=need_window_r;q_slab_ready_buffer<=need_head_r[0];
            end
            if(q_slab_ready_valid&&q_slab_ready_ready) begin
                q_slab_ready_valid<=0;need_pending<=0;
            end
            vpipe<={vpipe[0],v_req_valid&&v_req_ready};
            if(v_req_valid&&v_req_ready) vtag0<=v_req_context_tag;
            vtag1<=vtag0;v_rsp_valid<=vpipe[1];v_rsp_context_tag<=vtag1;
        end
    end

    always_ff @(posedge clk) begin
        integer expected_head,expected_row,expected_block;
        if(!rst_n||clear) begin
            outputs<=0;releases<=0;retires<=0;out_stalled<=0;release_stalled<=0;
            q_req_stalled<=0;k_req_stalled<=0;held_q_req<=0;held_k_req<=0;
        end else begin
            if(q_req_stalled&&(!q_req_valid||{q_req_context_tag,q_req_d}!==held_q_req))
                $fatal(1,"Q request payload changed under backpressure");
            if(k_req_stalled&&(!k_req_valid||
               {k_req_context_tag,k_req_key_block,k_req_d}!==held_k_req))
                $fatal(1,"K request payload changed under backpressure");
            q_req_stalled<=q_req_valid&&!q_req_ready;
            k_req_stalled<=k_req_valid&&!k_req_ready;
            if(q_req_valid&&!q_req_ready) held_q_req<={q_req_context_tag,q_req_d};
            if(k_req_valid&&!k_req_ready)
                held_k_req<={k_req_context_tag,k_req_key_block,k_req_d};
            if(error_valid&&error_ready) $fatal(1,"unexpected unified error source=%0d code=%0d",error_source,error_code);
            if(out_stalled && (!out_valid || {out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last}!==held_out))
                $fatal(1,"output payload changed under backpressure");
            out_stalled<=out_valid&&!out_ready;
            if(out_valid&&!out_ready) held_out<={out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last};
            if(out_valid&&out_ready) begin
                expected_head=outputs/(128*4);expected_row=(outputs/4)%128;expected_block=outputs%4;
                if(out_epoch!==EPOCH||out_global_q_head!==expected_head||out_row!==expected_row||
                   out_seq!==(expected_head*128+expected_row)||out_feature_block!==expected_block||
                   out_data_bf16!=={32{16'h3f80}}||out_row_last!==(expected_block==3)||
                   out_tensor_last!==(outputs==16383)) $fatal(1,"canonical output mismatch index=%0d",outputs);
                outputs<=outputs+1;
            end
            if(release_stalled && (!weight_release_valid || {weight_release_epoch,weight_release_group,weight_release_global_q_head,weight_release_row,weight_release_slot_id,weight_release_numeric_mode}!==held_release))
                $fatal(1,"release payload changed under backpressure");
            release_stalled<=weight_release_valid&&!weight_release_ready;
            if(weight_release_valid&&!weight_release_ready) held_release<={weight_release_epoch,weight_release_group,weight_release_global_q_head,weight_release_row,weight_release_slot_id,weight_release_numeric_mode};
            if(weight_release_valid&&weight_release_ready) begin
                if(weight_release_epoch!==EPOCH||weight_release_group!==weight_release_global_q_head[4:2]||
                   weight_release_global_q_head!==releases/128||weight_release_row!==releases%128||
                   weight_release_numeric_mode!==MODE) $fatal(1,"release order mismatch index=%0d",releases);
                releases<=releases+1;
            end
            if(q_slab_retire_valid&&q_slab_retire_ready) begin
                if(q_slab_retire_epoch!==EPOCH||q_slab_retire_group!==q_slab_retire_global_q_head[4:2]||
                   q_slab_retire_global_q_head!==retires/8||q_slab_retire_row_window!==retires%8)
                    $fatal(1,"retire order mismatch index=%0d",retires);
                retires<=retires+1;
            end
        end
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            heartbeat=0;qk_idle_cycles=0;qk_run_cycles=0;
            qk_emit_cycles=0;qk_done_cycles=0;
        end
        else begin
            heartbeat=heartbeat+1;
            case(dut.u_qk_engine.state)
                0:qk_idle_cycles=qk_idle_cycles+1;
                1:qk_run_cycles=qk_run_cycles+1;
                2:qk_emit_cycles=qk_emit_cycles+1;
                3:qk_done_cycles=qk_done_cycles+1;
            endcase
            if((heartbeat%100000)==0) begin
                $display("PROGRESS heartbeat=%0d jobs_counter=%0d rows=%0d scores=%0d releases=%0d final=%0d outputs=%0d owner=%h client=%0d qk=%0d ctx=%0d score=%b/%b raw=%b b2=%0d/%0d/%0d",
                    heartbeat,q_slab_jobs_accepted,rows_transferred,scores_transferred,releases,
                    final_release_count,outputs,slot_owner,dut.u_q_slab_client.state,
                    dut.u_qk_engine.state,dut.u_qk_engine.context_r,
                    dut.engine_score_valid,dut.engine_score_ready,dut.frontend_raw_score_ready,
                    dut.u_b4.u_softmax.state[0],dut.u_b4.u_softmax.state[1],dut.u_b4.u_softmax.state[2]);
                $display("PROGRESS a2 fmt=%b/%b keyblock=%0d opened=%b rowopen=%b/%b block=%b/%b asm=%0d hs=%b/%b release=%b/%b",
                    dut.u_row_frontend.u_a2.fmt_out_valid,dut.u_row_frontend.u_a2.fmt_out_ready,
                    dut.u_row_frontend.u_a2.fmt_key_block,dut.u_row_frontend.u_a2.formatted_row_opened,
                    dut.u_row_frontend.u_a2.row_open_valid,dut.u_row_frontend.u_a2.row_open_ready,
                    dut.u_row_frontend.u_a2.block_valid,dut.u_row_frontend.u_a2.block_ready,
                    {dut.u_row_frontend.u_a2.u_rows.u_assembler.slot_active[2],dut.u_row_frontend.u_a2.u_rows.u_assembler.slot_active[1],dut.u_row_frontend.u_a2.u_rows.u_assembler.slot_active[0]},
                    dut.u_row_frontend.u_a2.u_rows.hs_valid,dut.u_row_frontend.u_a2.u_rows.hs_ready,
                    dut.final_release_valid,dut.final_release_ready);
                $fflush();
            end
        end
    end

    initial begin
        txn_start_valid=0;job_valid=0;txn_numeric_mode=MODE[1:0];jobs_sent=0;
        prelude_ready_mode=1;
        repeat(8) @(posedge clk);rst_n=1;repeat(3) @(posedge clk);
        force dut.engine_score_ready=1'b0;
        @(negedge clk);txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        for(jobs_sent=0;jobs_sent<JOB_COUNT;jobs_sent=jobs_sent+1) begin
            job_global_q_head=jobs_sent/8;job_group=(jobs_sent/8)>>2;job_row_window=jobs_sent%8;
            job_valid=1;do @(posedge clk); while(!job_ready);@(negedge clk);job_valid=0;
            if(jobs_sent==0) begin
                prelude_watchdog=0;
                while(dut.unused64[8]==0&&prelude_watchdog<100) begin
                    @(negedge clk);prelude_watchdog=prelude_watchdog+1;
                end
                if(prelude_watchdog==100||dut.unused64[8]!==1||
                   dut.unused64[9]!==0||dut.unused64[22]!==0)
                    $fatal(1,"Q/K-score independence prelude failed q=%0d k=%0d commits=%0d",
                           dut.unused64[8],dut.unused64[9],dut.unused64[22]);
                prelude_stalls=dut.unused64[14];prelude_ready_mode=2;
                repeat(4) @(posedge clk);
                @(negedge clk);
                if(dut.unused64[14]<(prelude_stalls+3)||dut.unused64[22]!==0)
                    $fatal(1,"memory-stall prelude failed stalls=%0d base=%0d commits=%0d",
                           dut.unused64[14],prelude_stalls,dut.unused64[22]);
                $display("PASS A3 QK HANDSHAKE PRELUDE q=%0d k=%0d memory_stalls=%0d score_commits=%0d",
                         dut.unused64[8],dut.unused64[9],dut.unused64[14],dut.unused64[22]);
                prelude_ready_mode=0;release dut.engine_score_ready;
                if(SMOKE_ONLY) begin
                    $display("EVIDENCE_LEVEL=PROTOCOL_MODEL_NOT_REAL_IP");
                    $finish;
                end
            end
            if(jobs_sent<4 || (jobs_sent%16)==15) begin
                $display("PROGRESS jobs=%0d rows=%0d scores=%0d releases=%0d outputs=%0d",
                    jobs_sent+1,rows_transferred,scores_transferred,releases,outputs);
                $fflush();
            end
        end
        cycles=0;
        while((outputs<(JOB_COUNT*64)||releases<(JOB_COUNT*16)||
               retires<JOB_COUNT)&&cycles<12000000) begin
            @(posedge clk);cycles=cycles+1;
            if(cycles%1000000==0) begin
                $display("PROGRESS cycles=%0d outputs=%0d releases=%0d retires=%0d rows=%0d",cycles,outputs,releases,retires,rows_transferred);
                $fflush();
            end
        end
        if(cycles==12000000) $fatal(1,"full protocol watchdog outputs=%0d releases=%0d retires=%0d",outputs,releases,retires);
        for(quiet=0;quiet<100;quiet=quiet+1) @(posedge clk);
        if(JOB_COUNT!=256) begin
            if(outputs!==(JOB_COUNT*64)||releases!==(JOB_COUNT*16)||
               retires!==JOB_COUNT||q_slab_jobs_accepted!==JOB_COUNT||
               engine_jobs_started!==(JOB_COUNT*24)||
               rows_transferred!==(JOB_COUNT*16)||
               scores_transferred!==(JOB_COUNT*1032)||
               qk_valid_macs!==(JOB_COUNT*132096)||
               dut.unused64[8]!==(JOB_COUNT*5120)||
               dut.unused64[9]!==(JOB_COUNT*5120)||
               dut.unused64[10]!==(JOB_COUNT*5120)||
               dut.unused64[11]!==(JOB_COUNT*5120)||
               dut.unused64[12]!==(JOB_COUNT*31744)||
               dut.unused64[13]!==(JOB_COUNT*24)||
               dut.unused64[17]!==(JOB_COUNT*5120)||
               dut.unused64[18]!==(JOB_COUNT*132096)||
               dut.unused64[19]!==(JOB_COUNT*132096)||
               dut.unused64[20]!==(JOB_COUNT*5120)||
               dut.unused64[22]!==(JOB_COUNT*40))
                $fatal(1,"protocol slice counter mismatch jobs=%0d rows=%0d scores=%0d q=%0d k=%0d macs=%0d",
                       q_slab_jobs_accepted,rows_transferred,scores_transferred,
                       dut.unused64[8],dut.unused64[9],qk_valid_macs);
            $display("PASS A3 FULL PROTOCOL SLICE jobs=%0d rows=%0d causal_scores=%0d qk_macs=%0d",
                     JOB_COUNT,rows_transferred,scores_transferred,qk_valid_macs);
            $display("SLICE_CYCLES total=%0d qk_idle=%0d qk_run=%0d qk_emit=%0d qk_done=%0d q=%0d k=%0d",
                     heartbeat,qk_idle_cycles,qk_run_cycles,qk_emit_cycles,
                     qk_done_cycles,dut.unused64[8],dut.unused64[9]);
            $display("EVIDENCE_LEVEL=PROTOCOL_MODEL_NOT_REAL_IP");
            $finish;
        end
        if(outputs!==16384||releases!==4096||retires!==256||slot_owner!==0||qk_fault_hold||
           q_slab_jobs_accepted!==256||engine_jobs_started!==6144||qk_valid_macs!==33816576||
           rows_transferred!==4096||scores_transferred!==264192||b2_exp_commit!==264192||
           b2_weight_writes!==524288||b3_pv_commit!==33816576||b3_context_words!==524288||
           final_release_count!==4096||c_weight_writes!==524288||c_row_commits!==4096||
           c_pv_rows!==4096||c_weight_releases!==4096||c_error_sticky)
            $fatal(1,"full protocol counter closure mismatch rows=%0d scores=%0d qk=%0d pv=%0d words=%0d releases=%0d retires=%0d starts=%0d",rows_transferred,scores_transferred,qk_valid_macs,b3_pv_commit,b3_context_words,final_release_count,retires,engine_jobs_started);
        if(dut.unused64[8]!==1310720||dut.unused64[9]!==1310720||
           dut.unused64[10]!==1310720||dut.unused64[11]!==1310720||
           dut.unused64[12]!==8126464||dut.unused64[13]!==6144||
           dut.unused64[17]!==1310720||dut.unused64[18]!==33816576||
           dut.unused64[19]!==33816576||dut.unused64[20]!==1310720||
           dut.unused64[22]!==10240||c_weight_requests!==264192||
           c_weight_responses!==264192)
            $fatal(1,"QK/C model counter mismatch q=%0d k=%0d issue=%0d complete=%0d bubbles=%0d skips=%0d commits=%0d c_req=%0d c_rsp=%0d",dut.unused64[8],dut.unused64[9],dut.unused64[10],dut.unused64[11],dut.unused64[12],dut.unused64[13],dut.unused64[22],c_weight_requests,c_weight_responses);
        if(dut.unused64[6]||dut.unused64[7]||dut.unused64[16]||
           dut.unused64[21]||dut.unused64[26]||
           dut.unused64[27]||dut.unused64[31]||dut.unused64[37]||dut.unused64[38]||
           dut.unused64[39]||dut.unused64[40]||dut.unused64[41]||dut.unused64[42]||
           dut.unused64[48]||dut.unused64[49]||dut.unused64[50]||dut.unused64[61]||
           dut.unused64[62]||dut.unused64[63]||dut.u_b4.release_join_errors||
           dut.unused_sticky[0]||dut.unused_sticky[1]||dut.unused_sticky[2]||
           dut.unused_sticky[3]||dut.unused_sticky[4]||dut.unused_sticky[5]||
           dut.unused_sticky[6]||dut.unused_sticky[7]) $fatal(1,"nonzero protocol/numeric/owner/release/memory/context error");
        if(out_valid||weight_release_valid||q_slab_retire_valid||error_valid)
            $fatal(1,"traffic remained after quiet closure");
        $display("PASS A3 FULL PROTOCOL MODEL rows=4096 causal_scores=264192 weight_writes=524288 qk_macs=33816576 pv_macs=33816576 context_words=524288 releases=4096");
        $display("EVIDENCE_LEVEL=PROTOCOL_MODEL_NOT_REAL_IP");
        $finish;
    end
endmodule
