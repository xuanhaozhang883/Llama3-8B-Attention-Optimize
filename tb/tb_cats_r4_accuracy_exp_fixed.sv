`timescale 1ns/1ps

module tb_cats_r4_accuracy_exp_fixed;
    localparam int META_W = 44;
    localparam int NUM_VECTORS = 8192;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic counter_clear = 1'b0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [15:0] in_row_max_bf16 = 0;
    logic [15:0] in_score_bf16 = 0;
    logic [META_W-1:0] in_meta = 0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [31:0] out_weight_fp32;
    logic out_numeric_error;
    logic [META_W-1:0] out_meta;
    logic [63:0] exp_issue;
    logic [63:0] exp_result;
    logic [63:0] exp_commit;
    logic [63:0] numeric_error_count;
    logic [63:0] output_stall_cycles;

    logic [64:0] vectors [0:NUM_VECTORS-1];
    integer sent;
    integer received;
    integer cycles;
    integer expected_errors;
    integer index;

    always #5 clk = ~clk;

    cats_r4_accuracy_exp_fixed #(.META_W(META_W)) dut (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .in_valid,
        .in_ready,
        .in_row_max_bf16,
        .in_score_bf16,
        .in_meta,
        .out_valid,
        .out_ready,
        .out_weight_fp32,
        .out_numeric_error,
        .out_meta,
        .exp_issue,
        .exp_result,
        .exp_commit,
        .numeric_error_count,
        .output_stall_cycles
    );

    task automatic drive_vector(input integer vector_index);
        begin
            in_row_max_bf16 = vectors[vector_index][63:48];
            in_score_bf16 = vectors[vector_index][47:32];
            in_meta = vector_index;
        end
    endtask

    initial begin
        $readmemh(".Xil/cats_r4_b2/accuracy_exp_vectors.mem", vectors);
        expected_errors = 0;
        for (index = 0; index < NUM_VECTORS; index = index + 1)
            expected_errors = expected_errors + vectors[index][64];

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Accept an item, stall it, then prove clear discards the old output.
        drive_vector(0);
        in_valid = 1'b1;
        out_ready = 1'b0;
        @(posedge clk);
        if (!(in_valid && in_ready))
            $fatal(1, "clear pretest input was not accepted");
        @(negedge clk);
        in_valid = 1'b0;
        // The 150 MHz exp implementation has three internal elastic stages
        // before its output register; retain the directed clear test across
        // the full pipeline rather than assuming one-cycle latency.
        repeat (4) @(posedge clk);
        @(negedge clk);
        if (!out_valid)
            $fatal(1, "clear pretest did not create pending output");
        clear = 1'b1;
        counter_clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        counter_clear = 1'b0;
        if (out_valid)
            $fatal(1, "clear failed to discard pending output");

        sent = 0;
        received = 0;
        cycles = 0;
        while (received < NUM_VECTORS) begin
            @(negedge clk);
            cycles = cycles + 1;
            out_ready = (cycles % 7) != 0;
            in_valid = (sent < NUM_VECTORS) && ((cycles % 5) != 0);
            if (sent < NUM_VECTORS)
                drive_vector(sent);

            @(posedge clk);
            if (out_valid && out_ready) begin
                if (out_meta != received[META_W-1:0])
                    $fatal(1, "metadata mismatch at vector %0d", received);
                if (out_numeric_error != vectors[received][64])
                    $fatal(1, "error mismatch at vector %0d", received);
                if (out_weight_fp32 != vectors[received][31:0])
                    $fatal(1,
                        "weight mismatch vector=%0d max=%h score=%h got=%h expected=%h",
                        received,vectors[received][63:48],
                        vectors[received][47:32],out_weight_fp32,
                        vectors[received][31:0]);
                received = received + 1;
            end
            if (in_valid && in_ready)
                sent = sent + 1;
            if (cycles > 100000)
                $fatal(1, "timeout sent=%0d received=%0d", sent, received);
        end

        @(negedge clk);
        in_valid = 1'b0;
        out_ready = 1'b1;
        if (sent != NUM_VECTORS)
            $fatal(1, "not all vectors were accepted");
        if (exp_issue != NUM_VECTORS || exp_result != NUM_VECTORS ||
            exp_commit != NUM_VECTORS)
            $fatal(1, "counter closure issue=%0d result=%0d commit=%0d",
                exp_issue,exp_result,exp_commit);
        if (numeric_error_count != expected_errors)
            $fatal(1, "numeric error count got=%0d expected=%0d",
                numeric_error_count,expected_errors);
        if (output_stall_cycles == 0)
            $fatal(1, "random backpressure did not exercise an output stall");

        $display(
            "CATS-R4 Accuracy exp fixed PASS vectors=%0d errors=%0d stalls=%0d cycles=%0d",
            NUM_VECTORS,expected_errors,output_stall_cycles,cycles
        );
        $finish;
    end
endmodule
