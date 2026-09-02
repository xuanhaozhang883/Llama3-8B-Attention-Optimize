`timescale 1ns/1ps

module tb_v31_v_ddr_loader_lanes8;
    logic clk=0, rst_n=0, start=0;
    logic busy, done, error;
    logic rd_start, rd_ready=1;
    logic [31:0] rd_addr, rd_len;
    logic rd_data_we=0;
    logic [63:0] rd_data=0;
    logic rd_fifo_full;
    logic rd_done=0, rd_error=0;
    logic v_load_valid;
    logic v_load_ready=0;
    logic [4:0] v_load_addr;
    logic [127:0] v_load_data;
    integer cycle;
    integer beat;
    integer vector_count;

    always #5 clk=~clk;
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            cycle<=0;
            vector_count<=0;
            v_load_ready<=0;
        end else begin
            cycle<=cycle+1;
            v_load_ready<=((cycle%3)!=1);
            if(v_load_valid&&v_load_ready) begin
                if(v_load_addr!==vector_count*8)
                    $fatal(1,"address %0d expected %0d",v_load_addr,vector_count*8);
                if(v_load_data[63:0]!==64'h1000_0000_0000_0000+vector_count*2)
                    $fatal(1,"low beat mismatch vector %0d",vector_count);
                if(v_load_data[127:64]!==64'h1000_0000_0000_0001+vector_count*2)
                    $fatal(1,"high beat mismatch vector %0d",vector_count);
                vector_count<=vector_count+1;
            end
            if(error) $fatal(1,"loader error");
            if(cycle>300) $fatal(1,"loader timeout");
        end
    end

    fpt_v_ddr_loader #(
        .RUN_GROUPS(1), .SEQ_LEN(4), .HEAD_DIM(8),
        .V_ADDR_W(5), .LOAD_LANES(8)
    ) dut (
        .clk,.rst_n,.start,.v_base_addr(32'h1000),
        .busy,.done,.error,.rd_start,.rd_ready,.rd_addr,.rd_len,
        .rd_data_we,.rd_data,.rd_fifo_full,.rd_done,.rd_error,
        .v_load_valid,.v_load_ready,.v_load_addr,.v_load_data
    );

    initial begin
        repeat(4) @(posedge clk);
        rst_n<=1;
        @(posedge clk); start<=1;
        @(posedge clk); start<=0;
        wait(rd_start);
        for(beat=0;beat<8;beat=beat+1) begin
            @(negedge clk);
            while(rd_fifo_full) @(negedge clk);
            rd_data=64'h1000_0000_0000_0000+beat;
            rd_data_we=1;
            if(beat==7) rd_done=1;
            @(negedge clk);
            rd_data_we=0;
            rd_done=0;
        end
        wait(done);
        wait(vector_count==4);
        #1;
        if(rd_len!==64) $fatal(1,"rd_len expected 64 got %0d",rd_len);
        $display("V_DDR_LOADER_LANES8_TEST: PASS vectors=%0d",vector_count);
        $finish;
    end
endmodule
