`timescale 1ns/1ps

// Gate-2 proof: keep the dense QK/FIFO stream, but discard a fully masked
// upper-triangular tile before Online Softmax, V fetch, and Context update.
module tb_v314_causal_consumer_bypass;
    localparam int TILE=4;
    localparam int V_LANES=8;
    localparam int SEQ_LEN=8;
    localparam int HEAD_DIM=8;
    localparam int V_ADDR_W=$clog2(SEQ_LEN*HEAD_DIM);

    logic clk=1'b0, rst_n=1'b0, clear=1'b0, causal_en=1'b1;
    always #5 clk=~clk;

    logic score_valid, score_ready;
    logic [15:0] score_bf16;
    logic score_mask;
    logic [0:0] score_group, score_head;
    logic [2:0] score_row, score_col;
    logic score_last;
    logic v_load_valid, v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr;
    logic [V_LANES*16-1:0] v_load_data;
    logic context_valid, context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [0:0] context_group, context_head, context_global_head;
    logic [2:0] context_row, context_col;
    logic context_last, busy, protocol_error;
    logic [31:0] score_tiles_enqueued, score_tiles_dequeued;
    logic [31:0] softmax_tiles_processed, context_tiles_processed;
    logic [31:0] v_vectors_read, causal_tiles_bypassed;
    logic causal_protocol_error;
    integer output_count=0, cycles=0;
    integer token, row_base, col_base, local_row, local_col, lane;

    flash_attention_consumer_top #(
        .TILE(TILE), .CAUSAL_MODE(1'b1), .V_LANES(V_LANES),
        .FIFO_DEPTH_TILES(3), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(1), .GQA_GROUPS(1), .HEAD_W(1), .GROUP_W(1),
        .GLOBAL_HEAD_W(1), .POS_W(3), .DIM_W(3),
        .V_ADDR_W(V_ADDR_W), .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);

    task automatic load_v(input integer token_number);
        integer vl;
        begin
            @(negedge clk);
            v_load_addr=token_number*HEAD_DIM;
            for(vl=0;vl<V_LANES;vl=vl+1)
                v_load_data[vl*16 +: 16]=16'h3f80;
            v_load_valid=1'b1;
            do @(posedge clk); while(!v_load_ready);
            @(negedge clk); v_load_valid=1'b0;
        end
    endtask

    task automatic send_score(input integer global_row,
                              input integer global_col);
        integer active_count;
        begin
            @(negedge clk);
            score_row=global_row;
            score_col=global_col;
            score_bf16=16'h0000;
            // Keep each active row length at a power of two so the deliberately
            // tiny FP simulation mocks only see 1, 1/2, 1/4, or 1/8 weights.
            // The upper-right tile remains wholly masked and is the bypass DUT.
            if(global_row==0) active_count=1;
            else if(global_row<3) active_count=2;
            else if(global_row<7) active_count=4;
            else active_count=8;
            score_mask=(global_col>global_row) ||
                       (global_col>=active_count);
            score_last=(global_row==SEQ_LEN-1 && global_col==SEQ_LEN-1);
            score_valid=1'b1;
            do @(posedge clk); while(!score_ready);
            @(negedge clk); score_valid=1'b0;
        end
    endtask

    always @(posedge clk) begin
        if(!rst_n) begin
            context_ready<=1'b0;
            cycles<=0;
        end else begin
            cycles<=cycles+1;
            context_ready<=((cycles%7)!=0);
            if(cycles>8000) $fatal(1,"causal consumer bypass timeout");
            if(context_valid&&context_ready) begin
                if(context_bf16!==16'h3f80)
                    $fatal(1,"context mismatch idx=%0d got=%h",output_count,
                           context_bf16);
                if(context_col!==(output_count%HEAD_DIM) ||
                   context_row!==(output_count/HEAD_DIM))
                    $fatal(1,"context order mismatch idx=%0d",output_count);
                if(context_last!==(output_count==SEQ_LEN*HEAD_DIM-1))
                    $fatal(1,"context_last mismatch idx=%0d",output_count);
                output_count<=output_count+1;
            end
        end
    end

    initial begin
        score_valid=1'b0; score_bf16='0; score_mask=1'b0;
        score_group='0; score_head='0; score_row='0; score_col='0;
        score_last=1'b0; v_load_valid=1'b0; v_load_addr='0;
        v_load_data='0;
        repeat(5) @(posedge clk); rst_n=1'b1; repeat(2) @(posedge clk);

        for(token=0;token<SEQ_LEN;token=token+1) load_v(token);
        for(row_base=0;row_base<SEQ_LEN;row_base=row_base+TILE)
            for(col_base=0;col_base<SEQ_LEN;col_base=col_base+TILE)
                for(local_row=0;local_row<TILE;local_row=local_row+1)
                    for(local_col=0;local_col<TILE;local_col=local_col+1)
                        send_score(row_base+local_row,col_base+local_col);

        wait(output_count==SEQ_LEN*HEAD_DIM); repeat(8) @(posedge clk);
        if(protocol_error || causal_protocol_error)
            $fatal(1,"unexpected protocol error protocol=%0b causal=%0b",
                   protocol_error,causal_protocol_error);
        if(score_tiles_enqueued!=4 || score_tiles_dequeued!=4 ||
           softmax_tiles_processed!=3 || context_tiles_processed!=3 ||
           causal_tiles_bypassed!=1 || v_vectors_read!=12)
            $fatal(1,"counter mismatch fifo=%0d/%0d sm=%0d ctx=%0d bypass=%0d v=%0d",
                   score_tiles_enqueued,score_tiles_dequeued,
                   softmax_tiles_processed,context_tiles_processed,
                   causal_tiles_bypassed,v_vectors_read);
        $display("V314_CAUSAL_CONSUMER_BYPASS_TEST: PASS contexts=%0d bypass=%0d",
                 output_count,causal_tiles_bypassed);
        $finish;
    end
endmodule
