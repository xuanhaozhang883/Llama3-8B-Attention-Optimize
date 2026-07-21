`timescale 1ns/1ps

// Small numerical integration: raw split-half Q/K -> 90-degree RoPE ->
// Group cache/vector loader -> real QK systolic array.
module tb_rope_qk_pipeline_small;
    localparam int TILE=2, SEQ_LEN=4, HEAD_DIM=4, Q_HEADS=4, GQA_GROUPS=8;
    localparam int HEAD_W=2, GROUP_W=3, GLOBAL_HEAD_W=5, POS_W=2, DIM_W=2, PAIR_W=1;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic group_start, group_start_ready;
    logic [GROUP_W-1:0] group_id, active_group_id, pipeline_group_id;
    logic bridge_busy, rope_done;
    logic raw_req_valid, raw_req_ready, raw_req_is_k;
    logic [GLOBAL_HEAD_W-1:0] raw_req_head;
    logic [POS_W-1:0] raw_req_token;
    logic [PAIR_W-1:0] raw_req_pair;
    logic raw_rsp_valid, raw_rsp_ready;
    logic [15:0] raw_rsp_x0, raw_rsp_x1;
    logic pipeline_start, pipeline_start_ready, pipeline_done;
    logic [HEAD_W-1:0] req_head;
    logic [POS_W-1:0] req_row_base, req_col_base;
    logic [DIM_W-1:0] req_dim;
    logic qk_vec_ready, qk_vec_valid;
    logic [TILE*16-1:0] q_vec_bf16, k_vec_bf16;
    logic qk_busy, score_valid, score_ready, score_last;
    logic [15:0] score_bf16;
    logic [31:0] score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [POS_W-1:0] score_row, score_col;
    integer req_count=0, vec_count=0, score_count=0, rope_done_count=0;
    integer cycle_count=0;
    integer lane;

    rope_group_bridge #(
        .QK_TILE(TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        // Vivado exports memory files into the XSim working directory.
        .SIN_ROM_FILE("rope_small_sin.hex"),
        .COS_ROM_FILE("rope_small_cos.hex")
    ) dut_bridge (
        .clk, .rst_n, .group_start, .group_id, .group_start_ready,
        .active_group_id, .busy(bridge_busy), .rope_done,
        .raw_req_valid, .raw_req_ready, .raw_req_is_k, .raw_req_head,
        .raw_req_token, .raw_req_pair, .raw_rsp_valid, .raw_rsp_ready,
        .raw_rsp_x0, .raw_rsp_x1,
        .pipeline_group_start(pipeline_start),
        .pipeline_group_start_ready(pipeline_start_ready),
        .pipeline_group_id, .pipeline_done,
        .req_head, .req_row_base, .req_col_base, .req_dim,
        .qk_vec_ready, .qk_vec_valid, .q_vec_bf16, .k_vec_bf16
    );

    qk_systolic_gqa_top #(
        .TILE(TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .SCALE_FP32(32'h3F800000)
    ) dut_qk (
        .clk, .rst_n, .start(pipeline_start), .busy(qk_busy), .done(pipeline_done),
        .vec_ready(qk_vec_ready), .vec_valid(qk_vec_valid),
        .q_vec_bf16, .k_vec_bf16, .req_head, .req_row_base,
        .req_col_base, .req_dim, .score_valid, .score_ready,
        .score_bf16, .score_fp32_debug, .score_head, .score_row,
        .score_col, .score_last
    );
    assign pipeline_start_ready=!qk_busy;
    assign raw_req_ready=rst_n && !raw_rsp_valid && ((cycle_count%3)!=1);
    assign score_ready=rst_n && ((cycle_count%5)!=2);

    always_ff @(posedge clk) begin
        if(!rst_n) cycle_count<=0;
        else cycle_count<=cycle_count+1;
    end

    // One-cycle registered raw-memory response. Every pair is Q=(1,2),
    // K=(3,4); sin=1/cos=0 rotates them to Q=(-2,1), K=(-4,3).
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            raw_rsp_valid<=0; raw_rsp_x0<=0; raw_rsp_x1<=0;
        end else begin
            if(raw_rsp_valid && raw_rsp_ready) raw_rsp_valid<=0;
            if(raw_req_valid && raw_req_ready) begin
                raw_rsp_valid<=1;
                raw_rsp_x0<=raw_req_is_k ? 16'h4040 : 16'h3F80;
                raw_rsp_x1<=raw_req_is_k ? 16'h4080 : 16'h4000;
                if(raw_req_is_k) begin
                    if(raw_req_head!==3'd7) $fatal(1,"K head mapping error");
                end else if(raw_req_head!==(5'd28+req_count/(SEQ_LEN*(HEAD_DIM/2))))
                    $fatal(1,"Q head mapping error req=%0d head=%0d",req_count,raw_req_head);
                req_count<=req_count+1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if(rst_n && rope_done) rope_done_count<=rope_done_count+1;
        if(rst_n && qk_vec_valid && qk_vec_ready) begin
            for(lane=0;lane<TILE;lane=lane+1) begin
                if(q_vec_bf16[lane*16 +:16] !== ((req_dim<2)?16'hC000:16'h3F80))
                    $fatal(1,"rotated Q mismatch dim=%0d lane=%0d got=%h",req_dim,lane,q_vec_bf16[lane*16 +:16]);
                if(k_vec_bf16[lane*16 +:16] !== ((req_dim<2)?16'hC080:16'h4040))
                    $fatal(1,"rotated K mismatch dim=%0d lane=%0d got=%h",req_dim,lane,k_vec_bf16[lane*16 +:16]);
            end
            if(active_group_id!==3'd7 || pipeline_group_id!==3'd7)
                $fatal(1,"active Group was not locked");
            vec_count<=vec_count+1;
        end
        if(rst_n && score_valid && score_ready) begin
            if(score_bf16!==16'h41B0)
                $fatal(1,"QK score mismatch index=%0d expected=41B0 got=%h",score_count,score_bf16);
            if(score_last !== (score_count==Q_HEADS*SEQ_LEN*SEQ_LEN-1))
                $fatal(1,"score_last mismatch index=%0d",score_count);
            score_count<=score_count+1;
        end
    end

    initial begin
        group_start=0; group_id=7;
        repeat(5) @(posedge clk); @(negedge clk) rst_n=1;
        wait(group_start_ready); @(negedge clk) group_start=1;
        @(negedge clk) group_start=0;
        wait(pipeline_done); @(posedge clk); @(negedge clk);
        if(req_count!=Q_HEADS*SEQ_LEN*(HEAD_DIM/2)+SEQ_LEN*(HEAD_DIM/2))
            $fatal(1,"raw request count mismatch %0d",req_count);
        if(vec_count!=Q_HEADS*(SEQ_LEN/TILE)*(SEQ_LEN/TILE)*HEAD_DIM)
            $fatal(1,"QK vector count mismatch %0d",vec_count);
        if(score_count!=Q_HEADS*SEQ_LEN*SEQ_LEN || rope_done_count!=1)
            $fatal(1,"completion/count mismatch score=%0d rope_done=%0d",score_count,rope_done_count);
        if(bridge_busy || qk_busy) $fatal(1,"modules failed to return idle");
        $display("TEST_RESULT: PASS RoPE->QK Group 7 scores=%0d",score_count);
        $finish;
    end
    initial begin #20_000_000; $fatal(1,"timeout"); end
endmodule
