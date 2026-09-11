`timescale 1ns/1ps

module tb_cats_r4_fp32_positive_add;
    localparam int META_W = 44;
    localparam int NUM_VECTORS = 8192;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic counter_clear = 1'b0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [31:0] in_a_fp32 = 0;
    logic [31:0] in_b_fp32 = 0;
    logic [META_W-1:0] in_meta = 0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [31:0] out_sum_fp32;
    logic out_numeric_error;
    logic [META_W-1:0] out_meta;
    logic [63:0] add_issue;
    logic [63:0] add_result;
    logic [63:0] add_commit;
    logic [63:0] numeric_error_count;
    logic [63:0] output_stall_cycles;

    logic [96:0] vectors [0:NUM_VECTORS-1];
    integer sent;
    integer received;
    integer cycles;
    integer expected_errors;
    integer index;

    always #5 clk = ~clk;

    cats_r4_fp32_positive_add #(.META_W(META_W)) dut (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .in_valid,
        .in_ready,
        .in_a_fp32,
        .in_b_fp32,
        .in_meta,
        .out_valid,
        .out_ready,
        .out_sum_fp32,
        .out_numeric_error,
        .out_meta,
        .add_issue,
        .add_result,
        .add_commit,
        .numeric_error_count,
        .output_stall_cycles
    );

    task automatic drive_vector(input integer vector_index);
        begin
            in_a_fp32 = vectors[vector_index][95:64];
            in_b_fp32 = vectors[vector_index][63:32];
            in_meta = vector_index;
        end
    endtask

    initial begin
        $readmemh(".Xil/cats_r4_b2/positive_add_vectors.mem", vectors);
        expected_errors = 0;
        for (index = 0; index < NUM_VECTORS; index = index + 1)
            expected_errors = expected_errors + vectors[index][96];

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        drive_vector(0);
        in_valid = 1'b1;
        out_ready = 1'b0;
        @(posedge clk);
        if (!(in_valid && in_ready))
            $fatal(1, "clear pretest input was not accepted");
        @(negedge clk);
        in_valid = 1'b0;
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
            out_ready = (cycles % 11) != 0;
            in_valid = (sent < NUM_VECTORS) && ((cycles % 6) != 0);
            if (sent < NUM_VECTORS)
                drive_vector(sent);

            @(posedge clk);
            if (out_valid && out_ready) begin
                if (out_meta != received[META_W-1:0])
                    $fatal(1, "metadata mismatch at vector %0d", received);
                if (out_numeric_error != vectors[received][96])
                    $fatal(1, "error mismatch at vector %0d", received);
                if (out_sum_fp32 != vectors[received][31:0])
                    $fatal(1,
                        "sum mismatch vector=%0d a=%h b=%h got=%h expected=%h",
                        received,vectors[received][95:64],
                        vectors[received][63:32],out_sum_fp32,
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
        if (add_issue != NUM_VECTORS || add_result != NUM_VECTORS ||
            add_commit != NUM_VECTORS)
            $fatal(1, "counter closure issue=%0d result=%0d commit=%0d",
                add_issue,add_result,add_commit);
        if (numeric_error_count != expected_errors)
            $fatal(1, "numeric error count got=%0d expected=%0d",
                numeric_error_count,expected_errors);
        if (output_stall_cycles == 0)
            $fatal(1, "random backpressure did not exercise an output stall");

        $display(
            "CATS-R4 positive FP32 add PASS vectors=%0d errors=%0d stalls=%0d cycles=%0d",
            NUM_VECTORS,expected_errors,output_stall_cycles,cycles
        );
        $finish;
    end
endmodule
