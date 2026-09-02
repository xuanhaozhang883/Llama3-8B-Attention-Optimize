`timescale 1ns/1ps

module tb_v31_flash_context_fusion_backend;
    localparam int TILE=4;
    localparam int V_LANES=8;
    localparam int SEQ_LEN=4;
    localparam int HEAD_DIM=8;
    localparam int L_W=16+$clog2(SEQ_LEN+1);
    localparam int V_ADDR_W=$clog2(2*SEQ_LEN*HEAD_DIM);
    logic clk=0, rst_n=0, clear=0;
    always #5 clk=~clk;

    logic in_valid, in_ready;
    logic [TILE*TILE*16-1:0] in_weights_q15;
    logic [TILE*16-1:0] in_alpha_q15;
    logic [TILE*L_W-1:0] in_l_q15;
    logic [TILE-1:0] in_row_active;
    logic [0:0] in_group, in_head;
    logic [1:0] in_row_base, in_col_base;
    logic in_row_tile_last, in_group_last;
    logic v_req_valid, v_req_ready;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid, v_rsp_ready;
    logic [V_LANES*16-1:0] v_rsp_data;
    logic context_valid, context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [0:0] context_group, context_head;
    logic [1:0] context_global_head;
    logic [1:0] context_row;
    logic [2:0] context_col;
    logic context_last, busy, tile_done, protocol_error;
    logic [31:0] tiles_processed, v_vectors_read;
    integer seed=32'hBACC3110;
    integer request_count=0;
    integer output_count=0;
    integer cycles=0;
    logic response_pending=0;
    logic [15:0] response_word;
    integer lane;
    integer idx;

    flash_context_fusion_backend #(
        .TILE(TILE), .V_LANES(V_LANES), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .Q_HEADS(2), .GQA_GROUPS(2),
        .HEAD_W(1), .GROUP_W(1), .GLOBAL_HEAD_W(2),
        .POS_W(2), .DIM_W(3), .L_W(L_W), .V_ADDR_W(V_ADDR_W)
    ) dut (.*);

    always @(posedge clk) begin
        if (!rst_n) begin
            v_req_ready <= 0;
            v_rsp_valid <= 0;
            v_rsp_data <= 0;
            context_ready <= 0;
            response_pending <= 0;
            cycles <= 0;
        end else begin
            cycles <= cycles+1;
            if (cycles > 2000) begin
                $display("DEBUG state=%0d req=%0d out=%0d feature=%0d key=%0d pe_ready=%h pe_valid=%h div_done=%h",
                         dut.state, request_count, output_count,
                         dut.feature_chunk, dut.key_index,
                         dut.pe_ready, dut.pe_result_valid, dut.div_done);
                $fatal(1,"backend timeout");
            end
            v_req_ready <= ((cycles%3)!=0) && !response_pending;
            context_ready <= ((cycles%4)!=0);
            if (v_rsp_valid && v_rsp_ready) begin
                v_rsp_valid <= 0;
                response_pending <= 0;
            end
            if (v_req_valid && v_req_ready) begin
                if (v_req_addr !== request_count*HEAD_DIM)
                    $fatal(1,"V address mismatch req=%0d got=%0d",
                           request_count,v_req_addr);
                case (request_count)
                    0: response_word = 16'h3F80; // 1.0
                    1: response_word = 16'h4000; // 2.0
                    2: response_word = 16'h4040; // 3.0
                    default: response_word = 16'h4080; // 4.0
                endcase
                for (lane=0;lane<V_LANES;lane=lane+1)
                    v_rsp_data[lane*16 +: 16] <= response_word;
                v_rsp_valid <= 1;
                response_pending <= 1;
                request_count <= request_count+1;
            end
            if (context_valid && context_ready) begin
                if (context_bf16 !== 16'h4020 ||
                    context_fp32_debug !== 32'h40200000)
                    $fatal(1,"context value mismatch idx=%0d bf16=%h fp32=%h",
                           output_count,context_bf16,context_fp32_debug);
                if (context_group !== 0 || context_head !== 0 ||
                    context_global_head !== 0 ||
                    context_row !== (output_count/HEAD_DIM) ||
                    context_col !== (output_count%HEAD_DIM))
                    $fatal(1,"context metadata mismatch idx=%0d",output_count);
                if (context_last !== (output_count==TILE*HEAD_DIM-1))
                    $fatal(1,"context_last mismatch idx=%0d",output_count);
                output_count <= output_count+1;
            end
        end
    end

    initial begin
        in_valid=0; in_weights_q15='0; in_alpha_q15='0;
        in_l_q15='0; in_row_active=4'hF; in_group=0; in_head=0;
        in_row_base=0; in_col_base=0; in_row_tile_last=1;
        in_group_last=1;
        for(idx=0;idx<TILE*TILE;idx=idx+1)
            in_weights_q15[idx*16 +: 16]=16'h8000;
        for(idx=0;idx<TILE;idx=idx+1)
            in_l_q15[idx*L_W +: L_W]=4*32768;
        repeat(5) @(posedge clk); rst_n=1;
        repeat(2) @(posedge clk);
        @(negedge clk); in_valid=1;
        do @(posedge clk); while(!in_ready);
        @(negedge clk); in_valid=0;
        wait(output_count==TILE*HEAD_DIM);
        repeat(4) @(posedge clk);
        if(protocol_error) $fatal(1,"unexpected protocol_error");
        if(tiles_processed!=1 || v_vectors_read!=4 || request_count!=4)
            $fatal(1,"counter mismatch tiles=%0d vread=%0d req=%0d",
                   tiles_processed,v_vectors_read,request_count);
        $display("FLASH_CONTEXT_FUSION_BACKEND_TEST: PASS contexts=%0d",
                 output_count);
        $finish;
    end
endmodule
