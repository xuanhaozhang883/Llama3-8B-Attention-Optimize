`timescale 1ns/1ps

module tb_cats_r4_qk_q_slab_client;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;

    logic job_valid, job_ready;
    logic [15:0] job_epoch;
    logic [2:0] job_group;
    logic [4:0] job_global_q_head;
    logic [2:0] job_row_window;

    logic q_slab_need_valid, q_slab_need_ready;
    logic [15:0] q_slab_need_epoch;
    logic [2:0] q_slab_need_group;
    logic [4:0] q_slab_need_global_q_head;
    logic [2:0] q_slab_need_row_window;

    logic q_slab_ready_valid, q_slab_ready_ready;
    logic [15:0] q_slab_ready_epoch;
    logic [2:0] q_slab_ready_group;
    logic [4:0] q_slab_ready_global_q_head;
    logic [2:0] q_slab_ready_row_window;
    logic q_slab_ready_buffer;

    logic engine_start_valid, engine_start_ready;
    logic [15:0] engine_start_epoch;
    logic [2:0] engine_start_group;
    logic [4:0] engine_start_global_q_head;
    logic [2:0] engine_start_row_window;
    logic [3:0] engine_start_row_offset;
    logic [4:0] engine_start_row_count;
    logic [1:0] engine_start_key_block;
    logic engine_start_q_buffer;

    logic engine_done_valid, engine_done_ready;
    logic [15:0] engine_done_epoch;
    logic [2:0] engine_done_group;
    logic [4:0] engine_done_global_q_head;
    logic [2:0] engine_done_row_window;
    logic [3:0] engine_done_row_offset;
    logic [4:0] engine_done_row_count;
    logic [1:0] engine_done_key_block;
    logic engine_done_error;

    logic q_slab_retire_valid, q_slab_retire_ready;
    logic [15:0] q_slab_retire_epoch;
    logic [2:0] q_slab_retire_group;
    logic [4:0] q_slab_retire_global_q_head;
    logic [2:0] q_slab_retire_row_window;
    logic q_slab_retire_buffer;

    logic [63:0] jobs_accepted, q_slab_needs_transferred;
    logic [63:0] q_slab_ready_transferred, engine_jobs_started;
    logic [63:0] engine_jobs_completed, q_slab_retires_transferred;
    logic [63:0] protocol_errors, epoch_drops;
    logic protocol_error_sticky;

    cats_r4_qk_q_slab_client dut (.*);

    task automatic tick; @(posedge clk); #1; endtask

    task automatic send_done(
        input logic [3:0] row_offset,
        input logic [4:0] row_count,
        input logic [1:0] key_block
    );
        begin
            @(negedge clk);
            engine_done_valid = 1;
            engine_done_epoch = 16'h3303;
            engine_done_group = 3'd2;
            engine_done_global_q_head = 5'd9;
            engine_done_row_window = 3'd5;
            engine_done_row_offset = row_offset;
            engine_done_row_count = row_count;
            engine_done_key_block = key_block;
            engine_done_error = 0;
            #1;
            if (!engine_done_ready)
                $fatal(1, "engine done not accepted key_block=%0d", key_block);
            tick();
            @(negedge clk); engine_done_valid = 0;
        end
    endtask

    integer kb, batch_offset, batch_count, full_head, full_window;
    initial begin
        job_valid = 0;
        job_epoch = 16'h3303;
        job_group = 3'd2;
        job_global_q_head = 5'd9;
        job_row_window = 3'd5;
        q_slab_need_ready = 0;
        q_slab_ready_valid = 0;
        q_slab_ready_epoch = 16'h3303;
        q_slab_ready_group = 3'd2;
        q_slab_ready_global_q_head = 5'd9;
        q_slab_ready_row_window = 3'd5;
        q_slab_ready_buffer = 1;
        engine_start_ready = 0;
        engine_done_valid = 0;
        engine_done_row_offset = 0;
        engine_done_row_count = 0;
        q_slab_retire_ready = 0;

        repeat (3) tick();
        rst_n = 1;
        @(negedge clk); job_valid = 1;
        #1;
        if (!job_ready) $fatal(1, "legal Q-slab job not accepted");
        tick();
        @(negedge clk); job_valid = 0;

        repeat (3) begin
            tick();
            if (!q_slab_need_valid || q_slab_need_epoch !== 16'h3303 ||
                q_slab_need_group !== 2 || q_slab_need_global_q_head !== 9 ||
                q_slab_need_row_window !== 5)
                $fatal(1, "q_slab_need changed under backpressure");
        end
        q_slab_need_ready = 1;
        tick();
        q_slab_need_ready = 0;

        if (!q_slab_ready_ready || engine_start_valid)
            $fatal(1, "client did not wait for Q-slab ready token");
        // A stale completion is consumed and dropped, but cannot activate a
        // buffer or advance the engine-start sequence.
        q_slab_ready_epoch = 16'h3302;
        @(negedge clk); q_slab_ready_valid = 1;
        tick();
        @(negedge clk); q_slab_ready_valid = 0;
        #1;
        if (engine_start_valid || !q_slab_ready_ready ||
            protocol_errors !== 1 || epoch_drops !== 1)
            $fatal(1, "stale Q-slab ready token was not dropped");
        q_slab_ready_epoch = 16'h3303;
        @(negedge clk); q_slab_ready_valid = 1;
        tick();
        @(negedge clk); q_slab_ready_valid = 0;

        for (batch_offset = 0; batch_offset < 16;
             batch_offset = batch_offset + 3) begin
          batch_count = ((16 - batch_offset) < 3) ?
                        (16 - batch_offset) : 3;
          for (kb = 0; kb < 4; kb = kb + 1) begin
              repeat (2) begin
                  tick();
                  if (!engine_start_valid || engine_start_key_block !== kb ||
                      engine_start_row_offset !== batch_offset ||
                      engine_start_row_count !== batch_count ||
                      engine_start_epoch !== 16'h3303 ||
                      engine_start_group !== 2 || engine_start_global_q_head !== 9 ||
                      engine_start_row_window !== 5 || !engine_start_q_buffer)
                      $fatal(1, "engine start changed under backpressure offset=%0d key_block=%0d",
                             batch_offset, kb);
              end
              engine_start_ready = 1;
              tick();
              engine_start_ready = 0;
              if (batch_offset == 0 && kb == 0) begin
                @(negedge clk);
                engine_done_valid = 1;
                engine_done_epoch = 16'h3302;
                engine_done_group = 3'd2;
                engine_done_global_q_head = 5'd9;
                engine_done_row_window = 3'd5;
                engine_done_row_offset = 0;
                engine_done_row_count = 3;
                engine_done_key_block = 0;
                engine_done_error = 0;
                #1;
                if (!engine_done_ready)
                    $fatal(1, "stale engine completion could not be consumed");
                tick();
                @(negedge clk); engine_done_valid = 0;
                #1;
                if (!engine_done_ready || engine_start_valid ||
                    engine_jobs_completed !== 0 || protocol_errors !== 2 ||
                    epoch_drops !== 2)
                    $fatal(1, "stale engine completion advanced the lifecycle");
              end
              send_done(batch_offset[3:0], batch_count[4:0], kb[1:0]);
          end
        end

        repeat (3) begin
            tick();
            if (!q_slab_retire_valid || q_slab_retire_epoch !== 16'h3303 ||
                q_slab_retire_group !== 2 ||
                q_slab_retire_global_q_head !== 9 ||
                q_slab_retire_row_window !== 5 || !q_slab_retire_buffer)
                $fatal(1, "q_slab_retire changed under backpressure");
        end
        q_slab_retire_ready = 1;
        tick();

        if (jobs_accepted !== 1 || q_slab_needs_transferred !== 1 ||
            q_slab_ready_transferred !== 1 || engine_jobs_started !== 24 ||
            engine_jobs_completed !== 24 || q_slab_retires_transferred !== 1 ||
            protocol_errors !== 2 || epoch_drops !== 2 ||
            !protocol_error_sticky || !job_ready)
            $fatal(1, "Q-slab lifecycle counters/state mismatch");

        counter_clear = 1; tick(); counter_clear = 0;
        q_slab_need_ready = 1;
        engine_start_ready = 1;
        q_slab_retire_ready = 1;
        for (full_head=0; full_head<32; full_head=full_head+1) begin
            for (full_window=0; full_window<8; full_window=full_window+1) begin
                @(negedge clk);
                job_epoch=16'h8808; job_group=full_head>>2;
                job_global_q_head=full_head; job_row_window=full_window;
                job_valid=1; #1; if(!job_ready)$fatal(1,"full Q job rejected");
                tick(); @(negedge clk); job_valid=0;
                tick();
                @(negedge clk);
                q_slab_ready_epoch=16'h8808; q_slab_ready_group=full_head>>2;
                q_slab_ready_global_q_head=full_head;
                q_slab_ready_row_window=full_window;
                q_slab_ready_buffer=(full_head+full_window)&1;
                q_slab_ready_valid=1; tick();
                @(negedge clk); q_slab_ready_valid=0;
                for(batch_offset=0;batch_offset<16;batch_offset=batch_offset+3) begin
                  batch_count=((16-batch_offset)<3)?(16-batch_offset):3;
                  for(kb=0;kb<4;kb=kb+1) begin
                      tick();
                      if(engine_start_row_offset!==batch_offset ||
                         engine_start_row_count!==batch_count ||
                         engine_start_key_block!==kb)
                          $fatal(1,"full Q-slab launch sequence mismatch");
                      @(negedge clk);
                      engine_done_epoch=16'h8808;engine_done_group=full_head>>2;
                      engine_done_global_q_head=full_head;
                      engine_done_row_window=full_window;
                      engine_done_row_offset=batch_offset;
                      engine_done_row_count=batch_count;
                      engine_done_key_block=kb;engine_done_error=0;
                      engine_done_valid=1;tick();
                      @(negedge clk);engine_done_valid=0;
                  end
                end
                tick();
            end
        end
        if(jobs_accepted!==256||q_slab_needs_transferred!==256||
           q_slab_ready_transferred!==256||engine_jobs_started!==6144||
           engine_jobs_completed!==6144||q_slab_retires_transferred!==256||
           protocol_errors!==0||epoch_drops!==0||protocol_error_sticky)
            $fatal(1,"full Q-slab closure mismatch need=%0d ready=%0d start=%0d done=%0d retire=%0d",
                   q_slab_needs_transferred,q_slab_ready_transferred,
                   engine_jobs_started,engine_jobs_completed,q_slab_retires_transferred);

        $display("PASS: CATS-R4 A Q-slab full lifecycle slabs=256 engine_jobs=6144");
        $finish;
    end
endmodule
