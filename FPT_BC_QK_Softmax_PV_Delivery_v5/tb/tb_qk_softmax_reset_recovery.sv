`timescale 1ns/1ps

// Mid-operation synchronous reset recovery test for:
//   1) partially-filled row-tile buffer
//   2) Softmax EXP/sum processing
//   3) stalled Softmax output (prob_valid=1, prob_ready=0)
//
// Important TB rule:
//   qk_valid/qk_* are driven only by the sender task while a sender is active.
//   Reset control requests the sender to stop, rather than killing a forked
//   sender thread with "disable". This avoids leaving qk_valid stuck high.
module tb_qk_softmax_reset_recovery;
    localparam int SEQ_LEN = 8;
    localparam int TILE    = 4;
    localparam int Q_HEADS = 2;
    localparam int HEAD_W  = 1;
    localparam int POS_W   = 3;
    localparam int TOTAL   = Q_HEADS * SEQ_LEN * SEQ_LEN;

    parameter EXP_LUT_FILE = "exp_lut_q15.mem";

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;

    logic                 qk_valid;
    logic                 qk_ready;
    logic [15:0]          qk_score;
    logic [HEAD_W-1:0]    qk_head;
    logic [POS_W-1:0]     qk_row;
    logic [POS_W-1:0]     qk_col;
    logic                 qk_global_last;

    logic                 prob_valid;
    logic                 prob_ready;
    logic [15:0]          prob_data;
    logic                 prob_first;
    logic                 prob_last;
    logic                 prob_global_last;
    logic                 pipeline_done;
    logic [HEAD_W-1:0]    prob_head;
    logic [POS_W-1:0]     prob_row;
    logic [POS_W-1:0]     prob_col;

    logic                 busy;
    logic                 adapter_protocol_error;
    logic                 adapter_global_last_error;
    logic                 softmax_row_error;
    logic                 softmax_metadata_error;

    // Packed as:
    // {global_last[32], head[31:30], row[29:23], col[22:16], score[15:0]}
    logic [32:0] stream_mem [0:TOTAL-1];

    integer recv_count;
    integer row_count;
    integer done_count;
    integer phase;
    real    row_sum;

    // Sender-control signals belong to the testbench only.
    logic sender_abort;
    logic sender_active;

    qk_softmax_frontend #(
        .SEQ_LEN     (SEQ_LEN),
        .TILE        (TILE),
        .Q_HEADS     (Q_HEADS),
        .HEAD_W      (HEAD_W),
        .POS_W       (POS_W),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) dut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .causal_en                (1'b1),

        .qk_valid                 (qk_valid),
        .qk_ready                 (qk_ready),
        .qk_score                 (qk_score),
        .qk_head                  (qk_head),
        .qk_row                   (qk_row),
        .qk_col                   (qk_col),
        .qk_global_last           (qk_global_last),

        .prob_valid               (prob_valid),
        .prob_ready               (prob_ready),
        .prob_data                (prob_data),
        .prob_first               (prob_first),
        .prob_last                (prob_last),
        .prob_global_last         (prob_global_last),
        .prob_head                (prob_head),
        .prob_row                 (prob_row),
        .prob_col                 (prob_col),
        .pipeline_done            (pipeline_done),

        .busy                     (busy),
        .adapter_protocol_error   (adapter_protocol_error),
        .adapter_global_last_error(adapter_global_last_error),
        .softmax_row_error        (softmax_row_error),
        .softmax_metadata_error   (softmax_metadata_error)
    );

    function automatic real pow2_real(input integer exponent);
        real v;
        integer i;
        begin
            v = 1.0;
            if (exponent >= 0) begin
                for (i = 0; i < exponent; i = i + 1)
                    v = v * 2.0;
            end else begin
                for (i = 0; i < (-exponent); i = i + 1)
                    v = v / 2.0;
            end
            pow2_real = v;
        end
    endfunction

    function automatic real bf16_to_real(input logic [15:0] b);
        integer e;
        integer f;
        real m;
        real v;
        begin
            e = b[14:7];
            f = b[6:0];
            if ((e == 0) && (f == 0)) begin
                v = 0.0;
            end else begin
                m = 1.0 + f / 128.0;
                v = m * pow2_real(e - 127);
            end
            bf16_to_real = b[15] ? -v : v;
        end
    endfunction

    function automatic real abs_real(input real x);
        begin
            abs_real = (x < 0.0) ? -x : x;
        end
    endfunction

    // Drive an idle input source. Call only when sender_active == 0.
    task automatic drive_qk_idle;
        begin
            qk_valid       = 1'b0;
            qk_score       = 16'h0000;
            qk_head        = '0;
            qk_row         = '0;
            qk_col         = '0;
            qk_global_last = 1'b0;
        end
    endtask

    // The only task that drives qk_valid/qk payload during traffic.
    // When sender_abort or reset is observed, it exits cleanly and explicitly
    // returns the source interface to idle before lowering sender_active.
    task automatic send_items_abortable(input integer count);
        integer i;
        logic accepted;
        begin : sender_body
            if (sender_active)
                $fatal(1, "Attempted to start a second QK sender");

            sender_active = 1'b1;

            for (i = 0; i < count; i = i + 1) begin
                @(negedge clk);

                if (sender_abort || !rst_n)
                    disable sender_body;

                qk_valid       = 1'b1;
                qk_score       = stream_mem[i][15:0];
                qk_col         = stream_mem[i][22:16];
                qk_row         = stream_mem[i][29:23];
                qk_head        = stream_mem[i][31:30];
                qk_global_last = stream_mem[i][32];

                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (sender_abort || !rst_n)
                        disable sender_body;
                    if (qk_valid && qk_ready)
                        accepted = 1'b1;
                end
            end

            @(negedge clk);
            drive_qk_idle();
            sender_active = 1'b0;
        end
    endtask

    // Cleanup path used when disable sender_body exits the main task body.
    // SystemVerilog does not provide a finally block, so this wrapper always
    // restores the source interface after the abortable body returns.
    task automatic run_sender(input integer count);
        begin
            send_items_abortable(count);

            // If the normal tail of send_items_abortable was skipped by
            // disable sender_body, perform deterministic cleanup here.
            if (sender_active) begin
                @(negedge clk);
                drive_qk_idle();
                sender_active = 1'b0;
            end
        end
    endtask

    // Assert synchronous active-low reset and request an active sender to stop.
    // This task never drives qk_valid directly, preventing multiple TB drivers.
    task automatic abort_sender_and_hold_reset;
        begin
            @(negedge clk);
            sender_abort = 1'b1;
            rst_n        = 1'b0;

            // Hold reset through at least three rising edges.
            repeat (3) @(posedge clk);

            // The sender must have observed abort/reset and cleaned up.
            wait (sender_active == 1'b0);
        end
    endtask

    task automatic release_reset_and_check;
        begin
            if (sender_active)
                $fatal(1, "Sender still active before reset release in phase %0d", phase);
            if (qk_valid)
                $fatal(1, "qk_valid still high before reset release in phase %0d", phase);

            @(negedge clk);
            sender_abort = 1'b0;
            rst_n        = 1'b1;

            // Sample after NBA updates have settled.
            repeat (2) @(posedge clk);
            #1;

            if (busy || prob_valid) begin
                $fatal(1,
                    "Pipeline not clean after reset in phase %0d: busy=%b prob_valid=%b qk_valid=%b sender_active=%b",
                    phase, busy, prob_valid, qk_valid, sender_active);
            end

            if (adapter_protocol_error || adapter_global_last_error ||
                softmax_row_error || softmax_metadata_error) begin
                $fatal(1,
                    "Error flag not cleared after reset in phase %0d: protocol=%b global_last=%b row=%b metadata=%b",
                    phase, adapter_protocol_error, adapter_global_last_error,
                    softmax_row_error, softmax_metadata_error);
            end

            if (!qk_ready)
                $fatal(1, "qk_ready not restored after reset in phase %0d", phase);

            $display("INFO: phase %0d reset cleanup check passed", phase);
        end
    endtask

    task automatic pulse_reset;
        begin
            abort_sender_and_hold_reset();
            release_reset_and_check();
        end
    endtask

    task automatic complete_run;
        begin
            sender_abort = 1'b0;

            fork
                run_sender(TOTAL);
                begin
                    wait (recv_count == TOTAL);
                end
            join

            repeat (4) @(posedge clk);
            #1;

            if (row_count != Q_HEADS * SEQ_LEN)
                $fatal(1, "Reset recovery row count=%0d phase=%0d", row_count, phase);
            if (done_count != 1)
                $fatal(1, "Reset recovery pipeline_done count=%0d phase=%0d", done_count, phase);
            if (busy || prob_valid)
                $fatal(1, "Pipeline not idle after complete run in phase %0d", phase);
            if (adapter_protocol_error || adapter_global_last_error ||
                softmax_row_error || softmax_metadata_error)
                $fatal(1, "Error flag after recovered complete run in phase %0d", phase);

            $display("INFO: phase %0d recovered complete run passed", phase);
        end
    endtask

    // Output checker and per-run counters. Resetting rst_n clears all counters,
    // so each recovery run is independently checked from output index zero.
    always @(posedge clk) begin
        integer eh;
        integer er;
        integer ec;

        if (!rst_n) begin
            recv_count = 0;
            row_count  = 0;
            done_count = 0;
            row_sum    = 0.0;
        end else if (prob_valid && prob_ready) begin
            eh = recv_count / (SEQ_LEN * SEQ_LEN);
            er = (recv_count / SEQ_LEN) % SEQ_LEN;
            ec = recv_count % SEQ_LEN;

            if ((prob_head !== eh[HEAD_W-1:0]) ||
                (prob_row  !== er[POS_W-1:0])  ||
                (prob_col  !== ec[POS_W-1:0])) begin
                $fatal(1,
                    "Reset recovery metadata mismatch phase=%0d index=%0d got=(%0d,%0d,%0d) expected=(%0d,%0d,%0d)",
                    phase, recv_count, prob_head, prob_row, prob_col, eh, er, ec);
            end

            if ((prob_first !== (ec == 0)) ||
                (prob_last  !== (ec == SEQ_LEN-1))) begin
                $fatal(1,
                    "Reset recovery row marker mismatch phase=%0d index=%0d first=%b last=%b",
                    phase, recv_count, prob_first, prob_last);
            end

            if ((ec > er) && (prob_data !== 16'h0000))
                $fatal(1, "Reset recovery masked output nonzero phase=%0d index=%0d", phase, recv_count);

            row_sum = row_sum + bf16_to_real(prob_data);

            if (ec == SEQ_LEN-1) begin
                if (abs_real(row_sum - 1.0) > 0.02)
                    $fatal(1, "Reset recovery row sum=%f phase=%0d row=%0d", row_sum, phase, er);
                row_sum   = 0.0;
                row_count = row_count + 1;
            end

            if (pipeline_done)
                done_count = done_count + 1;

            recv_count = recv_count + 1;
        end
    end

    initial begin
        integer h;
        integer rb;
        integer cb;
        integer lr;
        integer lc;
        integer idx;
        integer r;
        integer c;

        idx = 0;
        for (h = 0; h < Q_HEADS; h = h + 1) begin
            for (rb = 0; rb < SEQ_LEN; rb = rb + TILE) begin
                for (cb = 0; cb < SEQ_LEN; cb = cb + TILE) begin
                    for (lr = 0; lr < TILE; lr = lr + 1) begin
                        for (lc = 0; lc < TILE; lc = lc + 1) begin
                            r = rb + lr;
                            c = cb + lc;
                            stream_mem[idx] = {
                                ((h == Q_HEADS-1) &&
                                 (r == SEQ_LEN-1) &&
                                 (c == SEQ_LEN-1)),
                                h[1:0], r[6:0], c[6:0], 16'h0000
                            };
                            idx = idx + 1;
                        end
                    end
                end
            end
        end

        rst_n         = 1'b0;
        prob_ready    = 1'b1;
        phase         = 0;
        sender_abort  = 1'b0;
        sender_active = 1'b0;
        drive_qk_idle();

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        // ------------------------------------------------------------
        // Phase 1: reset while the row-tile buffer is partially filled.
        // ------------------------------------------------------------
        phase = 1;
        $display("INFO: phase 1 - reset during partial buffer fill");
        run_sender(10);
        pulse_reset();
        complete_run();
        pulse_reset();

        // ------------------------------------------------------------
        // Phase 2: reset while Softmax is processing EXP/sum work.
        // ------------------------------------------------------------
        phase = 2;
        $display("INFO: phase 2 - reset during Softmax EXP processing");
        sender_abort = 1'b0;

        fork
            run_sender(TOTAL);
            begin
                // ST_EXP remains enum value 4'd1 in softmax_bf16.sv.
                wait (dut.u_softmax.state == 4'd1);
                repeat (3) @(posedge clk);
                abort_sender_and_hold_reset();
            end
        join

        release_reset_and_check();
        complete_run();
        pulse_reset();

        // ------------------------------------------------------------
        // Phase 3: reset while an output is stalled by prob_ready=0.
        // ------------------------------------------------------------
        phase      = 3;
        prob_ready = 1'b0;
        $display("INFO: phase 3 - reset during stalled Softmax output");
        sender_abort = 1'b0;

        fork
            run_sender(TOTAL);
            begin
                wait (prob_valid === 1'b1);
                repeat (3) @(posedge clk);
                abort_sender_and_hold_reset();
            end
        join

        release_reset_and_check();
        prob_ready = 1'b1;
        complete_run();

        $display("PASS: mid-operation reset recovery (fill, compute, output stall)");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "Timeout: reset recovery");
    end
endmodule
