`timescale 1ns/1ps

module tb_cats_r4_qkv_banked_mem;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic counter_clear = 1'b0;

    logic prep_valid, prep_ready, prep_buffer;
    logic [15:0] prep_epoch;
    logic load_valid, load_ready, load_buffer;
    logic [15:0] load_epoch;
    logic [1:0] load_kind;
    logic [3:0] load_context_tag;
    logic [6:0] load_key, load_d;
    logic [15:0] load_data_bf16;
    logic publish_valid, publish_ready, publish_buffer;
    logic [15:0] publish_epoch;
    logic activate_valid, activate_ready, activate_buffer;
    logic [15:0] activate_epoch;
    logic active_valid, active_buffer;
    logic [15:0] active_epoch;
    logic [1:0] buffer_ready;
    logic [31:0] buffer_epoch_flat;

    logic q_req_valid, q_req_ready;
    logic [3:0] q_req_context_tag;
    logic [6:0] q_req_d;
    logic q_rsp_valid;
    logic [3:0] q_rsp_context_tag;
    logic [15:0] q_rsp_bf16;
    logic k_req_valid, k_req_ready;
    logic [3:0] k_req_context_tag;
    logic [1:0] k_req_key_block;
    logic [6:0] k_req_d;
    logic k_rsp_valid;
    logic [3:0] k_rsp_context_tag;
    logic [511:0] k_rsp_vec;
    logic v_req_valid, v_req_ready;
    logic [3:0] v_req_context_tag;
    logic [6:0] v_req_key;
    logic [1:0] v_req_feature_block;
    logic v_rsp_valid;
    logic [3:0] v_rsp_context_tag;
    logic [511:0] v_rsp_vec;
    logic [63:0] q_requests_accepted, k_requests_accepted;
    logic [63:0] v_requests_accepted, active_write_conflicts;
    logic [63:0] bank_conflicts, protocol_errors;
    logic protocol_error_sticky;

    cats_r4_qkv_banked_mem dut (
        .core_clk(clk),
        .core_rst_n(rst_n),
        .*
    );

    task automatic fail(input string msg);
        begin $display("FAIL: %s", msg); $fatal(1); end
    endtask

    task automatic idle_edge;
        begin @(posedge clk); #1; end
    endtask

    task automatic prepare(input logic buffer_sel, input logic [15:0] epoch);
        begin
            @(negedge clk);
            prep_buffer = buffer_sel; prep_epoch = epoch; prep_valid = 1'b1;
            #1; if (!prep_ready) fail("prepare unexpectedly blocked");
            idle_edge();
            @(negedge clk); prep_valid = 1'b0;
        end
    endtask

    task automatic load_word(
        input logic buffer_sel, input logic [15:0] epoch, input logic [1:0] kind,
        input logic [3:0] context_tag, input logic [6:0] key,
        input logic [6:0] dim, input logic [15:0] data
    );
        begin
            @(negedge clk);
            load_buffer = buffer_sel; load_epoch = epoch; load_kind = kind;
            load_context_tag = context_tag; load_key = key; load_d = dim;
            load_data_bf16 = data; load_valid = 1'b1;
            #1; if (!load_ready) fail("legal load unexpectedly blocked");
            idle_edge();
            @(negedge clk); load_valid = 1'b0;
        end
    endtask

    task automatic publish(input logic buffer_sel, input logic [15:0] epoch);
        begin
            @(negedge clk);
            publish_buffer = buffer_sel; publish_epoch = epoch; publish_valid = 1'b1;
            #1; if (!publish_ready) fail("publish unexpectedly blocked");
            idle_edge();
            @(negedge clk); publish_valid = 1'b0;
        end
    endtask

    task automatic activate(input logic buffer_sel, input logic [15:0] epoch);
        begin
            @(negedge clk);
            activate_buffer = buffer_sel; activate_epoch = epoch; activate_valid = 1'b1;
            #1; if (!activate_ready) fail("activate unexpectedly blocked");
            idle_edge();
            @(negedge clk); activate_valid = 1'b0;
        end
    endtask

    integer i;
    initial begin
        prep_valid = 0; prep_buffer = 0; prep_epoch = 0;
        load_valid = 0; load_buffer = 0; load_epoch = 0; load_kind = 0;
        load_context_tag = 0; load_key = 0; load_d = 0; load_data_bf16 = 0;
        publish_valid = 0; publish_buffer = 0; publish_epoch = 0;
        activate_valid = 0; activate_buffer = 0; activate_epoch = 0;
        q_req_valid = 0; q_req_context_tag = 0; q_req_d = 0;
        k_req_valid = 0; k_req_context_tag = 0; k_req_key_block = 0; k_req_d = 0;
        v_req_valid = 0; v_req_context_tag = 0; v_req_key = 0;
        v_req_feature_block = 0;

        repeat (3) idle_edge();
        rst_n = 1'b1;
        idle_edge();

        prepare(1'b0, 16'h0101);
        load_word(0, 16'h0101, 0, 4'd1, 7'd0, 7'd5, 16'h3f80);
        load_word(0, 16'h0101, 0, 4'd2, 7'd0, 7'd6, 16'h4000);
        for (i = 0; i < 32; i = i + 1)
            load_word(0, 16'h0101, 1, 0, 7'd32+i, 7'd9, 16'h1000+i);
        for (i = 0; i < 32; i = i + 1)
            load_word(0, 16'h0101, 2, 0, 7'd7, 7'd64+i, 16'h2000+i);
        publish(1'b0, 16'h0101);
        activate(1'b0, 16'h0101);
        idle_edge();
        if (!active_valid || active_buffer || active_epoch != 16'h0101)
            fail("active buffer identity mismatch");
        if (!buffer_ready[0] || buffer_epoch_flat[15:0] != 16'h0101)
            fail("published buffer metadata mismatch");

        // A write to the active buffer must not transfer and must count once,
        // even if valid is held for more than one cycle.
        @(negedge clk);
        load_buffer = 0; load_epoch = 16'h0101; load_kind = 0;
        load_context_tag = 1; load_d = 5; load_data_bf16 = 16'hdead;
        load_valid = 1;
        #1; if (load_ready) fail("active-buffer write accepted");
        idle_edge(); idle_edge();
        @(negedge clk); load_valid = 0;
        idle_edge();
        if (active_write_conflicts != 1 || bank_conflicts != 1 ||
            protocol_errors != 1 || !protocol_error_sticky)
            fail("active-write/protocol counters mismatch");

        // Clear observation counters without disturbing ownership/data.
        @(negedge clk); counter_clear = 1;
        idle_edge();
        @(negedge clk); counter_clear = 0;
        idle_edge();
        if (active_write_conflicts || bank_conflicts || protocol_errors ||
            protocol_error_sticky)
            fail("counter clear failed");

        // Four independent illegal assertions in one cycle are four protocol
        // events, not one.  Holding valid must still count each channel only
        // once, and only the active-buffer load is a bank/write conflict.
        @(negedge clk);
        prep_buffer = 0; prep_epoch = 16'h0200; prep_valid = 1;
        load_buffer = 0; load_epoch = 16'h0101; load_kind = 0;
        load_context_tag = 1; load_d = 5; load_valid = 1;
        publish_buffer = 1; publish_epoch = 16'h0201; publish_valid = 1;
        activate_buffer = 1; activate_epoch = 16'h0201; activate_valid = 1;
        #1;
        if (prep_ready || load_ready || publish_ready || activate_ready)
            fail("simultaneous illegal controls unexpectedly accepted");
        idle_edge(); idle_edge();
        if (protocol_errors != 4 || active_write_conflicts != 1 ||
            bank_conflicts != 1 || !protocol_error_sticky)
            fail("simultaneous rejection accounting mismatch");
        @(negedge clk);
        prep_valid = 0; load_valid = 0; publish_valid = 0; activate_valid = 0;
        idle_edge();
        @(negedge clk); counter_clear = 1;
        idle_edge();
        @(negedge clk); counter_clear = 0;
        idle_edge();
        if (active_write_conflicts || bank_conflicts || protocol_errors ||
            protocol_error_sticky)
            fail("second counter clear failed");

        // Three services accept requests concurrently.  A second Q request
        // follows on the next cycle to prove Q II=1.  The first responses must
        // be absent for one edge and present on exactly the second edge.
        @(negedge clk);
        q_req_valid = 1; q_req_context_tag = 1; q_req_d = 5;
        k_req_valid = 1; k_req_context_tag = 4'ha; k_req_key_block = 1; k_req_d = 9;
        v_req_valid = 1; v_req_context_tag = 4'hb; v_req_key = 7; v_req_feature_block = 2;
        #1;
        if (!q_req_ready || !k_req_ready || !v_req_ready)
            fail("service request unexpectedly blocked");
        idle_edge(); // acceptance edge N
        if (q_rsp_valid || k_rsp_valid || v_rsp_valid)
            fail("response arrived on acceptance edge");

        @(negedge clk);
        q_req_context_tag = 2; q_req_d = 6;
        k_req_valid = 0; v_req_valid = 0;
        #1; if (!q_req_ready) fail("Q did not sustain II=1");
        idle_edge(); // N+1, second Q accepted
        if (q_rsp_valid || k_rsp_valid || v_rsp_valid)
            fail("response arrived one cycle early");

        @(negedge clk); q_req_valid = 0;
        idle_edge(); // N+2, first response
        if (!q_rsp_valid || !k_rsp_valid || !v_rsp_valid)
            fail("response missing at fixed two-cycle latency");
        if (q_rsp_context_tag != 1 || q_rsp_bf16 != 16'h3f80)
            fail("Q bank/tag data mismatch");
        if (k_rsp_context_tag != 4'ha || v_rsp_context_tag != 4'hb)
            fail("K/V response tag mismatch");
        for (i = 0; i < 32; i = i + 1) begin
            if (k_rsp_vec[i*16 +: 16] != 16'h1000+i)
                fail("K key-bank mapping mismatch");
            if (v_rsp_vec[i*16 +: 16] != 16'h2000+i)
                fail("V feature-bank mapping mismatch");
        end

        idle_edge(); // N+3, second Q response
        if (!q_rsp_valid || q_rsp_context_tag != 2 || q_rsp_bf16 != 16'h4000)
            fail("consecutive Q response mismatch");
        if (k_rsp_valid || v_rsp_valid)
            fail("spurious K/V response");
        idle_edge();
        if (q_rsp_valid || k_rsp_valid || v_rsp_valid)
            fail("response pulse did not clear");

        if (q_requests_accepted != 2 || k_requests_accepted != 1 ||
            v_requests_accepted != 1)
            fail("accepted-request counters mismatch");

        // Fill and switch to ping/pong buffer 1.  Buffer 0 becomes inactive,
        // proving ownership can rotate without touching its contents.
        prepare(1'b1, 16'h0102);
        load_word(1, 16'h0102, 0, 4'd1, 0, 7'd5, 16'h4040);
        publish(1'b1, 16'h0102);
        activate(1'b1, 16'h0102);
        idle_edge();
        if (!active_buffer || active_epoch != 16'h0102)
            fail("ping/pong activation mismatch");

        $display("PASS: cats_r4_qkv_banked_mem banking/ownership/latency/II/counters");
        $finish;
    end
endmodule
