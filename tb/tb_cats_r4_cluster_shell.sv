`timescale 1ns/1ps

// Contract-only smoke test for cats_r4_cluster_shell.
// It checks command filtering, output/done stability under backpressure and
// descriptor identity.  It intentionally does not claim A/B/C correctness.
module tb_cats_r4_cluster_shell;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    logic cmd_valid, cmd_ready;
    logic [15:0] cmd_epoch;
    logic [1:0] cmd_cluster_id;
    logic [2:0] cmd_group_id;
    logic [4:0] cmd_q_head_base;
    logic cmd_kv_buffer;
    logic done_valid, done_ready;
    logic [15:0] done_epoch;
    logic [2:0] done_group;
    logic done_error;
    logic q_req_valid, q_req_ready, q_rsp_valid, q_rsp_ready;
    logic [3:0] q_req_context_tag, q_rsp_context_tag;
    logic [6:0] q_req_d;
    logic [15:0] q_rsp_bf16;
    logic k_req_valid, k_req_ready, k_rsp_valid, k_rsp_ready;
    logic [3:0] k_req_context_tag, k_rsp_context_tag;
    logic [1:0] k_req_key_block;
    logic [6:0] k_req_d;
    logic [511:0] k_rsp_vec;
    logic v_req_valid, v_req_ready, v_rsp_valid, v_rsp_ready;
    logic [3:0] v_req_context_tag, v_rsp_context_tag;
    logic [6:0] v_req_key;
    logic [1:0] v_req_feature_block;
    logic [511:0] v_rsp_vec;
    logic out_valid, out_ready;
    logic [15:0] out_epoch;
    logic [11:0] out_seq;
    logic [4:0] out_global_q_head;
    logic [6:0] out_row;
    logic [1:0] out_feature_block;
    logic [511:0] out_data_bf16;
    logic out_row_last, out_tensor_last, protocol_error;

    cats_r4_cluster_shell dut (
        .core_clk(clk), .core_rst_n(rst_n),
        .cmd_valid, .cmd_ready, .cmd_epoch, .cmd_cluster_id,
        .cmd_group_id, .cmd_q_head_base, .cmd_kv_buffer,
        .done_valid, .done_ready, .done_epoch, .done_group, .done_error,
        .q_req_valid, .q_req_ready, .q_req_context_tag, .q_req_d,
        .q_rsp_valid, .q_rsp_ready, .q_rsp_context_tag, .q_rsp_bf16,
        .k_req_valid, .k_req_ready, .k_req_context_tag, .k_req_key_block,
        .k_req_d, .k_rsp_valid, .k_rsp_ready, .k_rsp_context_tag, .k_rsp_vec,
        .v_req_valid, .v_req_ready, .v_req_context_tag, .v_req_key,
        .v_req_feature_block, .v_rsp_valid, .v_rsp_ready,
        .v_rsp_context_tag, .v_rsp_vec,
        .out_valid, .out_ready, .out_epoch, .out_seq, .out_global_q_head,
        .out_row, .out_feature_block, .out_data_bf16, .out_row_last,
        .out_tensor_last, .protocol_error
    );

    task automatic tick; begin @(posedge clk); #1; end endtask
    task automatic fail(input string msg); begin
        $display("FAIL: %s", msg);
        $fatal(1);
    end endtask

    logic [15:0] hold_epoch;
    logic [11:0] hold_seq;
    logic [4:0] hold_head;
    logic [511:0] hold_data;

    initial begin
        cmd_valid = 0; cmd_epoch = 0; cmd_cluster_id = 0; cmd_group_id = 0;
        cmd_q_head_base = 0; cmd_kv_buffer = 0;
        done_ready = 0; out_ready = 0;
        q_req_ready = 1; q_rsp_valid = 0; q_rsp_context_tag = 0; q_rsp_bf16 = 0;
        k_req_ready = 1; k_rsp_valid = 0; k_rsp_context_tag = 0; k_rsp_vec = 0;
        v_req_ready = 1; v_rsp_valid = 0; v_rsp_context_tag = 0; v_rsp_vec = 0;

        repeat (2) tick();
        rst_n = 1;
        tick();

        // Wrong cluster ID is filtered and cannot transfer.
        cmd_epoch = 16'h1234; cmd_group_id = 3'd5; cmd_q_head_base = 5'd7;
        cmd_cluster_id = 2'd1; cmd_valid = 1;
        tick();
        if (cmd_ready) fail("wrong cluster ID accepted");
        cmd_valid = 0;
        tick();

        cmd_cluster_id = 2'd0; cmd_valid = 1; #1;
        if (!cmd_ready) fail("valid command not accepted");
        tick();
        cmd_valid = 0;
        tick();

        if (!out_valid) fail("output not presented after command");
        hold_epoch = out_epoch; hold_seq = out_seq; hold_head = out_global_q_head;
        hold_data = out_data_bf16;
        repeat (3) begin
            tick();
            if (!out_valid || out_epoch !== hold_epoch || out_seq !== hold_seq ||
                out_global_q_head !== hold_head || out_data_bf16 !== hold_data)
                fail("output payload changed under backpressure");
        end
        if (out_seq !== 12'd896) fail("unexpected output sequence");
        out_ready = 1;
        tick();
        out_ready = 0;
        tick();
        if (!done_valid) fail("done descriptor missing");
        if (done_epoch !== 16'h1234 || done_group !== 3'd5 || done_error)
            fail("done descriptor mismatch");
        done_ready = 1;
        tick();
        if (done_valid) fail("done did not handshake");
        if (q_req_valid || k_req_valid || v_req_valid || q_rsp_ready ||
            k_rsp_ready || v_rsp_ready)
            fail("stub unexpectedly consumed/issued memory service traffic");
        $display("PASS: cats_r4_cluster_shell contract smoke");
        $finish;
    end
endmodule
