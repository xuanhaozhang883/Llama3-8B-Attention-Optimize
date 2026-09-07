module tb_cats_r4_qk_32lane_fp32_service;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, clear=0;
    logic req_valid, req_ready;
    logic [15:0] req_epoch; logic [2:0] req_group; logic [4:0] req_global_q_head;
    logic [6:0] req_row; logic [1:0] req_key_block; logic [3:0] req_context_tag;
    logic [6:0] req_d; logic [31:0] req_lane_valid;
    logic req_first, req_last; logic [15:0] req_q_bf16; logic [511:0] req_k_vec;
    logic rsp_valid, rsp_ready; logic [15:0] rsp_epoch; logic [2:0] rsp_group;
    logic [4:0] rsp_global_q_head; logic [6:0] rsp_row; logic [1:0] rsp_key_block;
    logic [3:0] rsp_context_tag; logic [6:0] rsp_d; logic rsp_score_valid;
    logic [31:0] rsp_lane_valid; logic [1023:0] rsp_score_fp32;
    logic [63:0] requests_accepted, mul_products_completed, add_results_completed;
    logic [63:0] response_transfers, protocol_errors; logic protocol_error_sticky;

    cats_r4_qk_32lane_fp32_service #(.HEAD_DIM(8)) dut (.*);

    task automatic tick; @(posedge clk); #1; endtask

    task automatic send_step(input logic [3:0] ctx, input integer d_value,
                              input logic last_value);
        integer lane;
        begin
            while (!req_ready) tick();
            @(negedge clk);
            req_valid=1;
            req_epoch=16'h22; req_group=3'd0; req_global_q_head=5'd0;
            req_row=7'd3; req_key_block=2'd0; req_context_tag=ctx;
            req_d=d_value[6:0]; req_lane_valid=32'h00000003;
            req_first=(d_value==0); req_last=last_value;
            req_q_bf16=16'h3f80; req_k_vec='0;
            req_k_vec[0 +: 16]=16'h3f80;
            req_k_vec[16 +: 16]=16'h3f80;
            @(negedge clk); req_valid=0;
            while (!rsp_valid) tick();
            if (rsp_epoch!==16'h22 || rsp_context_tag!==ctx ||
                rsp_d!==d_value[6:0] || rsp_lane_valid!==32'h3)
                $fatal(1,"response tag mismatch ctx=%0d d=%0d",ctx,d_value);
            if (rsp_score_valid !== last_value)
                $fatal(1,"score_valid mismatch d=%0d",d_value);
            if (last_value) begin
                if (rsp_score_fp32[31:0]!==32'h41000000 ||
                    rsp_score_fp32[63:32]!==32'h41000000)
                    $fatal(1,"score accumulation mismatch %h %h",
                           rsp_score_fp32[31:0],rsp_score_fp32[63:32]);
                if (rsp_score_fp32[95:64]!==32'd0)
                    $fatal(1,"inactive lane score not zero");
            end
            rsp_ready=0;
            tick();
            if (!rsp_valid) $fatal(1,"response did not hold under backpressure");
            rsp_ready=1;
            tick();
            rsp_ready=0;
        end
    endtask

    initial begin
        req_valid=0; rsp_ready=0; req_epoch=0; req_group=0;
        req_global_q_head=0; req_row=0; req_key_block=0; req_context_tag=0;
        req_d=0; req_lane_valid=0; req_first=0; req_last=0;
        req_q_bf16=0; req_k_vec=0;
        repeat(4) tick(); rst_n=1; repeat(2) tick();

        for (integer d=0; d<8; d=d+1)
            send_step(4'd0,d,(d==7));
        for (integer d=0; d<8; d=d+1)
            send_step(4'd1,d,(d==7));

        if (requests_accepted!==16 || mul_products_completed!==32 ||
            add_results_completed!==32 || response_transfers!==16 ||
            protocol_errors!==0 || protocol_error_sticky)
            $fatal(1,"counter mismatch req=%0d mul=%0d add=%0d rsp=%0d err=%0d",
                   requests_accepted,mul_products_completed,
                   add_results_completed,response_transfers,protocol_errors);
        $display("PASS: CATS-R4 32-lane FP32 accumulator context isolation and score commit");
        $finish;
    end
endmodule