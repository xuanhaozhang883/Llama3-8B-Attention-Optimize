`timescale 1ns/1ps

// Optional, long-running full-configuration test:
// real qk_systolic_gqa_top -> qk_softmax_adapter, 4x128x128, HEAD_DIM=128.
// It is intentionally excluded from run_vivado_v4_all.tcl because the behavioral
// FP models make this test much slower than the small real-QK integration test.
module tb_qk_adapter_integration_full_optional;
    localparam int TILE=4, SEQ_LEN=128, HEAD_DIM=128, Q_HEADS=4;
    localparam int HEAD_W=2, POS_W=7, DIM_W=7;
    localparam int TOTAL=Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam logic [31:0] SCALE_FP32=32'h3DB504F3;

    parameter Q_FILE="q_after_rope.hex";
    parameter K_FILE="k_after_rope.hex";
    parameter SCORE_FILE="scores_before_mask.hex";

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
    logic [15:0] expected_scores[0:TOTAL-1];
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
        q_vec_bf16='0;
        k_vec_bf16='0;
        for (lane=0;lane<TILE;lane=lane+1) begin
            q_vec_bf16[lane*16 +:16]=q_mem[req_head*SEQ_LEN*HEAD_DIM+
                (req_row_base+lane)*HEAD_DIM+req_dim];
            k_vec_bf16[lane*16 +:16]=k_mem[(req_col_base+lane)*HEAD_DIM+req_dim];
        end
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            ready_count<=0;
            row_ready<=0;
        end else begin
            ready_count<=ready_count+1;
            row_ready<=((ready_count%17)!=5)&&((ready_count%23)!=11);
        end
    end

    always_ff @(posedge clk) begin
        integer eh,er,ec;
        logic [15:0] expected_data;
        if(!rst_n) begin
            recv_count<=0;
            global_last_count<=0;
            qk_done_count<=0;
        end else begin
            if(qk_done) qk_done_count<=qk_done_count+1;
            if(row_valid&&row_ready) begin
                eh=recv_count/(SEQ_LEN*SEQ_LEN);
                er=(recv_count/SEQ_LEN)%SEQ_LEN;
                ec=recv_count%SEQ_LEN;
                expected_data=(ec>er)?16'hFF80:expected_scores[recv_count];
                if(row_head!==eh[HEAD_W-1:0]||row_index!==er[POS_W-1:0]||
                   row_col!==ec[POS_W-1:0])
                    $fatal(1,"Full real-QK metadata mismatch index=%0d",recv_count);
                if(row_data!==expected_data||row_mask!==(ec>er))
                    $fatal(1,"Full real-QK data mismatch index=%0d expected=%h actual=%h",
                           recv_count,expected_data,row_data);
                if(row_first!==(ec==0)||row_last!==(ec==SEQ_LEN-1))
                    $fatal(1,"Full real-QK row marker mismatch index=%0d",recv_count);
                if(row_global_last) global_last_count<=global_last_count+1;
                recv_count<=recv_count+1;
            end
        end
    end

    initial begin
        $readmemh(Q_FILE,q_mem);
        $readmemh(K_FILE,k_mem);
        $readmemh(SCORE_FILE,expected_scores);
        rst_n=0;
        start=0;
        repeat(8) @(posedge clk);
        @(negedge clk) rst_n=1;
        repeat(3) @(posedge clk);
        @(negedge clk) start=1;
        @(negedge clk) start=0;
        wait(recv_count==TOTAL);
        repeat(10) @(posedge clk);
        if(qk_busy) $fatal(1,"Full QK remained busy");
        if(qk_done_count!=1) $fatal(1,"Expected one qk_done, got %0d",qk_done_count);
        if(protocol_error||global_last_error) $fatal(1,"Adapter error flag in full real-QK test");
        if(global_last_count!=1) $fatal(1,"Expected one row_global_last, got %0d",global_last_count);
        $display("PASS: OPTIONAL full real QK -> Adapter integration, outputs=%0d",recv_count);
        $finish;
    end

    initial begin
        #500000000;
        $fatal(1,"Timeout: optional full real-QK integration");
    end
endmodule
