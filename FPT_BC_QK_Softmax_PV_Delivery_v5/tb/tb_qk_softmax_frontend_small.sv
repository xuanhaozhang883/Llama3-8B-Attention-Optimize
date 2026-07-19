`timescale 1ns/1ps

module tb_qk_softmax_frontend_small;
    localparam int SEQ_LEN=8,TILE=4,Q_HEADS=2,HEAD_W=1,POS_W=3;
    localparam int TOTAL=Q_HEADS*SEQ_LEN*SEQ_LEN;
    parameter EXP_LUT_FILE="exp_lut_q15.mem";
    logic clk=0; always #5 clk=~clk;
    logic rst_n,qk_valid,qk_ready,qk_global_last;
    logic [15:0] qk_score;
    logic [HEAD_W-1:0] qk_head;
    logic [POS_W-1:0] qk_row,qk_col;
    logic prob_valid,prob_ready,prob_first,prob_last,prob_global_last,pipeline_done;
    logic [15:0] prob_data;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row,prob_col;
    logic busy,adapter_protocol_error,adapter_global_last_error;
    logic softmax_row_error,softmax_metadata_error;
    integer recv_count,ready_count,done_count;
    real row_sum;

    qk_softmax_frontend #(
        .SEQ_LEN(SEQ_LEN),.TILE(TILE),.Q_HEADS(Q_HEADS),
        .HEAD_W(HEAD_W),.POS_W(POS_W),.EXP_LUT_FILE(EXP_LUT_FILE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .causal_en(1'b1),
        .qk_valid(qk_valid), .qk_ready(qk_ready), .qk_score(qk_score),
        .qk_head(qk_head), .qk_row(qk_row), .qk_col(qk_col),
        .qk_global_last(qk_global_last),
        .prob_valid(prob_valid), .prob_ready(prob_ready), .prob_data(prob_data),
        .prob_first(prob_first), .prob_last(prob_last),
        .prob_global_last(prob_global_last), .prob_head(prob_head),
        .prob_row(prob_row), .prob_col(prob_col), .pipeline_done(pipeline_done),
        .busy(busy), .adapter_protocol_error(adapter_protocol_error),
        .adapter_global_last_error(adapter_global_last_error),
        .softmax_row_error(softmax_row_error),
        .softmax_metadata_error(softmax_metadata_error)
    );

    function automatic real pow2_real(input integer exponent);
        real v; integer i;
        begin v=1.0;
            if(exponent>=0) for(i=0;i<exponent;i=i+1) v=v*2.0;
            else for(i=0;i<(-exponent);i=i+1) v=v/2.0;
            pow2_real=v;
        end
    endfunction
    function automatic real bf16_to_real(input logic [15:0] b);
        integer e,f; real m,v;
        begin e=b[14:7]; f=b[6:0];
            if(e==0&&f==0) v=0.0;
            else begin m=1.0+f/128.0; v=m*pow2_real(e-127); end
            bf16_to_real=b[15]?-v:v;
        end
    endfunction
    function automatic real abs_real(input real x); begin abs_real=(x<0.0)?-x:x; end endfunction

    always_ff @(posedge clk) begin
        if(!rst_n) begin ready_count<=0; prob_ready<=0; end
        else begin ready_count<=ready_count+1; prob_ready<=((ready_count%7)!=3); end
    end

    always @(posedge clk) begin
        integer eh,er,ec; real actual,expected;
        if(!rst_n) begin recv_count=0; done_count=0; row_sum=0.0; end
        else if(prob_valid&&prob_ready) begin
            eh=recv_count/(SEQ_LEN*SEQ_LEN); er=(recv_count/SEQ_LEN)%SEQ_LEN; ec=recv_count%SEQ_LEN;
            if(prob_head!==eh[HEAD_W-1:0]||prob_row!==er[POS_W-1:0]||prob_col!==ec[POS_W-1:0])
                $fatal(1,"small frontend metadata mismatch");
            actual=bf16_to_real(prob_data); expected=(ec<=er)?(1.0/(er+1)):0.0;
            if(abs_real(actual-expected)>0.01)
                $fatal(1,"small frontend value mismatch h=%0d r=%0d c=%0d actual=%f expected=%f",eh,er,ec,actual,expected);
            row_sum=row_sum+actual;
            if(ec==SEQ_LEN-1) begin
                if(abs_real(row_sum-1.0)>0.02) $fatal(1,"small frontend row sum=%f",row_sum);
                row_sum=0.0;
            end
            if(pipeline_done) done_count=done_count+1;
            recv_count=recv_count+1;
        end
    end

    task automatic send_one(input integer h,input integer r,input integer c,input bit glast);
        begin
            @(negedge clk); qk_valid=1; qk_score=16'h0000;
            qk_head=h[HEAD_W-1:0]; qk_row=r[POS_W-1:0]; qk_col=c[POS_W-1:0]; qk_global_last=glast;
            do @(posedge clk); while(!qk_ready);
        end
    endtask

    initial begin
        integer h,rb,cb,lr,lc,r,c;
        rst_n=0;qk_valid=0;qk_score=0;qk_head=0;qk_row=0;qk_col=0;qk_global_last=0;
        repeat(5) @(posedge clk); @(negedge clk) rst_n=1;
        for(h=0;h<Q_HEADS;h=h+1)
            for(rb=0;rb<SEQ_LEN;rb=rb+TILE)
                for(cb=0;cb<SEQ_LEN;cb=cb+TILE)
                    for(lr=0;lr<TILE;lr=lr+1)
                        for(lc=0;lc<TILE;lc=lc+1) begin
                            r=rb+lr;c=cb+lc;
                            send_one(h,r,c,(h==Q_HEADS-1)&&(r==SEQ_LEN-1)&&(c==SEQ_LEN-1));
                        end
        @(negedge clk);qk_valid=0;qk_global_last=0;
        wait(recv_count==TOTAL);repeat(4)@(posedge clk);
        if(adapter_protocol_error||adapter_global_last_error||softmax_row_error||softmax_metadata_error)
            $fatal(1,"small frontend error flag");
        if(done_count!=1) $fatal(1,"small frontend pipeline_done count=%0d",done_count);
        $display("PASS: qk_softmax_frontend small test, outputs=%0d",recv_count);
        $finish;
    end
    initial begin #5000000;$fatal(1,"Timeout: small frontend");end
endmodule
