`timescale 1ns/1ps

module tb_cats_r4_b2_accuracy_v3_wrapper;
    logic clk=0, rst_n=0, clear=0, counter_clear=0;
    logic row_valid=0, row_ready;
    logic [15:0] row_epoch=0;
    logic [2:0] row_group=0;
    logic [4:0] row_global_q_head=0;
    logic [6:0] row_index=0;
    logic [1:0] row_slot_id=0, row_numeric_mode=0;
    logic [15:0] row_max_bf16=0;
    logic score_valid=0, score_ready;
    logic [15:0] score_epoch=0;
    logic [2:0] score_group=0;
    logic [4:0] score_global_q_head=0;
    logic [6:0] score_row=0;
    logic [1:0] score_slot_id=0, score_numeric_mode=0;
    logic [6:0] score_key=0;
    logic [15:0] score_bf16=0;
    logic score_last=0;
    logic weight_wr_valid, weight_wr_ready=0;
    logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group;
    logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row;
    logic [1:0] weight_wr_slot_id, weight_wr_numeric_mode;
    logic [6:0] weight_wr_key;
    logic weight_wr_mask;
    logic [31:0] weight_wr_data;
    logic weight_wr_last;
    logic row_commit_valid, row_commit_ready=0;
    logic [15:0] row_commit_epoch;
    logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head;
    logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id, row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32, row_commit_inv_sum_fp32;
    logic row_error_valid, row_error_ready=0;
    logic [15:0] row_error_epoch;
    logic [2:0] row_error_group;
    logic [4:0] row_error_global_q_head;
    logic [6:0] row_error_row;
    logic [1:0] row_error_slot_id, row_error_numeric_mode;
    logic [3:0] row_error_code;
    logic [6:0] row_error_bad_key;
    logic slot_release_valid=0, slot_release_ready;
    logic [15:0] slot_release_epoch=0;
    logic [2:0] slot_release_group=0;
    logic [4:0] slot_release_global_q_head=0;
    logic [6:0] slot_release_row=0;
    logic [1:0] slot_release_slot_id=0, slot_release_numeric_mode=0;
    logic [63:0] rows_issue, rows_result;
    logic [63:0] exp_issue, exp_result, exp_commit;
    logic [63:0] sum_issue, sum_result, sum_commit;
    logic [63:0] reciprocal_issue, reciprocal_result, reciprocal_commit;
    logic [63:0] staged_weight_accept, weight_wr_accept;
    logic [63:0] row_commit_count, slot_release_count;
    logic [63:0] protocol_error_count, numeric_error_count;
    logic [63:0] owner_error_count, mask_error_count, output_stall_cycles;
    logic [63:0] exp_stall_cycles, sum_stall_cycles;
    logic [63:0] reciprocal_busy_stall_cycles;
    logic [63:0] reciprocal_output_stall_cycles;
    logic error_sticky;

    integer write_count=0, commit_count=0, error_count=0, ready_cycle=0;
    logic [31:0] expected_sum [0:2];
    logic [31:0] expected_inv [0:2];

    always #5 clk=~clk;
    cats_r4_b2_accuracy_v3_wrapper dut (.*);

    initial begin
        repeat (50000) @(posedge clk);
        $fatal(1,"timeout writes=%0d commits=%0d errors=%0d",write_count,commit_count,error_count);
    end

    always @(negedge clk) begin
        ready_cycle=ready_cycle+1;
        weight_wr_ready=(ready_cycle%5)!=0;
        row_commit_ready=(ready_cycle%7)!=0;
        row_error_ready=(ready_cycle%11)!=0;
    end

    function automatic logic [31:0] expected_weight(
        input integer block,
        input integer key
    );
        begin
            expected_weight=0;
            case (block)
                0: if (key==0) expected_weight=32'h3F800000;
                1: if (key<=1) expected_weight=32'h3F800000;
                2: case (key)
                    0: expected_weight=32'h3F800000;
                    1: expected_weight=32'h3EBC5C7D;
                    2: expected_weight=32'h39016AF8;
                    3: expected_weight=32'h00000000;
                    default: expected_weight=0;
                endcase
            endcase
        end
    endfunction

    always @(posedge clk) begin
        integer block;
        integer key;
        integer causal_last;
        if (rst_n && !clear && weight_wr_valid && weight_wr_ready) begin
            block=write_count/128;
            key=write_count%128;
            causal_last=(block==0)?0:((block==1)?1:3);
            if (block>=3 || weight_wr_slot_id!=block[1:0] ||
                weight_wr_key!=key[6:0] ||
                weight_wr_numeric_mode!=2'd1 ||
                weight_wr_mask!=(key>causal_last) ||
                weight_wr_data!=expected_weight(block,key) ||
                weight_wr_last!=(key==127))
                $fatal(1,
                    "publish mismatch write=%0d block=%0d key=%0d slot=%0d mask=%0d data=%h last=%0d",
                    write_count,block,key,weight_wr_slot_id,
                    weight_wr_mask,weight_wr_data,weight_wr_last);
            write_count=write_count+1;
        end
        if (rst_n && !clear && row_commit_valid && row_commit_ready) begin
            if (commit_count>=3 || row_commit_slot_id!=commit_count[1:0] ||
                row_commit_numeric_mode!=2'd1 ||
                row_commit_sum_fp32!=expected_sum[commit_count] ||
                row_commit_inv_sum_fp32!=expected_inv[commit_count])
                $fatal(1,
                    "commit mismatch count=%0d slot=%0d sum=%h inv=%h",
                    commit_count,row_commit_slot_id,row_commit_sum_fp32,
                    row_commit_inv_sum_fp32);
            commit_count=commit_count+1;
        end
        if (rst_n && !clear && row_error_valid && row_error_ready) begin
            if (error_count>=2 || row_error_slot_id!=error_count[1:0] ||
                row_error_numeric_mode!=2'd1 || row_error_code==0)
                $fatal(1,"row error mismatch count=%0d slot=%0d code=%0d",
                    error_count,row_error_slot_id,row_error_code);
            error_count=error_count+1;
        end
    end

    task automatic send_row(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [15:0] maximum
    );
        begin
            @(negedge clk);
            row_valid=1'b1;
            row_epoch=epoch;
            row_group=head[4:2];
            row_global_q_head=head;
            row_index=row;
            row_slot_id=slot;
            row_numeric_mode=2'd1;
            row_max_bf16=maximum;
            do @(posedge clk); while (!row_ready);
            @(negedge clk);
            row_valid=1'b0;
        end
    endtask

    task automatic send_release(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot
    );
        begin
            @(negedge clk);
            slot_release_valid=1'b1;
            slot_release_epoch=epoch;
            slot_release_group=head[4:2];
            slot_release_global_q_head=head;
            slot_release_row=row;
            slot_release_slot_id=slot;
            slot_release_numeric_mode=2'd1;
            do @(posedge clk); while (!slot_release_ready);
            @(negedge clk);
            slot_release_valid=1'b0;
        end
    endtask

    task automatic send_score(
        input logic [15:0] epoch,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot,
        input logic [6:0] key,
        input logic [15:0] score,
        input logic last
    );
        begin
            @(negedge clk);
            score_valid=1'b1;
            score_epoch=epoch;
            score_group=head[4:2];
            score_global_q_head=head;
            score_row=row;
            score_slot_id=slot;
            score_numeric_mode=2'd1;
            score_key=key;
            score_bf16=score;
            score_last=last;
            do @(posedge clk); while (!score_ready);
            @(negedge clk);
            score_valid=1'b0;
        end
    endtask

    initial begin
        expected_sum[0]=32'h3F800000;
        expected_inv[0]=32'h3F800000;
        expected_sum[1]=32'h40000000;
        expected_inv[1]=32'h3F000000;
        expected_sum[2]=32'h3FAF1B2A;
        expected_inv[2]=32'h3F3B21DB;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n=1'b1;

        send_row(16'h10,5'd0,7'd0,2'd0,16'h0000);
        send_row(16'h10,5'd1,7'd1,2'd1,16'h3F80);
        send_row(16'h10,5'd2,7'd3,2'd2,16'h0000);
        send_score(16'h10,5'd0,7'd0,2'd0,7'd0,16'h0000,1'b1);
        send_score(16'h10,5'd1,7'd1,2'd1,7'd0,16'h3F80,1'b0);
        send_score(16'h10,5'd1,7'd1,2'd1,7'd1,16'h3F80,1'b1);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd0,16'h0000,1'b0);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd1,16'hBF80,1'b0);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd2,16'hC110,1'b0);
        send_score(16'h10,5'd2,7'd3,2'd2,7'd3,16'hC2D0,1'b1);
        wait (commit_count==3);
        if (write_count!=384)
            $fatal(1,"normal rows did not publish 384 writes: %0d",write_count);

        send_release(16'h10,5'd0,7'd0,2'd0);
        send_release(16'h10,5'd1,7'd1,2'd1);
        send_release(16'h10,5'd2,7'd3,2'd2);

        // Wrong first last is drained, finalized as an error, and publishes
        // no C weight writes or normal commit.
        send_row(16'h20,5'd0,7'd1,2'd0,16'h0000);
        send_score(16'h20,5'd0,7'd1,2'd0,7'd0,16'h0000,1'b1);
        send_score(16'h20,5'd0,7'd1,2'd0,7'd1,16'h0000,1'b1);
        wait (error_count==1);
        if (write_count!=384 || commit_count!=3)
            $fatal(1,"protocol-error row leaked to C");
        send_release(16'h20,5'd0,7'd1,2'd0);

        // A non-finite row is also contained before the first C write.
        send_row(16'h30,5'd1,7'd0,2'd1,16'h7F80);
        send_score(16'h30,5'd1,7'd0,2'd1,7'd0,16'h7F80,1'b1);
        wait (error_count==2);
        if (write_count!=384 || commit_count!=3)
            $fatal(1,"numeric-error row leaked to C");
        send_release(16'h30,5'd1,7'd0,2'd1);

        repeat (4) @(posedge clk);
        if (rows_issue!=5 || rows_result!=5 ||
            exp_issue!=10 || exp_result!=10 || exp_commit!=10 ||
            sum_issue!=10 || sum_result!=10 || sum_commit!=10 ||
            reciprocal_issue!=5 || reciprocal_result!=5 ||
            reciprocal_commit!=5 || staged_weight_accept!=10 ||
            weight_wr_accept!=384 || row_commit_count!=3 ||
            slot_release_count!=5 || protocol_error_count!=1 ||
            numeric_error_count!=5 || owner_error_count!=0 ||
            mask_error_count!=0 || !error_sticky)
            $fatal(1,
                "counter mismatch rows=%0d/%0d exp=%0d/%0d/%0d sum=%0d/%0d/%0d recip=%0d/%0d/%0d staged=%0d writes=%0d commits=%0d releases=%0d protocol=%0d numeric=%0d",
                rows_issue,rows_result,exp_issue,exp_result,exp_commit,
                sum_issue,sum_result,sum_commit,reciprocal_issue,
                reciprocal_result,reciprocal_commit,staged_weight_accept,
                weight_wr_accept,row_commit_count,slot_release_count,
                protocol_error_count,numeric_error_count);

        $display(
            "CATS-R4 Accuracy V3 staged PASS rows=%0d exp=%0d staged=%0d writes=%0d commits=%0d errors=%0d releases=%0d",
            rows_issue,exp_commit,staged_weight_accept,weight_wr_accept,
            row_commit_count,error_count,slot_release_count
        );
        $finish;
    end
endmodule
