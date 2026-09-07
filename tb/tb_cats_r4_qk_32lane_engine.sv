module tb_cats_r4_qk_32lane_engine;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, clear=0, counter_clear=0;
    logic start_valid, start_ready;
    logic [15:0] start_epoch; logic [2:0] start_group; logic [4:0] start_global_q_head;
    logic [2:0] start_row_window; logic [4:0] start_row_count; logic [1:0] start_key_block;
    logic done_valid, done_ready;
    logic [15:0] done_epoch; logic [2:0] done_group; logic [4:0] done_global_q_head;
    logic [2:0] done_row_window; logic [1:0] done_key_block; logic done_error;

    logic q_req_valid,q_req_ready; logic [3:0] q_req_context_tag; logic [6:0] q_req_d;
    logic q_rsp_valid; logic [3:0] q_rsp_context_tag; logic [15:0] q_rsp_bf16;
    logic k_req_valid,k_req_ready; logic [3:0] k_req_context_tag; logic [1:0] k_req_key_block;
    logic [6:0] k_req_d; logic k_rsp_valid; logic [3:0] k_rsp_context_tag;
    logic [511:0] k_rsp_vec;

    logic score_valid,score_ready; logic [15:0] score_epoch; logic [2:0] score_group;
    logic [4:0] score_global_q_head; logic [6:0] score_row; logic [1:0] score_key_block;
    logic [3:0] score_context_tag; logic [31:0] score_lane_valid; logic [1023:0] score_fp32;

    logic [63:0] q_requests_accepted,k_requests_accepted,mac_steps_issued,mac_steps_completed;
    logic [63:0] valid_macs,causal_lane_bubbles,causal_rows_skipped;
    logic [63:0] memory_request_stalls,mac_issue_stalls,scheduler_protocol_errors;
    logic scheduler_protocol_error_sticky;
    logic [63:0] fp32_requests_accepted,fp32_mul_products_completed,fp32_add_results_completed;
    logic [63:0] fp32_response_transfers,fp32_protocol_errors;
    logic fp32_protocol_error_sticky;
    logic [63:0] score_commits,score_commit_stalls,score_fifo_max_occupancy;

    cats_r4_qk_32lane_engine #(.HEAD_DIM(8)) dut (.*);

    logic [1:0] q_pipe_valid,k_pipe_valid;
    logic [3:0] q_pipe_context[0:1],k_pipe_context[0:1];
    logic [6:0] q_pipe_d[0:1],k_pipe_d[0:1];
    logic [1:0] k_pipe_block[0:1];
    logic [31:0] lfsr=32'h13579bdf;
    assign q_req_ready=1'b1;
    assign k_req_ready=1'b1;

    task automatic tick; @(posedge clk); #1; endtask

    always_ff @(posedge clk) begin : p_memory_model
        integer i;
        if (!rst_n || clear) begin
            q_pipe_valid <= '0; k_pipe_valid <= '0;
            q_rsp_valid <= 0; k_rsp_valid <= 0;
            q_rsp_context_tag <= 0; q_rsp_bf16 <= 0;
            k_rsp_context_tag <= 0; k_rsp_vec <= 0;
            q_pipe_context[0] <= 0; q_pipe_context[1] <= 0;
            k_pipe_context[0] <= 0; k_pipe_context[1] <= 0;
            q_pipe_d[0] <= 0; q_pipe_d[1] <= 0;
            k_pipe_d[0] <= 0; k_pipe_d[1] <= 0;
            k_pipe_block[0] <= 0; k_pipe_block[1] <= 0;
            lfsr <= 32'h13579bdf;
        end else begin
            lfsr <= {lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            q_rsp_valid <= q_pipe_valid[1];
            q_rsp_context_tag <= q_pipe_context[1];
            q_rsp_bf16 <= 16'h3f80;
            q_pipe_valid[1] <= q_pipe_valid[0];
            q_pipe_context[1] <= q_pipe_context[0];
            q_pipe_d[1] <= q_pipe_d[0];
            q_pipe_valid[0] <= q_req_valid && q_req_ready;
            q_pipe_context[0] <= q_req_context_tag;
            q_pipe_d[0] <= q_req_d;

            k_rsp_valid <= k_pipe_valid[1];
            k_rsp_context_tag <= k_pipe_context[1];
            k_rsp_vec <= '0;
            for (i=0;i<32;i=i+1)
                k_rsp_vec[i*16 +: 16] <= 16'h3f80;
            k_pipe_valid[1] <= k_pipe_valid[0];
            k_pipe_context[1] <= k_pipe_context[0];
            k_pipe_d[1] <= k_pipe_d[0];
            k_pipe_block[1] <= k_pipe_block[0];
            k_pipe_valid[0] <= k_req_valid && k_req_ready;
            k_pipe_context[0] <= k_req_context_tag;
            k_pipe_d[0] <= k_req_d;
            k_pipe_block[0] <= k_req_key_block;
        end
    end

    initial begin
        start_valid=0; start_epoch=16'h55; start_group=0; start_global_q_head=0;
        start_row_window=0; start_row_count=16; start_key_block=0;
        done_ready=1; score_ready=0;
        repeat(5) tick(); rst_n=1; repeat(2) tick();
        while(!start_ready) tick();
        @(negedge clk); start_valid=1; @(negedge clk); start_valid=0;

        while(!done_valid) begin
            tick();
            if (score_valid) begin
                if (score_ready) $fatal(1,"score unexpectedly ready before done");
                if (score_epoch!==16'h55 || score_group!==0 ||
                    score_global_q_head!==0 || score_key_block!==0)
                    $fatal(1,"score tag mismatch while filling FIFO");
            end
        end

        if (done_error || scheduler_protocol_error_sticky ||
            fp32_protocol_error_sticky || scheduler_protocol_errors!=0 ||
            fp32_protocol_errors!=0)
            $fatal(1,"protocol error in integrated engine");
        if (q_requests_accepted!==128 || k_requests_accepted!==128 ||
            mac_steps_issued!==128 || mac_steps_completed!==128)
            $fatal(1,"scheduler counters mismatch q=%0d k=%0d i=%0d r=%0d",
                   q_requests_accepted,k_requests_accepted,
                   mac_steps_issued,mac_steps_completed);
        if (valid_macs!==1088 || causal_lane_bubbles!==3008)
            $fatal(1,"causal counters mismatch valid=%0d bubbles=%0d",
                   valid_macs,causal_lane_bubbles);
        if (fp32_requests_accepted!==128 ||
            fp32_mul_products_completed!==1088 ||
            fp32_add_results_completed!==1088 ||
            fp32_response_transfers!==128)
            $fatal(1,"FP32 counters mismatch req=%0d mul=%0d add=%0d rsp=%0d",
                   fp32_requests_accepted,fp32_mul_products_completed,
                   fp32_add_results_completed,fp32_response_transfers);
        if (score_commits!==16 || score_fifo_max_occupancy!==16)
            $fatal(1,"score FIFO counters mismatch commits=%0d max=%0d",
                   score_commits,score_fifo_max_occupancy);

        score_ready=1;
        for (integer row=0; row<16; row=row+1) begin
            while(!score_valid) tick();
            if (score_context_tag!==row[3:0] || score_row!==row[6:0])
                $fatal(1,"score order mismatch exp row=%0d got ctx=%0d row=%0d",
                       row,score_context_tag,score_row);
            if (score_lane_valid !== ((32'h1 << (row+1))-1))
                $fatal(1,"score lane mask mismatch row=%0d mask=%h",row,score_lane_valid);
            for (integer lane=0; lane<32; lane=lane+1)
                if (score_lane_valid[lane] &&
                    score_fp32[lane*32 +: 32]!==32'h41000000)
                    $fatal(1,"score value mismatch row=%0d lane=%0d val=%h",
                           row,lane,score_fp32[lane*32 +: 32]);
            tick();
        end
        if (score_valid) $fatal(1,"score FIFO did not drain");
        $display("PASS: CATS-R4 integrated scheduler/FP32 service/score FIFO");
        $finish;
    end
endmodule