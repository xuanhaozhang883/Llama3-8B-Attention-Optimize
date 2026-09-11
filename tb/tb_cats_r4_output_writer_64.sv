`timescale 1ns/1ps
module tb_cats_r4_output_writer_64;
    logic clk=0; always #5 clk=~clk; logic rst_n=0,clear=0,start;
    logic [31:0] base_addr; logic in_valid,in_ready; logic [15:0] in_epoch; logic [11:0] in_seq;
    logic [4:0] in_global_q_head; logic [6:0] in_row; logic [1:0] in_feature_block; logic [2:0] in_beat_in_chunk;
    logic [63:0] in_data; logic in_row_last,in_tensor_last; logic out_valid,out_ready; logic [31:0] out_addr; logic [63:0] out_data;
    logic out_row_last,out_tensor_last,busy,done,error; logic [63:0] beats_accepted,rows_written,protocol_error_count;
    cats_r4_output_writer_64 #(.TOTAL_BEATS(32)) dut (.*);
    task automatic tick; @(posedge clk); #1; endtask
    integer b,beat; initial begin
        start=0;base_addr=32'h1000;in_valid=0;in_epoch=16'ha203;in_seq=0;in_global_q_head=0;in_row=0;in_feature_block=0;in_beat_in_chunk=0;in_data=0;in_row_last=0;in_tensor_last=0;out_ready=0;
        repeat(2) tick(); rst_n=1; @(negedge clk); start=1; tick(); @(negedge clk); start=0;
        for(b=0;b<4;b=b+1) for(beat=0;beat<8;beat=beat+1) begin
            @(negedge clk); in_seq=0; in_feature_block=b[1:0]; in_beat_in_chunk=beat[2:0]; in_data={32'd0,b[15:0],beat[15:0]}; in_row_last=(b==3)&&(beat==7); in_tensor_last=(b==3)&&(beat==7); in_valid=1;
            while(!in_ready) tick(); tick(); @(negedge clk); in_valid=0;
            if(beat==2) begin out_ready=0; repeat(3) tick(); out_ready=1; end else out_ready=1;
            while(out_valid) tick();
        end
        out_ready=1; while(!done) tick();
        if(error || protocol_error_count!=0 || beats_accepted!=32 || rows_written!=1 || out_addr!=32'h1100)
            $fatal(1,"writer mismatch err=%0d p=%0d beats=%0d rows=%0d addr=%h",error,protocol_error_count,beats_accepted,rows_written,out_addr);
        $display("PASS: CATS-R4 64-bit output writer ordering, address, row/tensor last and backpressure"); $finish;
    end
    initial begin repeat(10000) tick(); $fatal(1,"writer timeout"); end
endmodule
