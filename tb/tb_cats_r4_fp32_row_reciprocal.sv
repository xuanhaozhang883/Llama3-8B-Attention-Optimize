`timescale 1ns/1ps

module tb_cats_r4_fp32_row_reciprocal;
    localparam int META_W = 44;
    localparam int NUM_VECTORS = 8192;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic counter_clear = 1'b0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [31:0] in_sum_fp32 = 0;
    logic [META_W-1:0] in_meta = 0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [31:0] out_inv_sum_fp32;
    logic out_numeric_error;
    logic [META_W-1:0] out_meta;
    logic [63:0] reciprocal_issue;
    logic [63:0] reciprocal_result;
    logic [63:0] reciprocal_commit;
    logic [63:0] numeric_error_count;
    logic [63:0] busy_stall_cycles;
    logic [63:0] output_stall_cycles;

    logic [64:0] vectors [0:NUM_VECTORS-1];
    integer sent;
    integer received;
    integer cycles;
    integer expected_errors;
    integer index;

    always #5 clk = ~clk;

    cats_r4_fp32_row_reciprocal #(.META_W(META_W)) dut (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .in_valid,
        .in_ready,
        .in_sum_fp32,
        .in_meta,
        .out_valid,
        .out_ready,
        .out_inv_sum_fp32,
        .out_numeric_error,
        .out_meta,
        .reciprocal_issue,
        .reciprocal_result,
        .reciprocal_commit,
        .numeric_error_count,
        .busy_stall_cycles,
        .output_stall_cycles
    );

    initial begin
        $readmemh(".Xil/cats_r4_b2/reciprocal_vectors.mem", vectors);
        expected_errors = 0;
        for (index = 0; index < NUM_VECTORS; index = index + 1)
            expected_errors = expected_errors + vectors[index][64];

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Clear an in-flight iterative divide before beginning counted work.
        in_sum_fp32 = 32'h3F800000;
        in_meta = 44'h123;
        in_valid = 1'b1;
        out_ready = 1'b0;
        @(posedge clk);
        if (!(in_valid && in_ready))
            $fatal(1, "clear pretest reciprocal was not accepted");
        @(negedge clk);
        in_valid = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        clear = 1'b1;
        counter_clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        counter_clear = 1'b0;
        if (out_valid)
            $fatal(1, "clear failed to discard reciprocal state");

        sent = 0;
        received = 0;
        cycles = 0;
        while (received < NUM_VECTORS) begin
            @(negedge clk);
            cycles = cycles + 1;
            out_ready = (cycles % 13) != 0;
            in_valid = sent < NUM_VECTORS;
            if (sent < NUM_VECTORS) begin
                in_sum_fp32 = vectors[sent][63:32];
                in_meta = sent;
            end

            @(posedge clk);
            if (out_valid && out_ready) begin
                if (out_meta != received[META_W-1:0])
                    $fatal(1, "metadata mismatch at vector %0d", received);
                if (out_numeric_error != vectors[received][64])
                    $fatal(1, "error mismatch at vector %0d", received);
                if (out_inv_sum_fp32 != vectors[received][31:0])
                    $fatal(1,
                        "reciprocal mismatch vector=%0d sum=%h got=%h expected=%h",
                        received,vectors[received][63:32],out_inv_sum_fp32,
                        vectors[received][31:0]);
                received = received + 1;
            end
            if (in_valid && in_ready)
                sent = sent + 1;
            if (cycles > 600000)
                $fatal(1, "timeout sent=%0d received=%0d", sent, received);
        end

        @(negedge clk);
        in_valid = 1'b0;
        out_ready = 1'b1;
        if (sent != NUM_VECTORS)
            $fatal(1, "not all reciprocal vectors were accepted");
        if (reciprocal_issue != NUM_VECTORS ||
            reciprocal_result != NUM_VECTORS ||
            reciprocal_commit != NUM_VECTORS)
            $fatal(1, "counter closure issue=%0d result=%0d commit=%0d",
                reciprocal_issue,reciprocal_result,reciprocal_commit);
        if (numeric_error_count != expected_errors)
            $fatal(1, "numeric error count got=%0d expected=%0d",
                numeric_error_count,expected_errors);
        if (busy_stall_cycles == 0 || output_stall_cycles == 0)
            $fatal(1, "backpressure coverage busy=%0d output=%0d",
                busy_stall_cycles,output_stall_cycles);

        $display(
            "CATS-R4 row reciprocal PASS vectors=%0d errors=%0d busy_stalls=%0d output_stalls=%0d cycles=%0d",
            NUM_VECTORS,expected_errors,busy_stall_cycles,
            output_stall_cycles,cycles
        );
        $finish;
    end
endmodule
