`timescale 1ns/1ps
module tb_cats_r4_output_cdc;
    logic core_clk=0,axi_clk=0;
    always #2.5 core_clk=~core_clk;
    always #3.5 axi_clk=~axi_clk;
    logic core_rst_n=0,axi_rst_n=0,core_counter_clear=0,axi_counter_clear=0;
    logic in_valid=0,in_ready; logic [15:0] in_epoch=0;
    logic [4:0] in_global_q_head=0; logic [6:0] in_row=0;
    logic [1:0] in_feature_block=0; logic [511:0] in_data_bf16=0;
    logic in_row_last=0,in_tensor_last=0,out_valid,out_ready=0;
    logic [63:0] out_data; logic [15:0] out_epoch; logic [11:0] out_seq;
    logic [4:0] out_global_q_head; logic [6:0] out_row;
    logic [5:0] out_beat_in_row; logic out_row_last,out_tensor_last;
    logic [63:0] payload_push_count,payload_pop_count,tag_push_count,tag_pop_count;
    logic [63:0] full_stall_count,empty_stall_count;
    logic [63:0] max_payload_occupancy,max_tag_occupancy;
    logic [63:0] overflow_count,underflow_count,seq_error_count,epoch_error_count;
    logic core_protocol_error,axi_protocol_error;
    cats_r4_output_cdc dut(.*);

    logic [15:0] lfsr=16'hca75;
    logic random_ready=0;
    integer received_beats=0,expected_row_index=0;
    logic [15:0] expected_epoch=16'h1001;

    function automatic [63:0] beat_value(input logic [15:0] epoch,
        input integer row_index,input integer beat_index);
        beat_value={epoch,row_index[11:0],beat_index[5:0],30'h155aa55};
    endfunction
    function automatic [511:0] chunk_value(input logic [15:0] epoch,
        input integer row_index,input integer feature_block);
        integer b;
        begin
            for(b=0;b<8;b=b+1)
                chunk_value[b*64+:64]=beat_value(epoch,row_index,feature_block*8+b);
        end
    endfunction

    always_ff @(posedge axi_clk or negedge axi_rst_n) begin
        if(!axi_rst_n) begin lfsr<=16'hca75; out_ready<=0; end
        else if(random_ready) begin
            lfsr<={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            out_ready<=lfsr[0]|lfsr[2];
        end else out_ready<=0;
    end

    always @(posedge axi_clk) begin
        if(out_valid&&out_ready) begin
            if(out_epoch!==expected_epoch||out_seq!==expected_row_index||
               out_global_q_head!==(expected_row_index/128)||
               out_row!==(expected_row_index%128)||
               out_beat_in_row!==(received_beats%32)||
               out_data!==beat_value(expected_epoch,expected_row_index,received_beats%32))
                $fatal(1,"payload/tag mismatch epoch=%h seq=%0d beat=%0d data=%h",
                       out_epoch,out_seq,out_beat_in_row,out_data);
            if(out_row_last!==(out_beat_in_row==31)) $fatal(1,"row_last mismatch");
            received_beats=received_beats+1;
            if((received_beats%32)==0) expected_row_index=expected_row_index+1;
        end
    end

    task automatic send_rows(input integer first_row,input integer count,
                              input logic [15:0] epoch);
        integer rr,fb;
        begin
            for(rr=first_row;rr<first_row+count;rr=rr+1)
                for(fb=0;fb<4;fb=fb+1) begin
                    @(negedge core_clk);
                    in_epoch=epoch; in_global_q_head=rr/128; in_row=rr%128;
                    in_feature_block=fb; in_data_bf16=chunk_value(epoch,rr,fb);
                    in_row_last=(fb==3);
                    in_tensor_last=(rr==4095)&&(fb==3); in_valid=1;
                    while(!in_ready) @(negedge core_clk);
                    @(posedge core_clk); #1; in_valid=0;
                end
        end
    endtask

    task automatic async_reset;
        begin
            #1.3 core_rst_n=0; axi_rst_n=0;
            #17.2 axi_rst_n=1;
            #13.1 core_rst_n=1;
        end
    endtask

    initial begin #50_000_000 $fatal(1,"simulation watchdog"); end
    initial begin
        async_reset();
        // Stall AXI until all 32 rows are resident; row 33 must hit full.
        fork
            send_rows(0,4096,16'h1001);
            begin
                wait(tag_push_count==32); repeat(40) @(posedge core_clk);
                if(full_stall_count==0) $fatal(1,"FIFO full was not exercised");
                random_ready=1;
            end
        join
        wait(expected_row_index==4096);
        #1; // allow DUT handshake counters to commit their NBA updates
        if(payload_push_count!=131072||payload_pop_count!=131072||
           tag_push_count!=4096||tag_pop_count!=4096)
            $fatal(1,"first epoch counter mismatch ppush=%0d ppop=%0d tpush=%0d tpop=%0d",
                   payload_push_count,payload_pop_count,
                   tag_push_count,tag_pop_count);
        if(max_payload_occupancy<1000||max_tag_occupancy<31)
            $fatal(1,"capacity not exercised payload=%0d tag=%0d",
                   max_payload_occupancy,max_tag_occupancy);
        if(overflow_count||underflow_count||seq_error_count||epoch_error_count||
           core_protocol_error||axi_protocol_error)
            $fatal(1,"unexpected first epoch error");

        // More than two complete payload pointer wraps have occurred. Reset
        // asynchronously and restart canonical row zero with a new epoch.
        random_ready=0; async_reset();
        received_beats=0; expected_row_index=0; expected_epoch=16'h2002;
        random_ready=1; send_rows(0,12,16'h2002);
        wait(expected_row_index==12);
        #1;
        if(payload_push_count!=384||payload_pop_count!=384||
           tag_push_count!=12||tag_pop_count!=12)
            $fatal(1,"post-reset counter mismatch ppush=%0d ppop=%0d tpush=%0d tpop=%0d",
                   payload_push_count,payload_pop_count,
                   tag_push_count,tag_pop_count);
        if(overflow_count||underflow_count||seq_error_count||epoch_error_count||
           core_protocol_error||axi_protocol_error)
            $fatal(1,"unexpected post-reset error");
        $display("PASS cats_r4_output_cdc rows=4096+12 full/backpressure/wrap/reset payload-tag atomic");
        $finish;
    end
endmodule
