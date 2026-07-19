`timescale 1ns/1ps

// Complete Adapter -> Softmax golden test, fixed project configuration.
module tb_qk_softmax_frontend_golden;
    localparam int SEQ_LEN=128, TILE=4, Q_HEADS=4, HEAD_W=2, POS_W=7;
    localparam int TOTAL=Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam real TOL_ABS=0.0021;
    localparam real ROW_SUM_TOL=0.01;
    parameter INPUT_FILE="qk_scores_tile_order.mem";
    parameter EXPECT_BF16_FILE="full_expected_probs_bf16.mem";
    parameter EXPECT_FP32_FILE="full_expected_probs_fp32.mem";
    parameter EXP_LUT_FILE="exp_lut_q15.mem";

    logic clk=0; always #5 clk=~clk;
    logic rst_n;
    logic qk_valid,qk_ready;
    logic [15:0] qk_score;
    logic [HEAD_W-1:0] qk_head;
    logic [POS_W-1:0] qk_row,qk_col;
    logic qk_global_last;
    logic prob_valid,prob_ready;
    logic [15:0] prob_data;
    logic prob_first,prob_last,prob_global_last,pipeline_done;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row,prob_col;
    logic busy,adapter_protocol_error,adapter_global_last_error;
    logic softmax_row_error,softmax_metadata_error;

    logic [32:0] input_mem[0:TOTAL-1];
    logic [15:0] expected_bf16[0:TOTAL-1];
    logic [31:0] expected_fp32[0:TOTAL-1];
    integer send_count,recv_count,ready_count,fail_count,exact_mismatch_count;
    integer row_count,pipeline_done_count;
    real max_abs_error,mean_abs_error,row_sum;

    qk_softmax_frontend #(
        .SEQ_LEN(SEQ_LEN),.TILE(TILE),.Q_HEADS(Q_HEADS),
        .HEAD_W(HEAD_W),.POS_W(POS_W),.EXP_LUT_FILE(EXP_LUT_FILE)
    ) dut (
        .clk,.rst_n,.causal_en(1'b1),
        .qk_valid,.qk_ready,.qk_score,.qk_head,.qk_row,.qk_col,.qk_global_last,
        .prob_valid,.prob_ready,.prob_data,.prob_first,.prob_last,
        .prob_global_last,.prob_head,.prob_row,.prob_col,.pipeline_done,
        .busy,.adapter_protocol_error,.adapter_global_last_error,
        .softmax_row_error,.softmax_metadata_error
    );

    function automatic real pow2_real(input integer exponent);
        real v; integer i;
        begin
            v=1.0;
            if(exponent>=0) for(i=0;i<exponent;i=i+1) v=v*2.0;
            else for(i=0;i<(-exponent);i=i+1) v=v/2.0;
            pow2_real=v;
        end
    endfunction
    function automatic real bf16_to_real(input logic [15:0] b);
        integer e,f; real m,v;
        begin
            e=b[14:7]; f=b[6:0];
            if(e==0&&f==0) v=0.0;
            else if(e==0) begin m=f/128.0; v=m*pow2_real(-126); end
            else if(e==255) v=1.0e30;
            else begin m=1.0+f/128.0; v=m*pow2_real(e-127); end
            bf16_to_real=b[15] ? -v : v;
        end
    endfunction
    function automatic real fp32_to_real(input logic [31:0] b);
        integer e,f; real m,v;
        begin
            e=b[30:23]; f=b[22:0];
            if(e==0&&f==0) v=0.0;
            else if(e==0) begin m=f/8388608.0; v=m*pow2_real(-126); end
            else if(e==255) v=1.0e30;
            else begin m=1.0+f/8388608.0; v=m*pow2_real(e-127); end
            fp32_to_real=b[31] ? -v : v;
        end
    endfunction
    function automatic real abs_real(input real x); begin abs_real=(x<0.0)?-x:x; end endfunction

    always_ff @(posedge clk) begin
        if(!rst_n) begin ready_count<=0; prob_ready<=0; end
        else begin
            ready_count<=ready_count+1;
            prob_ready<=((ready_count%13)!=4)&&((ready_count%13)!=5)&&((ready_count%19)!=8);
        end
    end

    always @(posedge clk) begin
        integer eh,er,ec;
        real actual_r,expected_r,err;
        if(!rst_n) begin
            recv_count=0; fail_count=0; exact_mismatch_count=0;
            row_count=0; pipeline_done_count=0;
            max_abs_error=0.0; mean_abs_error=0.0; row_sum=0.0;
        end else begin
            if(adapter_protocol_error) $fatal(1,"adapter_protocol_error");
            if(adapter_global_last_error) $fatal(1,"adapter_global_last_error");
            if(softmax_row_error) $fatal(1,"Unexpected all-masked row");
            if(softmax_metadata_error) $fatal(1,"softmax_metadata_error");

            if(prob_valid&&prob_ready) begin
                eh=recv_count/(SEQ_LEN*SEQ_LEN);
                er=(recv_count/SEQ_LEN)%SEQ_LEN;
                ec=recv_count%SEQ_LEN;
                if((prob_head!==eh[HEAD_W-1:0])||(prob_row!==er[POS_W-1:0])||
                   (prob_col!==ec[POS_W-1:0]))
                    $fatal(1,"Probability metadata mismatch index=%0d",recv_count);
                if(prob_first!==(ec==0)) $fatal(1,"prob_first mismatch");
                if(prob_last!==(ec==SEQ_LEN-1)) $fatal(1,"prob_last mismatch");
                if(prob_global_last!==((eh==Q_HEADS-1)&&(er==SEQ_LEN-1)&&(ec==SEQ_LEN-1)))
                    $fatal(1,"prob_global_last mismatch");
                if((ec>er)&&(prob_data!==16'h0000))
                    $fatal(1,"Masked probability is nonzero h=%0d r=%0d c=%0d data=%h",eh,er,ec,prob_data);

                actual_r=bf16_to_real(prob_data);
                expected_r=fp32_to_real(expected_fp32[recv_count]);
                err=abs_real(actual_r-expected_r);
                mean_abs_error=mean_abs_error+err;
                if(err>max_abs_error) max_abs_error=err;
                if(err>TOL_ABS) begin
                    fail_count=fail_count+1;
                    if(fail_count<=10)
                        $display("NUM FAIL idx=%0d h=%0d r=%0d c=%0d actual=%f expected=%f err=%f",
                                 recv_count,eh,er,ec,actual_r,expected_r,err);
                end
                if(prob_data!==expected_bf16[recv_count]) exact_mismatch_count=exact_mismatch_count+1;
                row_sum=row_sum+actual_r;
                if(ec==SEQ_LEN-1) begin
                    if(abs_real(row_sum-1.0)>ROW_SUM_TOL)
                        $fatal(1,"Row sum out of tolerance h=%0d r=%0d sum=%f",eh,er,row_sum);
                    row_sum=0.0; row_count=row_count+1;
                end
                if(pipeline_done) pipeline_done_count=pipeline_done_count+1;
                recv_count=recv_count+1;
            end
        end
    end

    initial begin
        $readmemh(INPUT_FILE,input_mem);
        $readmemh(EXPECT_BF16_FILE,expected_bf16);
        $readmemh(EXPECT_FP32_FILE,expected_fp32);
        rst_n=0; qk_valid=0; qk_score=0; qk_head=0; qk_row=0; qk_col=0;
        qk_global_last=0; send_count=0;
        repeat(6) @(posedge clk); @(negedge clk) rst_n=1;
        while(send_count<TOTAL) begin
            @(negedge clk);
            qk_valid=1;
            qk_score=input_mem[send_count][15:0];
            qk_col=input_mem[send_count][22:16];
            qk_row=input_mem[send_count][29:23];
            qk_head=input_mem[send_count][31:30];
            qk_global_last=input_mem[send_count][32];
            do @(posedge clk); while(!qk_ready);
            send_count=send_count+1;
        end
        @(negedge clk); qk_valid=0; qk_global_last=0;
        wait(recv_count==TOTAL); repeat(5) @(posedge clk);
        if(fail_count!=0) $fatal(1,"Full frontend numerical failures=%0d",fail_count);
        if(row_count!=Q_HEADS*SEQ_LEN) $fatal(1,"Expected 512 rows, got %0d",row_count);
        if(pipeline_done_count!=1) $fatal(1,"Expected one pipeline_done, got %0d",pipeline_done_count);
        $display("PASS: full Adapter -> Softmax golden test");
        $display("outputs=%0d rows=%0d exact_bf16_mismatches=%0d",recv_count,row_count,exact_mismatch_count);
        $display("max_abs_error=%f mean_abs_error=%f",max_abs_error,mean_abs_error/TOTAL);
        $finish;
    end

    initial begin #50000000; $fatal(1,"Timeout: full frontend golden test"); end
endmodule
