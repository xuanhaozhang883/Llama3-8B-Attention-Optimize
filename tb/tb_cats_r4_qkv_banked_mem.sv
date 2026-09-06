`timescale 1ns/1ps

module tb_cats_r4_qkv_banked_mem;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, counter_clear = 0;

    logic prep_valid, prep_ready, prep_buffer;
    logic [15:0] prep_epoch;
    logic [2:0] prep_group;
    logic load_valid, load_ready, load_buffer;
    logic [15:0] load_epoch;
    logic [2:0] load_group, load_row_window;
    logic [4:0] load_global_q_head;
    logic [1:0] load_kind;
    logic [3:0] load_context_tag;
    logic [6:0] load_key, load_d;
    logic [15:0] load_data_bf16;
    logic publish_valid, publish_ready, publish_buffer;
    logic [15:0] publish_epoch;
    logic [2:0] publish_group;
    logic activate_valid, activate_ready, activate_buffer;
    logic [15:0] activate_epoch;
    logic [2:0] activate_group;
    logic active_valid, active_buffer;
    logic [15:0] active_epoch;
    logic [2:0] active_group;
    logic [1:0] buffer_ready;
    logic [31:0] buffer_epoch_flat;
    logic [5:0] buffer_group_flat;

    logic q_slab_need_valid, q_slab_need_ready;
    logic [15:0] q_slab_need_epoch;
    logic [2:0] q_slab_need_group, q_slab_need_row_window;
    logic [4:0] q_slab_need_global_q_head;
    logic q_fill_valid, q_fill_ready, q_fill_buffer;
    logic [15:0] q_fill_epoch;
    logic [2:0] q_fill_group, q_fill_row_window;
    logic [4:0] q_fill_global_q_head;
    logic q_publish_valid, q_publish_ready, q_publish_buffer;
    logic [15:0] q_publish_epoch;
    logic [2:0] q_publish_group, q_publish_row_window;
    logic [4:0] q_publish_global_q_head;
    logic q_slab_ready_valid, q_slab_ready_ready;
    logic [15:0] q_slab_ready_epoch;
    logic [2:0] q_slab_ready_group, q_slab_ready_row_window;
    logic [4:0] q_slab_ready_global_q_head;
    logic q_slab_ready_buffer;
    logic q_slab_retire_valid, q_slab_retire_ready;
    logic [15:0] q_slab_retire_epoch;
    logic [2:0] q_slab_retire_group, q_slab_retire_row_window;
    logic [4:0] q_slab_retire_global_q_head;
    logic q_slab_retire_buffer;

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
    logic [63:0] q_slab_need_count, q_slab_fill_count;
    logic [63:0] q_slab_ready_count, q_slab_activate_count;
    logic [63:0] q_slab_retire_count, q_slab_refill_wait;
    logic [63:0] q_slab_reuse_stall, q_slab_outstanding_max;
    logic [63:0] q_slab_tag_error, q_slab_epoch_error;
    logic [63:0] q_slab_overwrite_error, q_slab_early_retire_error;
    logic [63:0] kv_paired_ready_error, q_buffer_reuse_stall;
    logic [63:0] kv_buffer_reuse_stall;

    cats_r4_qkv_banked_mem dut (.*,
        .core_clk(clk), .core_rst_n(rst_n));

    task automatic fail(input string msg);
        begin $display("FAIL: %s", msg); $fatal(1); end
    endtask

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic kv_prepare(input logic b, input logic [15:0] e,
                              input logic [2:0] g);
        begin
            @(negedge clk); prep_buffer=b; prep_epoch=e; prep_group=g;
            prep_valid=1; #1; if (!prep_ready) fail("KV prepare blocked");
            tick(); @(negedge clk); prep_valid=0;
        end
    endtask

    task automatic write_word(
        input logic b, input logic [15:0] e, input logic [2:0] g,
        input logic [4:0] h, input logic [2:0] w, input logic [1:0] kind,
        input logic [3:0] c, input logic [6:0] key,
        input logic [6:0] d, input logic [15:0] data);
        begin
            @(negedge clk); load_buffer=b; load_epoch=e; load_group=g;
            load_global_q_head=h; load_row_window=w; load_kind=kind;
            load_context_tag=c; load_key=key; load_d=d;
            load_data_bf16=data; load_valid=1;
            #1; if (!load_ready) fail("legal memory write blocked");
            tick(); @(negedge clk); load_valid=0;
        end
    endtask

    task automatic kv_publish(input logic b, input logic [15:0] e,
                              input logic [2:0] g);
        begin
            @(negedge clk); publish_buffer=b; publish_epoch=e;
            publish_group=g; publish_valid=1;
            #1; if (!publish_ready) fail("paired KV publish blocked");
            tick(); @(negedge clk); publish_valid=0;
        end
    endtask

    task automatic kv_activate(input logic b, input logic [15:0] e,
                               input logic [2:0] g);
        begin
            @(negedge clk); activate_buffer=b; activate_epoch=e;
            activate_group=g; activate_valid=1;
            #1; if (!activate_ready) fail("KV activate blocked");
            tick(); @(negedge clk); activate_valid=0;
        end
    endtask

    task automatic q_need(input logic [15:0] e, input logic [2:0] g,
                          input logic [4:0] h, input logic [2:0] w,
                          output logic b);
        begin
            @(negedge clk); q_slab_need_epoch=e; q_slab_need_group=g;
            q_slab_need_global_q_head=h; q_slab_need_row_window=w;
            q_slab_need_valid=1;
            #1; if (!q_slab_need_ready) fail("legal Q need blocked");
            tick();
            if (!q_fill_valid || q_fill_epoch!=e || q_fill_group!=g ||
                q_fill_global_q_head!=h || q_fill_row_window!=w)
                fail("Q fill reservation token mismatch");
            b=q_fill_buffer;
            @(negedge clk); q_slab_need_valid=0;
            if ((h==0) && (w==0)) begin
                q_publish_buffer=b; q_publish_epoch=e; q_publish_group=g;
                q_publish_global_q_head=h; q_publish_row_window=w;
                q_publish_valid=1; #1;
                if (q_publish_ready)
                    fail("Q publish accepted before q_fill issued");
                tick(); @(negedge clk); q_publish_valid=0;
            end
            repeat ($urandom_range(0,3)) begin
                #1;
                if (!q_fill_valid || q_fill_buffer!=b || q_fill_epoch!=e ||
                    q_fill_group!=g || q_fill_global_q_head!=h ||
                    q_fill_row_window!=w)
                    fail("q_fill payload changed under backpressure");
                tick(); @(negedge clk);
            end
            q_fill_ready=1; #1;
            if (!q_fill_valid) fail("q_fill descriptor missing at transfer");
            tick();
            if (q_fill_valid) fail("q_fill descriptor transferred twice");
            @(negedge clk); q_fill_ready=0;
        end
    endtask

    task automatic q_publish(input logic b, input logic [15:0] e,
                             input logic [2:0] g, input logic [4:0] h,
                             input logic [2:0] w);
        begin
            @(negedge clk); q_publish_buffer=b; q_publish_epoch=e;
            q_publish_group=g; q_publish_global_q_head=h;
            q_publish_row_window=w; q_publish_valid=1;
            #1; if (!q_publish_ready) fail("legal Q publish blocked");
            tick(); @(negedge clk); q_publish_valid=0;
        end
    endtask

    task automatic q_activate(input logic [15:0] e, input logic [2:0] g,
                              input logic [4:0] h, input logic [2:0] w,
                              output logic b);
        begin
            repeat ($urandom_range(0,3)) begin
                @(negedge clk); #1;
                if (!q_slab_ready_valid || q_slab_ready_epoch!=e ||
                    q_slab_ready_group!=g ||
                    q_slab_ready_global_q_head!=h ||
                    q_slab_ready_row_window!=w)
                    fail("Q ready payload changed under backpressure");
                tick();
            end
            @(negedge clk); q_slab_ready_ready=1; #1;
            if (!q_slab_ready_valid || q_slab_ready_epoch!=e ||
                q_slab_ready_group!=g || q_slab_ready_global_q_head!=h ||
                q_slab_ready_row_window!=w)
                fail("Q ready token mismatch");
            b=q_slab_ready_buffer;
            tick(); @(negedge clk); q_slab_ready_ready=0;
        end
    endtask

    task automatic q_retire(input logic b, input logic [15:0] e,
                            input logic [2:0] g, input logic [4:0] h,
                            input logic [2:0] w, input logic expect_wait);
        begin
            @(negedge clk); q_slab_retire_buffer=b; q_slab_retire_epoch=e;
            q_slab_retire_group=g; q_slab_retire_global_q_head=h;
            q_slab_retire_row_window=w; q_slab_retire_valid=1; #1;
            if (expect_wait && q_slab_retire_ready)
                fail("early Q retire accepted with outstanding response");
            while (!q_slab_retire_ready) tick();
            tick(); @(negedge clk); q_slab_retire_valid=0;
        end
    endtask

    function automatic [15:0] q_pattern(
        input integer h, input integer w, input integer c, input integer d);
        q_pattern = 16'h3000 ^ (h << 11) ^ (w << 8) ^ (c << 4) ^ d;
    endfunction

    function automatic [15:0] k_pattern(input integer key, input integer d);
        k_pattern = 16'h1000 + key*128 + d;
    endfunction

    function automatic [15:0] v_pattern(input integer key, input integer d);
        v_pattern = 16'h8000 + key*128 + d;
    endfunction

    task automatic q_fill_complete(
        input logic b, input logic [15:0] e, input logic [2:0] g,
        input logic [4:0] h, input logic [2:0] w);
        integer n, c, d;
        begin
            for (n=0;n<2048;n=n+1) begin
                c=n/128; d=n%128;
                @(negedge clk); load_buffer=b; load_epoch=e; load_group=g;
                load_global_q_head=h; load_row_window=w; load_kind=0;
                load_context_tag=c[3:0]; load_key=0; load_d=d[6:0];
                load_data_bf16=q_pattern(h,w,c,d); load_valid=1; #1;
                if (!load_ready) fail("Q slab blocked before word 2048");
                tick();
            end
            @(negedge clk); load_valid=0;
        end
    endtask

    task automatic kv_fill_kind_complete(
        input logic b, input logic [15:0] e, input logic [2:0] g,
        input logic [1:0] kind);
        integer n, key, d;
        begin
            for (n=0;n<16384;n=n+1) begin
                key=n/128; d=n%128;
                @(negedge clk); load_buffer=b; load_epoch=e; load_group=g;
                load_global_q_head=0; load_row_window=0; load_kind=kind;
                load_context_tag=0; load_key=key[6:0]; load_d=d[6:0];
                if (kind==1) load_data_bf16=k_pattern(key,d);
                else load_data_bf16=v_pattern(key,d);
                load_valid=1; #1;
                if (!load_ready) fail("K/V half blocked before word 16384");
                tick();
            end
            @(negedge clk); load_valid=0;
        end
    endtask

    integer i, head_i, win_i;
    logic cur_b, next_b;
    initial begin
        prep_valid=0; prep_buffer=0; prep_epoch=0; prep_group=0;
        load_valid=0; load_buffer=0; load_epoch=0; load_group=0;
        load_global_q_head=0; load_row_window=0; load_kind=0;
        load_context_tag=0; load_key=0; load_d=0; load_data_bf16=0;
        publish_valid=0; publish_buffer=0; publish_epoch=0; publish_group=0;
        activate_valid=0; activate_buffer=0; activate_epoch=0; activate_group=0;
        q_slab_need_valid=0; q_slab_need_epoch=0; q_slab_need_group=0;
        q_slab_need_global_q_head=0; q_slab_need_row_window=0;
        q_fill_ready=0;
        q_publish_valid=0; q_publish_buffer=0; q_publish_epoch=0;
        q_publish_group=0; q_publish_global_q_head=0; q_publish_row_window=0;
        q_slab_ready_ready=0; q_slab_retire_valid=0;
        q_slab_retire_buffer=0; q_slab_retire_epoch=0;
        q_slab_retire_group=0; q_slab_retire_global_q_head=0;
        q_slab_retire_row_window=0;
        q_req_valid=0; q_req_context_tag=0; q_req_d=0;
        k_req_valid=0; k_req_context_tag=0; k_req_key_block=0; k_req_d=0;
        v_req_valid=0; v_req_context_tag=0; v_req_key=0;
        v_req_feature_block=0;

        repeat (3) tick(); rst_n=1; tick();

        // Physically write every word in the paired K/V half.  A matching
        // publish before V is complete is ordinary ready/valid backpressure.
        kv_prepare(0,16'h101,0);
        kv_fill_kind_complete(0,16'h101,0,1);
        @(negedge clk); publish_buffer=0; publish_epoch=16'h101;
        publish_group=0; publish_valid=1; #1;
        if (publish_ready) fail("incomplete K/V publish accepted");
        tick(); @(negedge clk); publish_valid=0;
        kv_fill_kind_complete(0,16'h101,0,2);

        // The 16385th V word is blocked.
        @(negedge clk); load_buffer=0; load_epoch=16'h101; load_group=0;
        load_kind=2; load_key=0; load_d=0; load_valid=1; #1;
        if (load_ready) fail("K/V count overflow accepted");
        tick(); @(negedge clk); load_valid=0;
        kv_publish(0,16'h101,0);
        kv_activate(0,16'h101,0);
        if (!active_valid || active_buffer!=0 || active_epoch!=16'h101 ||
            active_group!=0) fail("KV active identity mismatch");

        // Stale-epoch need must be rejected and counted.
        @(negedge clk); q_slab_need_epoch=16'h100; q_slab_need_group=0;
        q_slab_need_global_q_head=0; q_slab_need_row_window=0;
        q_slab_need_valid=1; #1;
        if (q_slab_need_ready) fail("stale Q need accepted");
        tick(); @(negedge clk); q_slab_need_valid=0;

        // q_fill descriptor delivery is separately backpressured and issued
        // exactly once.  Publish waits for all 2048 scalar BF16 writes.
        q_need(16'h101,0,0,0,cur_b);
        @(negedge clk); q_publish_buffer=cur_b; q_publish_epoch=16'h101;
        q_publish_group=0; q_publish_global_q_head=0;
        q_publish_row_window=0; q_publish_valid=1; #1;
        if (q_publish_ready) fail("short Q slab published");
        tick(); @(negedge clk); q_publish_valid=0;
        q_fill_complete(cur_b,16'h101,0,0,0);

        // The 2049th Q word is blocked.
        @(negedge clk); load_buffer=cur_b; load_epoch=16'h101;
        load_group=0; load_global_q_head=0; load_row_window=0;
        load_kind=0; load_context_tag=0; load_d=0; load_valid=1; #1;
        if (load_ready) fail("Q count overflow accepted");
        tick(); @(negedge clk); load_valid=0;

        // A publish with the wrong epoch is rejected without changing state.
        @(negedge clk); q_publish_buffer=cur_b; q_publish_epoch=16'h102;
        q_publish_group=0; q_publish_global_q_head=0;
        q_publish_row_window=0; q_publish_valid=1; #1;
        if (q_publish_ready) fail("stale Q publish accepted");
        tick(); @(negedge clk); q_publish_valid=0;
        q_publish(cur_b,16'h101,0,0,0);
        q_activate(16'h101,0,0,0,cur_b);

        // Q active-write protection is independent of the still-active K/V
        // selector.  The next Q half can nevertheless be filled and published.
        @(negedge clk); load_buffer=cur_b; load_epoch=16'h101; load_group=0;
        load_global_q_head=0; load_row_window=0; load_kind=0;
        load_context_tag=1; load_d=5; load_data_bf16=16'hdead;
        load_valid=1; #1; if (load_ready) fail("active Q overwrite accepted");
        tick(); @(negedge clk); load_valid=0;

        q_need(16'h101,0,0,1,next_b);
        if (next_b==cur_b || active_buffer!=0)
            fail("Q/KV selectors are not independent");
        q_fill_complete(next_b,16'h101,0,0,1);

        // Wrong-token retire and duplicate need are both rejected.
        @(negedge clk); q_slab_retire_buffer=cur_b;
        q_slab_retire_epoch=16'h101; q_slab_retire_group=0;
        q_slab_retire_global_q_head=0; q_slab_retire_row_window=7;
        q_slab_retire_valid=1; #1;
        if (q_slab_retire_ready) fail("mismatched retire accepted");
        tick(); @(negedge clk); q_slab_retire_valid=0;

        q_publish(next_b,16'h101,0,0,1);

        // Q/K/V accept concurrently; Q accepts again on N+1.  Responses are
        // absent at N/N+1 and present exactly at N+2.
        @(negedge clk); q_req_valid=1; q_req_context_tag=1; q_req_d=5;
        k_req_valid=1; k_req_context_tag=4'ha; k_req_key_block=1; k_req_d=9;
        v_req_valid=1; v_req_context_tag=4'hb; v_req_key=7;
        v_req_feature_block=2; #1;
        if (!q_req_ready || !k_req_ready || !v_req_ready)
            fail("concurrent service request blocked");
        tick(); if (q_rsp_valid || k_rsp_valid || v_rsp_valid)
            fail("response arrived at N");
        @(negedge clk); q_req_context_tag=2; q_req_d=6;
        k_req_valid=0; v_req_valid=0; #1;
        if (!q_req_ready) fail("Q II=1 failed");
        tick(); if (q_rsp_valid || k_rsp_valid || v_rsp_valid)
            fail("response arrived at N+1");
        @(negedge clk); q_req_valid=0;
        tick();
        if (!q_rsp_valid || q_rsp_context_tag!=1 ||
            q_rsp_bf16!=q_pattern(0,0,1,5))
            fail("Q N+2 response mismatch");
        if (!k_rsp_valid || !v_rsp_valid || k_rsp_context_tag!=4'ha ||
            v_rsp_context_tag!=4'hb) fail("K/V N+2 tag mismatch");
        for (i=0;i<32;i=i+1) begin
            if (k_rsp_vec[i*16 +:16] != k_pattern(32+i,9))
                fail("K key-bank vector mismatch");
            if (v_rsp_vec[i*16 +:16] != v_pattern(7,64+i))
                fail("V feature-bank vector mismatch");
        end
        tick();
        if (!q_rsp_valid || q_rsp_context_tag!=2 ||
            q_rsp_bf16!=q_pattern(0,0,2,6))
            fail("consecutive Q response mismatch");
        tick();
        q_retire(cur_b,16'h101,0,0,0,0);
        q_activate(16'h101,0,0,1,cur_b);

        // A retired token cannot be requested again even with a free half.
        @(negedge clk); q_slab_need_epoch=16'h101; q_slab_need_group=0;
        q_slab_need_global_q_head=0; q_slab_need_row_window=0;
        q_slab_need_valid=1; #1;
        if (q_slab_need_ready) fail("duplicate Q token accepted");
        tick(); @(negedge clk); q_slab_need_valid=0;

        // Token 1 early-retire: acceptance must wait for its response.
        q_need(16'h101,0,0,2,next_b);
        q_fill_complete(next_b,16'h101,0,0,2);
        q_publish(next_b,16'h101,0,0,2);
        @(negedge clk); q_req_valid=1; q_req_context_tag=1; q_req_d=5;
        #1; if (!q_req_ready) fail("token1 Q request blocked");
        tick(); @(negedge clk); q_req_valid=0;
        q_retire(cur_b,16'h101,0,0,1,1);
        if (q_slab_early_retire_error!=1)
            fail("outstanding-only retire was misclassified as early error");
        q_activate(16'h101,0,0,2,cur_b);

        // q_req_valid concurrent with retire is the true early-retire case.
        @(negedge clk); q_req_valid=1; q_req_context_tag=1; q_req_d=5;
        q_slab_retire_buffer=cur_b; q_slab_retire_epoch=16'h101;
        q_slab_retire_group=0; q_slab_retire_global_q_head=0;
        q_slab_retire_row_window=2; q_slab_retire_valid=1; #1;
        if (q_req_ready || q_slab_retire_ready)
            fail("request/retire overlap transferred");
        tick(); @(negedge clk); q_req_valid=0; q_slab_retire_valid=0;
        tick();

        // Finish the representative 32-slab/group sequence.  Every current
        // slab is active while the next is filled into the opposite half.
        for (i=2;i<32;i=i+1) begin
            head_i=i/8; win_i=i%8;
            if (i<31) begin
                repeat ($urandom_range(0,2)) tick();
                q_need(16'h101,0,(i+1)/8,(i+1)%8,next_b);
                if (next_b==cur_b || active_buffer!=0)
                    fail("ping/pong selector coupling detected");
                q_fill_complete(next_b,16'h101,0,(i+1)/8,(i+1)%8);
                q_publish(next_b,16'h101,0,(i+1)/8,(i+1)%8);
            end
            q_retire(cur_b,16'h101,0,head_i,win_i,0);
            if (i<31)
                q_activate(16'h101,0,(i+1)/8,(i+1)%8,cur_b);
        end

        if (q_slab_need_count!=32 || q_slab_fill_count!=32 ||
            q_slab_ready_count!=32 || q_slab_activate_count!=32 ||
            q_slab_retire_count!=32)
            fail("32-slab lifecycle counters do not close");
        if (q_requests_accepted!=3 || k_requests_accepted!=1 ||
            v_requests_accepted!=1 || q_slab_outstanding_max<2)
            fail("request/outstanding counters mismatch");
        if (q_slab_overwrite_error!=1 || q_slab_early_retire_error!=2 ||
            q_slab_epoch_error<2 ||
            q_slab_tag_error<2 || !protocol_error_sticky)
            fail("independent error counters mismatch");

        $display("PASS: CATS_R4_IF_V2 Q/KV ownership, 32 slabs, N+2/II1");
        $finish;
    end
endmodule
