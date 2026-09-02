`timescale 1ns/1ps

// Frozen-order QK producer mock.  The integration DUT still contains the real
// QK module selection; this mock isolates and verifies only the agreed scalar
// score boundary and all consumer/system metadata wiring.
module qk_parallel_systolic_gqa_top #(
    parameter int TILE=4, QK_LANES=2, SEQ_LEN=4, HEAD_DIM=8, Q_HEADS=1,
    parameter bit CAUSAL_TILE_SKIP=1'b0,
    parameter logic [31:0] SCALE_FP32=32'h3f800000,
    parameter int HEAD_W=(Q_HEADS<=1)?1:$clog2(Q_HEADS),
    parameter int POS_W=(SEQ_LEN<=1)?1:$clog2(SEQ_LEN),
    parameter int DIM_W=(HEAD_DIM<=1)?1:$clog2(HEAD_DIM)
) (
    input logic clk, rst_n, start, causal_en,
    output logic busy, done,
    output logic vec_ready, input logic vec_valid,
    input logic [TILE*16-1:0] q_vec_bf16, k_vec_bf16,
    output logic [HEAD_W-1:0] req_head,
    output logic [POS_W-1:0] req_row_base, req_col_base,
    output logic [DIM_W-1:0] req_dim,
    output logic score_valid, input logic score_ready,
    output logic [15:0] score_bf16,
    output logic [31:0] score_fp32_debug,
    output logic [HEAD_W-1:0] score_head,
    output logic [POS_W-1:0] score_row, score_col,
    output logic score_last,
    output logic [31:0] qk_tiles_computed, qk_tiles_skipped,
    output logic [31:0] masked_tiles_emitted,
    output logic causal_skip_error
);
    logic [5:0] item;
    assign vec_ready = 1'b0;
    assign req_head = '0;
    assign req_row_base = '0;
    assign req_col_base = '0;
    assign req_dim = '0;
    assign score_valid = busy;
    assign score_bf16 = 16'h0000;
    assign score_fp32_debug = 32'h00000000;
    assign score_head = '0;
    assign score_row = $unsigned(item)/SEQ_LEN;
    assign score_col = $unsigned(item)%SEQ_LEN;
    assign score_last = ($unsigned(item) == SEQ_LEN*SEQ_LEN-1);
    assign qk_tiles_computed = 32'd1;
    assign qk_tiles_skipped = 32'd0;
    assign masked_tiles_emitted = 32'd0;
    assign causal_skip_error = 1'b0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            item <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                item <= '0;
            end else if (score_valid && score_ready) begin
                if (score_last) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    item <= item + 1'b1;
                end
            end
        end
    end
    logic unused;
    assign unused = causal_en | vec_valid | q_vec_bf16[0] | k_vec_bf16[0] |
                    CAUSAL_TILE_SKIP | SCALE_FP32[0];
endmodule

module tb_v31_qk_flash_attention_pipeline_top;
    localparam int SEQ_LEN=4;
    localparam int HEAD_DIM=8;
    localparam int V_ADDR_W=$clog2(2*SEQ_LEN*HEAD_DIM);
    logic clk=0;
    logic rst_n=0;
    logic clear=0;
    logic group_start=0;
    logic group_start_ready;
    logic [0:0] group_id=1;
    logic [0:0] active_group_id;
    logic v_load_valid=0;
    logic v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr;
    logic [127:0] v_load_data;
    logic context_valid;
    logic context_ready=1;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [0:0] context_group;
    logic [0:0] context_head;
    logic [0:0] context_global_head;
    logic [1:0] context_row;
    logic [2:0] context_col;
    logic context_last;
    logic busy, group_done, protocol_error;
    integer addr;
    integer outputs;
    integer cycles;

    always #5 clk=~clk;

    qk_flash_attention_pipeline_top #(
        .TILE(4), .QK_LANES(2), .CAUSAL_QK_TILE_SKIP(1'b1),
        .V_LANES(8), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(1), .GQA_GROUPS(2), .SCALE_FP32(32'h3f800000),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n, .clear, .group_start, .group_id,
        .group_start_ready, .active_group_id, .causal_en(1'b0),
        .vec_ready(), .vec_valid(1'b0),
        .q_vec_bf16({64{1'b0}}), .k_vec_bf16({64{1'b0}}),
        .req_head(), .req_group_id(), .req_global_q_head(), .req_kv_head(),
        .req_row_base(), .req_col_base(), .req_dim(),
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group, .context_head,
        .context_global_head, .context_row, .context_col, .context_last,
        .qk_busy(), .qk_done(), .consumer_busy(), .busy, .group_done,
        .qk_tiles_computed(), .qk_tiles_skipped(), .masked_tiles_emitted(),
        .score_tiles_enqueued(), .score_tiles_dequeued(),
        .softmax_tiles_processed(), .context_tiles_processed(),
        .v_vectors_read(), .causal_skip_error(),
        .start_while_busy_error(), .invalid_group_id_error(),
        .consumer_protocol_error(), .protocol_error
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            outputs <= 0;
            cycles <= 0;
        end else begin
            cycles <= cycles+1;
            if (context_valid && context_ready) begin
                if (context_bf16 !== 16'h3f80)
                    $fatal(1,"context[%0d] expected 1.0, got %h",outputs,context_bf16);
                if (context_group !== 1 || context_global_head !== 1)
                    $fatal(1,"group metadata mismatch");
                if ((context_row !== outputs/HEAD_DIM) ||
                    (context_col !== outputs%HEAD_DIM))
                    $fatal(1,"context order mismatch at %0d",outputs);
                if (context_last !== (outputs == SEQ_LEN*HEAD_DIM-1))
                    $fatal(1,"context_last mismatch at %0d",outputs);
                outputs <= outputs+1;
            end
            if (protocol_error)
                $fatal(1,"integration protocol_error");
            if (cycles > 5000)
                $fatal(1,"integration timeout");
        end
    end

    initial begin
        v_load_addr='0;
        v_load_data={8{16'h3f80}};
        repeat(4) @(posedge clk);
        rst_n<=1;
        // Load only group 1: base address = 1*4*8 = 32.
        for(addr=32;addr<64;addr=addr+8) begin
            @(posedge clk);
            v_load_valid<=1;
            v_load_addr<=addr;
            do @(posedge clk); while(!v_load_ready);
            v_load_valid<=0;
        end
        do @(posedge clk); while(!group_start_ready);
        group_start<=1;
        @(posedge clk);
        group_start<=0;
        wait(group_done);
        wait(outputs==SEQ_LEN*HEAD_DIM);
        #1;
        if(outputs!=SEQ_LEN*HEAD_DIM)
            $fatal(1,"context count expected %0d got %0d",SEQ_LEN*HEAD_DIM,outputs);
        $display("QK_FLASH_ATTENTION_PIPELINE_TEST: PASS contexts=%0d cycles=%0d",outputs,cycles);
        $finish;
    end
endmodule
