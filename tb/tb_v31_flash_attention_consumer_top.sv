`timescale 1ns/1ps

module tb_v31_flash_attention_consumer_top;
    localparam int TILE=4, V_LANES=8, SEQ_LEN=4, HEAD_DIM=8;
    localparam int V_ADDR_W=$clog2(SEQ_LEN*HEAD_DIM);
    logic clk=0,rst_n=0,clear=0;
    always #5 clk=~clk;
    logic score_valid,score_ready;
    logic [15:0] score_bf16;
    logic score_mask;
    logic [0:0] score_group,score_head;
    logic [1:0] score_row,score_col;
    logic score_last;
    logic v_load_valid,v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr;
    logic [V_LANES*16-1:0] v_load_data;
    logic context_valid,context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [0:0] context_group,context_head,context_global_head;
    logic [1:0] context_row;
    logic [2:0] context_col;
    logic context_last,busy,protocol_error;
    logic causal_en=1'b0;
    logic [31:0] score_tiles_enqueued,score_tiles_dequeued;
    logic [31:0] softmax_tiles_processed,context_tiles_processed,v_vectors_read;
    logic [31:0] causal_tiles_bypassed;
    logic causal_protocol_error;
    integer row,col,lane,output_count=0,cycles=0;
    logic [15:0] expected;

    flash_attention_consumer_top #(
        .TILE(TILE),.V_LANES(V_LANES),.FIFO_DEPTH_TILES(3),
        .SEQ_LEN(SEQ_LEN),.HEAD_DIM(HEAD_DIM),.Q_HEADS(1),.GQA_GROUPS(1),
        .HEAD_W(1),.GROUP_W(1),.GLOBAL_HEAD_W(1),.POS_W(2),.DIM_W(3),
        .V_ADDR_W(V_ADDR_W),.EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (.*);

    task automatic load_v(input integer token, input logic [15:0] value);
        integer vl;
        begin
            @(negedge clk);
            v_load_addr=token*HEAD_DIM;
            for(vl=0;vl<V_LANES;vl=vl+1)
                v_load_data[vl*16 +: 16]=value;
            v_load_valid=1;
            do @(posedge clk); while(!v_load_ready);
            @(negedge clk); v_load_valid=0;
        end
    endtask

    task automatic send_score(input integer sr,input integer sc);
        begin
            @(negedge clk);
            score_row=sr; score_col=sc; score_bf16=16'h0000;
            // Causal/all-masked behavior is covered in the dedicated front-end
            // test.  Keep this full-chain arithmetic case on the exact quarter
            // values supported by the lightweight FP mocks.
            score_mask=1'b0;
            score_last=(sr==SEQ_LEN-1 && sc==SEQ_LEN-1);
            score_valid=1;
            do @(posedge clk); while(!score_ready);
            @(negedge clk); score_valid=0;
        end
    endtask

    always @(posedge clk) begin
        if(!rst_n) begin context_ready<=0; cycles<=0; end
        else begin
            cycles<=cycles+1;
            context_ready<=((cycles%5)!=0);
            if(cycles>3000)$fatal(1,"consumer timeout");
            if(context_valid&&context_ready) begin
                expected=16'h4020;
                if(context_bf16!==expected)
                    $fatal(1,"context mismatch row=%0d col=%0d got=%h exp=%h",
                           context_row,context_col,context_bf16,expected);
                if(context_col!==(output_count%HEAD_DIM) ||
                   context_row!==(output_count/HEAD_DIM))
                    $fatal(1,"context order mismatch idx=%0d",output_count);
                if(context_last!==(output_count==TILE*HEAD_DIM-1))
                    $fatal(1,"context_last mismatch idx=%0d",output_count);
                output_count<=output_count+1;
            end
        end
    end

    initial begin
        score_valid=0;score_bf16=0;score_mask=0;score_group=0;score_head=0;
        score_row=0;score_col=0;score_last=0;
        v_load_valid=0;v_load_addr=0;v_load_data=0;
        repeat(5)@(posedge clk);rst_n=1;repeat(2)@(posedge clk);
        load_v(0,16'h3F80);load_v(1,16'h4000);
        load_v(2,16'h4040);load_v(3,16'h4080);
        for(row=0;row<TILE;row=row+1)
            for(col=0;col<TILE;col=col+1)
                send_score(row,col);
        wait(output_count==TILE*HEAD_DIM);repeat(4)@(posedge clk);
        if(protocol_error)$fatal(1,"unexpected protocol_error");
        if(score_tiles_enqueued!=1||score_tiles_dequeued!=1||
           softmax_tiles_processed!=1||context_tiles_processed!=1||
           v_vectors_read!=4)
            $fatal(1,"counter mismatch fifo=%0d/%0d sm=%0d ctx=%0d v=%0d",
                   score_tiles_enqueued,score_tiles_dequeued,
                   softmax_tiles_processed,context_tiles_processed,v_vectors_read);
        if(causal_tiles_bypassed!=0 || causal_protocol_error)
            $fatal(1,"disabled causal bypass changed compatibility behavior");
        $display("FLASH_ATTENTION_CONSUMER_TOP_TEST: PASS contexts=%0d",output_count);
        $finish;
    end
endmodule
