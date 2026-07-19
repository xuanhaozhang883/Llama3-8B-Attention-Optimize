`timescale 1ns/1ps

// v4 control/metadata regression:
// * two sequential GQA groups;
// * illegal group_start while busy is rejected;
// * group ID is locked for each launch;
// * global Q-head and KV-head requests are correct.
module tb_qk_softmax_group_control;
    localparam int TILE=4, SEQ_LEN=8, HEAD_DIM=8, Q_HEADS=2, GQA_GROUPS=8;
    localparam int HEAD_W=1, GROUP_W=3, GLOBAL_Q_HEAD_W=4, POS_W=3, DIM_W=3;
    localparam int PER_GROUP=Q_HEADS*SEQ_LEN*SEQ_LEN;
    parameter Q_FILE="q_small_bf16.mem";
    parameter K_FILE="k_small_bf16.mem";
    parameter EXP_LUT_FILE="exp_lut_q15.mem";

    logic clk=0; always #5 clk=~clk;
    logic rst_n,group_start,causal_en;
    logic [GROUP_W-1:0] group_id,active_group_id;
    logic group_start_ready;
    logic vec_ready,vec_valid;
    logic [TILE*16-1:0] q_vec_bf16,k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [GROUP_W-1:0] req_group_id,req_kv_head;
    logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head;
    logic [POS_W-1:0] req_row_base,req_col_base;
    logic [DIM_W-1:0] req_dim;
    logic prob_valid,prob_ready;
    logic [15:0] prob_data;
    logic [GROUP_W-1:0] prob_group_id;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row,prob_col;
    logic prob_first,prob_last,prob_group_last,prob_global_last;
    logic qk_busy,qk_done,frontend_busy,pipeline_busy,group_done,pipeline_done;
    logic start_while_busy_error,invalid_group_id_error;
    logic adapter_protocol_error,adapter_global_last_error;
    logic softmax_row_error,softmax_metadata_error;
    logic [15:0] q_mem[0:Q_HEADS*SEQ_LEN*HEAD_DIM-1];
    logic [15:0] k_mem[0:SEQ_LEN*HEAD_DIM-1];
    integer lane,total_recv,group_recv,done_count;
    logic [GROUP_W-1:0] expected_group;

    qk_softmax_pipeline_top #(
        .TILE(TILE),.SEQ_LEN(SEQ_LEN),.HEAD_DIM(HEAD_DIM),.Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),.HEAD_W(HEAD_W),.GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),.POS_W(POS_W),.DIM_W(DIM_W),
        .SCALE_FP32(32'h3EB504F3),.EXP_LUT_FILE(EXP_LUT_FILE)
    ) dut (
        .clk,.rst_n,.group_start,.group_id,.group_start_ready,.active_group_id,.causal_en,
        .vec_ready,.vec_valid,.q_vec_bf16,.k_vec_bf16,
        .req_head,.req_group_id,.req_global_q_head,.req_kv_head,
        .req_row_base,.req_col_base,.req_dim,
        .prob_valid,.prob_ready,.prob_data,.prob_group_id,
        .prob_head,.prob_row,.prob_col,.prob_first,.prob_last,
        .prob_group_last,.prob_global_last,
        .qk_busy,.qk_done,.frontend_busy,.pipeline_busy,.group_done,.pipeline_done,
        .start_while_busy_error,.invalid_group_id_error,
        .adapter_protocol_error,.adapter_global_last_error,
        .softmax_row_error,.softmax_metadata_error
    );

    always_comb begin
        vec_valid=rst_n&&qk_busy;
        q_vec_bf16='0;
        k_vec_bf16='0;
        for(lane=0;lane<TILE;lane=lane+1) begin
            q_vec_bf16[lane*16 +:16]=q_mem[req_head*SEQ_LEN*HEAD_DIM+
                (req_row_base+lane)*HEAD_DIM+req_dim];
            k_vec_bf16[lane*16 +:16]=k_mem[(req_col_base+lane)*HEAD_DIM+req_dim];
        end
    end

    assign prob_ready=1'b1;

    always @(posedge clk) begin
        integer eh,er,ec;
        if(!rst_n) begin
            total_recv=0;
            group_recv=0;
            done_count=0;
        end else begin
            if(group_start && group_start_ready)
                group_recv=0;
            if(adapter_protocol_error||adapter_global_last_error||softmax_row_error||
               softmax_metadata_error||invalid_group_id_error)
                $fatal(1,"Unexpected protocol/data error in group-control test");
            if(vec_valid&&vec_ready) begin
                if(req_group_id!==expected_group || req_kv_head!==expected_group)
                    $fatal(1,"Request group changed during active launch");
                if(req_global_q_head!==((expected_group*Q_HEADS)+req_head))
                    $fatal(1,"Global Q-head mapping error");
            end
            if(prob_valid&&prob_ready) begin
                eh=group_recv/(SEQ_LEN*SEQ_LEN);
                er=(group_recv/SEQ_LEN)%SEQ_LEN;
                ec=group_recv%SEQ_LEN;
                if(prob_group_id!==expected_group || active_group_id!==expected_group)
                    $fatal(1,"Output group changed during active launch");
                if(prob_head!==eh[HEAD_W-1:0]||prob_row!==er[POS_W-1:0]||prob_col!==ec[POS_W-1:0])
                    $fatal(1,"Output metadata error group=%0d index=%0d",expected_group,group_recv);
                if(prob_group_last!==((eh==Q_HEADS-1)&&(er==SEQ_LEN-1)&&(ec==SEQ_LEN-1)))
                    $fatal(1,"Group-last error");
                group_recv=group_recv+1;
                total_recv=total_recv+1;
            end
            if(group_done) begin
                if(group_recv!=PER_GROUP)
                    $fatal(1,"group_done before all probabilities: %0d/%0d",group_recv,PER_GROUP);
                done_count=done_count+1;
            end
        end
    end

    task automatic launch_group(input logic [GROUP_W-1:0] gid);
        begin
            wait(group_start_ready);
            expected_group=gid;
            @(negedge clk); group_id=gid; group_start=1'b1;
            @(negedge clk); group_start=1'b0;
        end
    endtask

    initial begin
        $readmemh(Q_FILE,q_mem);
        $readmemh(K_FILE,k_mem);
        rst_n=0; group_start=0; group_id=0; causal_en=1; expected_group=0;
        repeat(6) @(posedge clk); @(negedge clk) rst_n=1;

        launch_group(3'd2);
        wait(qk_busy);
        repeat(12) @(posedge clk);
        // Illegal second launch must be rejected and must not replace group 2.
        @(negedge clk); group_id=3'd6; group_start=1'b1;
        @(negedge clk); group_start=1'b0;
        repeat(2) @(posedge clk);
        if(!start_while_busy_error) $fatal(1,"Busy-start error was not reported");
        if(active_group_id!==3'd2) $fatal(1,"Busy start overwrote active group");

        wait(done_count==1);
        launch_group(3'd7);
        repeat(2) @(posedge clk);
        if(start_while_busy_error) $fatal(1,"Accepted launch did not clear busy-start error");
        wait(done_count==2);
        repeat(8) @(posedge clk);

        if(total_recv!=2*PER_GROUP)
            $fatal(1,"Expected %0d total probabilities, got %0d",2*PER_GROUP,total_recv);
        if(pipeline_busy) $fatal(1,"Pipeline remained busy");
        $display("PASS: v4 multi-group start/lock/address/control test");
        $display("groups=2 probabilities=%0d",total_recv);
        $finish;
    end

    initial begin #20000000; $fatal(1,"Timeout: group-control test"); end
endmodule
