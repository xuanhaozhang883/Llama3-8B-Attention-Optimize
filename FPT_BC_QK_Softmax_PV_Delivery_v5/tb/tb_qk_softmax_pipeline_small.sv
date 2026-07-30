`timescale 1ns/1ps

// End-to-end small integration:
// one selected GQA group of real QK RTL -> Adapter -> Softmax frontend.
module tb_qk_softmax_pipeline_small;
    localparam int TILE=4, SEQ_LEN=8, HEAD_DIM=8, Q_HEADS=2, GQA_GROUPS=8;
    localparam int HEAD_W=1, GROUP_W=3, GLOBAL_Q_HEAD_W=4, POS_W=3, DIM_W=3;
    localparam int TOTAL=Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam logic [GROUP_W-1:0] TEST_GROUP=3'd5;
    localparam logic [31:0] SCALE_FP32=32'h3EB504F3;
    localparam real TOL_ABS=0.003;

    parameter Q_FILE="q_small_bf16.mem";
    parameter K_FILE="k_small_bf16.mem";
    parameter EXPECT_FP32_FILE="small_expected_probs_fp32.mem";
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
    logic prob_first,prob_last,prob_group_last,prob_global_last;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row,prob_col;
    logic qk_busy,qk_done,frontend_busy,pipeline_busy,group_done,pipeline_done;
    logic start_while_busy_error,invalid_group_id_error;
    logic adapter_protocol_error,adapter_global_last_error;
    logic softmax_row_error,softmax_metadata_error;

    logic [15:0] q_mem[0:Q_HEADS*SEQ_LEN*HEAD_DIM-1];
    logic [15:0] k_mem[0:SEQ_LEN*HEAD_DIM-1];
    logic [31:0] expected_fp32[0:TOTAL-1];
    integer lane,recv_count,ready_count,qk_done_count,group_done_count,row_count;
    integer fail_count;
    real max_abs_error,row_sum;

    logic hold_active;
    logic [15:0] hold_data;
    logic [GROUP_W-1:0] hold_group;
    logic [HEAD_W-1:0] hold_head;
    logic [POS_W-1:0] hold_row,hold_col;
    logic hold_first,hold_last,hold_group_last;

    qk_softmax_pipeline_top #(
        .TILE(TILE),.SEQ_LEN(SEQ_LEN),.HEAD_DIM(HEAD_DIM),.Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),.HEAD_W(HEAD_W),.GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),.POS_W(POS_W),.DIM_W(DIM_W),
        .SCALE_FP32(SCALE_FP32),.EXP_LUT_FILE(EXP_LUT_FILE)
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

    function automatic real pow2_real(input integer exponent);
        real value; integer i;
        begin
            value=1.0;
            if(exponent>=0) for(i=0;i<exponent;i=i+1) value=value*2.0;
            else for(i=0;i<(-exponent);i=i+1) value=value/2.0;
            pow2_real=value;
        end
    endfunction
    function automatic real bf16_to_real(input logic [15:0] bits);
        integer exponent,fraction; real mantissa,value;
        begin
            exponent=bits[14:7]; fraction=bits[6:0];
            if(exponent==0&&fraction==0) value=0.0;
            else if(exponent==0) begin mantissa=fraction/128.0; value=mantissa*pow2_real(-126); end
            else begin mantissa=1.0+fraction/128.0; value=mantissa*pow2_real(exponent-127); end
            bf16_to_real=bits[15]?-value:value;
        end
    endfunction
    function automatic real fp32_to_real(input logic [31:0] bits);
        integer exponent,fraction; real mantissa,value;
        begin
            exponent=bits[30:23]; fraction=bits[22:0];
            if(exponent==0&&fraction==0) value=0.0;
            else if(exponent==0) begin mantissa=fraction/8388608.0; value=mantissa*pow2_real(-126); end
            else begin mantissa=1.0+fraction/8388608.0; value=mantissa*pow2_real(exponent-127); end
            fp32_to_real=bits[31]?-value:value;
        end
    endfunction
    function automatic real abs_real(input real x); begin abs_real=(x<0.0)?-x:x; end endfunction

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

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            ready_count<=0;
            prob_ready<=0;
        end else begin
            ready_count<=ready_count+1;
            prob_ready<=((ready_count%11)!=4)&&((ready_count%17)!=9);
        end
    end

    // B->C contract: every output field must remain stable while C backpressures.
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            hold_active <= 1'b0;
        end else if(prob_valid && !prob_ready) begin
            if(hold_active) begin
                if(prob_data!==hold_data || prob_group_id!==hold_group ||
                   prob_head!==hold_head || prob_row!==hold_row || prob_col!==hold_col ||
                   prob_first!==hold_first || prob_last!==hold_last ||
                   prob_group_last!==hold_group_last)
                    $fatal(1,"B->C interface changed while prob_ready=0");
            end else begin
                hold_active     <= 1'b1;
                hold_data       <= prob_data;
                hold_group      <= prob_group_id;
                hold_head       <= prob_head;
                hold_row        <= prob_row;
                hold_col        <= prob_col;
                hold_first      <= prob_first;
                hold_last       <= prob_last;
                hold_group_last <= prob_group_last;
            end
        end else begin
            hold_active <= 1'b0;
        end
    end

    always @(posedge clk) begin
        integer eh,er,ec;
        real actual,expected,error;
        if(!rst_n) begin
            recv_count=0;
            qk_done_count=0;
            group_done_count=0;
            row_count=0;
            fail_count=0;
            max_abs_error=0.0;
            row_sum=0.0;
        end else begin
            if(qk_done) qk_done_count=qk_done_count+1;
            if(group_done) group_done_count=group_done_count+1;
            if(adapter_protocol_error||adapter_global_last_error||
               softmax_row_error||softmax_metadata_error||
               start_while_busy_error||invalid_group_id_error)
                $fatal(1,"Error flag in end-to-end small pipeline");

            if(vec_valid&&vec_ready) begin
                if(req_group_id!==TEST_GROUP || req_kv_head!==TEST_GROUP)
                    $fatal(1,"Q/K request group mismatch");
                if(req_global_q_head!==((TEST_GROUP*Q_HEADS)+req_head))
                    $fatal(1,"Global Q-head mapping mismatch");
            end

            if(prob_valid&&prob_ready) begin
                eh=recv_count/(SEQ_LEN*SEQ_LEN);
                er=(recv_count/SEQ_LEN)%SEQ_LEN;
                ec=recv_count%SEQ_LEN;
                if(prob_group_id!==TEST_GROUP || active_group_id!==TEST_GROUP)
                    $fatal(1,"Probability group mismatch index=%0d",recv_count);
                if(prob_head!==eh[HEAD_W-1:0]||prob_row!==er[POS_W-1:0]||
                   prob_col!==ec[POS_W-1:0])
                    $fatal(1,"Pipeline metadata mismatch index=%0d",recv_count);
                if(prob_first!==(ec==0)||prob_last!==(ec==SEQ_LEN-1))
                    $fatal(1,"Pipeline row marker mismatch index=%0d",recv_count);
                if(prob_group_last!==((eh==Q_HEADS-1)&&(er==SEQ_LEN-1)&&(ec==SEQ_LEN-1)))
                    $fatal(1,"Pipeline group-last mismatch index=%0d",recv_count);
                if(prob_global_last!==prob_group_last)
                    $fatal(1,"Compatibility last alias mismatch");
                if((ec>er)&&(prob_data!==16'h0000))
                    $fatal(1,"Pipeline masked probability nonzero index=%0d",recv_count);
                actual=bf16_to_real(prob_data);
                expected=fp32_to_real(expected_fp32[recv_count]);
                error=abs_real(actual-expected);
                if(error>max_abs_error) max_abs_error=error;
                if(error>TOL_ABS) begin
                    fail_count=fail_count+1;
                    if(fail_count<=8)
                        $display("PIPE NUM FAIL idx=%0d actual=%f expected=%f err=%f",
                                 recv_count,actual,expected,error);
                end
                row_sum=row_sum+actual;
                if(ec==SEQ_LEN-1) begin
                    if(abs_real(row_sum-1.0)>0.02)
                        $fatal(1,"Pipeline row sum=%f h=%0d r=%0d",row_sum,eh,er);
                    row_sum=0.0;
                    row_count=row_count+1;
                end
                recv_count=recv_count+1;
            end
        end
    end

    initial begin
        $readmemh(Q_FILE,q_mem);
        $readmemh(K_FILE,k_mem);
        $readmemh(EXPECT_FP32_FILE,expected_fp32);
        rst_n=0;
        group_start=0;
        group_id=TEST_GROUP;
        causal_en=1;
        repeat(6) @(posedge clk);
        @(negedge clk) rst_n=1;
        repeat(3) @(posedge clk);
        if(!group_start_ready) $fatal(1,"group_start_ready must be high while idle");
        @(negedge clk) group_start=1;
        @(negedge clk) group_start=0;
        wait(recv_count==TOTAL);
        repeat(8) @(posedge clk);
        if(fail_count!=0) $fatal(1,"End-to-end small numerical failures=%0d",fail_count);
        if(qk_done_count!=1) $fatal(1,"Expected one qk_done, got %0d",qk_done_count);
        if(group_done_count!=1) $fatal(1,"Expected one group_done, got %0d",group_done_count);
        if(row_count!=Q_HEADS*SEQ_LEN) $fatal(1,"Expected %0d rows, got %0d",Q_HEADS*SEQ_LEN,row_count);
        if(pipeline_busy) $fatal(1,"Pipeline remained busy after final output");
        if(pipeline_done!==group_done) $fatal(1,"Compatibility done alias mismatch");
        $display("PASS: selected-group real QK -> Adapter -> Softmax small pipeline");
        $display("group=%0d outputs=%0d rows=%0d max_abs_error=%f",TEST_GROUP,recv_count,row_count,max_abs_error);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1,"Timeout: end-to-end small pipeline");
    end
endmodule
