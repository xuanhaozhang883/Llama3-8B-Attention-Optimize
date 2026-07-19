`timescale 1ns/1ps

// Real qk_systolic_gqa_top RTL -> qk_softmax_adapter integration test.
// Uses simulation-only floating_point_0/1/2 models and a small but nontrivial
// TILE=4, SEQ_LEN=8, HEAD_DIM=8, Q_HEADS=2 configuration.
module tb_qk_adapter_integration;
    localparam int TILE=4, SEQ_LEN=8, HEAD_DIM=8, Q_HEADS=2;
    localparam int HEAD_W=1, POS_W=3, DIM_W=3;
    localparam int TOTAL=Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam logic [31:0] SCALE_FP32=32'h3EB504F3;

    parameter Q_FILE="q_small_bf16.mem";
    parameter K_FILE="k_small_bf16.mem";
    parameter EXPECT_FILE="expected_adapter_row_order.mem";

    logic clk=0; always #5 clk=~clk;
    logic rst_n,start,qk_busy,qk_done;
    logic vec_ready,vec_valid;
    logic [TILE*16-1:0] q_vec_bf16,k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [POS_W-1:0] req_row_base,req_col_base;
    logic [DIM_W-1:0] req_dim;
    logic score_valid,score_ready;
    logic [15:0] score_bf16;
    logic [31:0] score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [POS_W-1:0] score_row,score_col;
    logic score_last;

    logic row_valid,row_ready,row_mask,row_first,row_last,row_global_last;
    logic [15:0] row_data;
    logic [HEAD_W-1:0] row_head;
    logic [POS_W-1:0] row_index,row_col;
    logic adapter_busy,protocol_error,global_last_error;

    logic [15:0] q_mem[0:Q_HEADS*SEQ_LEN*HEAD_DIM-1];
    logic [15:0] k_mem[0:SEQ_LEN*HEAD_DIM-1];
    logic [25:0] expected_mem[0:TOTAL-1];
    integer lane,recv_count,ready_count,global_last_count,qk_done_count;

    qk_systolic_gqa_top #(
        .TILE(TILE),.SEQ_LEN(SEQ_LEN),.HEAD_DIM(HEAD_DIM),.Q_HEADS(Q_HEADS),
        .SCALE_FP32(SCALE_FP32)
    ) u_qk (
        .clk,.rst_n,.start,.busy(qk_busy),.done(qk_done),
        .vec_ready,.vec_valid,.q_vec_bf16,.k_vec_bf16,
        .req_head,.req_row_base,.req_col_base,.req_dim,
        .score_valid,.score_ready,.score_bf16,.score_fp32_debug,
        .score_head,.score_row,.score_col,.score_last
    );

    qk_softmax_adapter #(
        .SEQ_LEN(SEQ_LEN),.TILE(TILE),.Q_HEADS(Q_HEADS),
        .HEAD_W(HEAD_W),.POS_W(POS_W)
    ) u_adapter (
        .clk,.rst_n,.causal_en(1'b1),
        .qk_valid(score_valid),.qk_ready(score_ready),.qk_score(score_bf16),
        .qk_head(score_head),.qk_row(score_row),.qk_col(score_col),
        .qk_global_last(score_last),
        .row_valid,.row_ready,.row_data,.row_mask,.row_head,
        .row_index,.row_col,.row_first,.row_last,.row_global_last,
        .busy(adapter_busy),.protocol_error,.global_last_error
    );

    always_comb begin
        vec_valid= rst_n && qk_busy;
        q_vec_bf16='0; k_vec_bf16='0;
        for (lane=0;lane<TILE;lane=lane+1) begin
            q_vec_bf16[lane*16 +:16]=q_mem[req_head*SEQ_LEN*HEAD_DIM+
                (req_row_base+lane)*HEAD_DIM+req_dim];
            k_vec_bf16[lane*16 +:16]=k_mem[(req_col_base+lane)*HEAD_DIM+req_dim];
        end
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin ready_count<=0; row_ready<=0; end
        else begin
            ready_count<=ready_count+1;
            row_ready<=((ready_count%9)!=3)&&((ready_count%13)!=7);
        end
    end

    always_ff @(posedge clk) begin
        logic [25:0] actual;
        if(!rst_n) begin
            recv_count<=0;
            global_last_count<=0;
            qk_done_count<=0;
        end else begin
            if (qk_done)
                qk_done_count<=qk_done_count+1;
            if(row_valid&&row_ready) begin
            actual={row_last,row_first,row_col,row_index,row_head,row_mask,row_data};
            if(actual!==expected_mem[recv_count]) begin
                $display("QK->Adapter mismatch index=%0d expected=%07h actual=%07h",recv_count,expected_mem[recv_count],actual);
                $fatal(1,"Real QK adapter integration mismatch");
            end
            if(row_global_last) global_last_count<=global_last_count+1;
                recv_count<=recv_count+1;
            end
        end
    end

    initial begin
        $readmemh(Q_FILE,q_mem); $readmemh(K_FILE,k_mem); $readmemh(EXPECT_FILE,expected_mem);
        rst_n=0; start=0;
        repeat(6) @(posedge clk); @(negedge clk) rst_n=1;
        repeat(3) @(posedge clk); @(negedge clk) start=1;
        @(negedge clk) start=0;
        wait(recv_count==TOTAL);
        repeat(5) @(posedge clk);
        if(qk_busy) $fatal(1,"QK remained busy after all adapter outputs");
        if(qk_done_count!=1) $fatal(1,"Expected one qk_done pulse, got %0d",qk_done_count);
        if(protocol_error) $fatal(1,"Adapter protocol_error");
        if(global_last_error) $fatal(1,"QK global-last marker error");
        if(global_last_count!=1) $fatal(1,"Expected one row_global_last, got %0d",global_last_count);
        $display("PASS: real QK -> Adapter integration, outputs=%0d",recv_count);
        $finish;
    end

    initial begin #5000000; $fatal(1,"Timeout: real QK adapter integration"); end
endmodule
