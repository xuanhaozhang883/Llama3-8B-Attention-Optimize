`timescale 1ns/1ps
`include "tb_file_paths.svh"

module tb_softmax_golden;

    localparam int NUM_HEADS = 4;
    localparam int NUM_ROWS  = 128;
    localparam int MAX_LEN   = 128;
    localparam int TOTAL     = NUM_HEADS * NUM_ROWS * MAX_LEN;
    localparam int TIMEOUT_CYCLES = 1200000;
    localparam real TOL_ABS = `SOFTMAX_TOL_ABS;

    logic        clk;
    logic        rst_n;

    logic        in_valid;
    logic        in_ready;
    logic [15:0] in_data;
    logic        in_last;
    logic        in_mask;

    logic        out_valid;
    logic        out_ready;
    logic [15:0] out_data;
    logic        out_last;

    logic        busy;
    logic        row_error;

    logic [15:0] input_scores_bf16 [0:TOTAL-1];
    logic [0:0]  input_masks       [0:TOTAL-1];
    logic [15:0] expected_bf16     [0:TOTAL-1];
    logic [31:0] expected_fp32     [0:TOTAL-1];

    integer result_fd;
    integer row_fd;
    integer cycle_count;
    integer send_head;
    integer send_row_idx;
    integer send_col;

    integer out_count;
    integer pass_count;
    integer fail_count;
    integer outlast_fail_count;
    integer row_error_count;

    integer curr_head;
    integer curr_row;
    integer curr_col;
    integer curr_index;

    real actual_real;
    real expected_real;
    real abs_err;
    real max_abs_err;
    real mean_abs_err_acc;
    real row_sum_actual;
    real row_sum_expected;
    real row_max_abs_err;
    integer row_fail_count;

    softmax_bf16 #(
        .MAX_LEN(128),
        .SCORE_W(24),
        .SCORE_FRAC(14),
        .EXP_LUT_FILE(`EXP_LUT_FILE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_data),
        .in_last(in_last),
        .in_mask(in_mask),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_data),
        .out_last(out_last),
        .busy(busy),
        .row_error(row_error)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic real pow2_real(input int exponent);
        real value;
        int k;
        begin
            value = 1.0;
            if (exponent >= 0) begin
                for (k = 0; k < exponent; k = k + 1)
                    value = value * 2.0;
            end else begin
                for (k = 0; k < -exponent; k = k + 1)
                    value = value / 2.0;
            end
            pow2_real = value;
        end
    endfunction

    function automatic real bf16_to_real(input logic [15:0] bits);
        int sign_bit;
        int exponent;
        int fraction;
        real mantissa;
        real value;
        begin
            sign_bit = bits[15];
            exponent = bits[14:7];
            fraction = bits[6:0];

            if (exponent == 0 && fraction == 0) begin
                value = 0.0;
            end else if (exponent == 0) begin
                mantissa = fraction / 128.0;
                value = mantissa * pow2_real(-126);
            end else if (exponent == 255) begin
                // This testbench only expects finite probabilities. Use a large marker for unexpected inf/nan.
                value = 1.0e30;
            end else begin
                mantissa = 1.0 + (fraction / 128.0);
                value = mantissa * pow2_real(exponent - 127);
            end

            bf16_to_real = sign_bit ? -value : value;
        end
    endfunction

    function automatic real fp32_bits_to_real(input logic [31:0] bits);
        int sign_bit;
        int exponent;
        int fraction;
        real mantissa;
        real value;
        begin
            sign_bit = bits[31];
            exponent = bits[30:23];
            fraction = bits[22:0];

            if (exponent == 0 && fraction == 0) begin
                value = 0.0;
            end else if (exponent == 0) begin
                mantissa = fraction / 8388608.0;
                value = mantissa * pow2_real(-126);
            end else if (exponent == 255) begin
                value = 1.0e30;
            end else begin
                mantissa = 1.0 + (fraction / 8388608.0);
                value = mantissa * pow2_real(exponent - 127);
            end

            fp32_bits_to_real = sign_bit ? -value : value;
        end
    endfunction

    function automatic real real_abs(input real x);
        begin
            real_abs = (x < 0.0) ? -x : x;
        end
    endfunction

    task automatic send_one(input int index, input bit is_last);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_data  = input_scores_bf16[index];
            in_mask  = input_masks[index][0];
            in_last  = is_last;

            while (in_ready !== 1'b1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data  = input_scores_bf16[index];
                in_mask  = input_masks[index][0];
                in_last  = is_last;
            end
        end
    endtask

    task automatic send_row(input int head_id, input int row_id);
        int col_id;
        int index;
        begin
            for (col_id = 0; col_id < MAX_LEN; col_id = col_id + 1) begin
                index = ((head_id * NUM_ROWS) + row_id) * MAX_LEN + col_id;
                send_one(index, col_id == MAX_LEN - 1);
            end

            @(negedge clk);
            in_valid = 1'b0;
            in_data  = 16'h0000;
            in_mask  = 1'b0;
            in_last  = 1'b0;
        end
    endtask

    initial begin : timeout_watchdog
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $display("============================================================");
        $display("TEST_RESULT: TIMEOUT");
        $display("Simulation reached TIMEOUT_CYCLES=%0d before all outputs were collected.", TIMEOUT_CYCLES);
        $display("Collected outputs=%0d / %0d", out_count, TOTAL);
        $display("============================================================");
        $finish;
    end

    initial begin : main_test
        $display("============================================================");
        $display("Softmax BF16 golden-model simulation started");
        $display("Input score file    : %s", `INPUT_HEX_FILE);
        $display("Input mask file     : %s", `MASK_HEX_FILE);
        $display("Expected BF16 file  : %s", `EXPECTED_BF16_FILE);
        $display("Expected FP32 file  : %s", `EXPECTED_FP32_FILE);
        $display("Result CSV file     : %s", `RESULT_CSV_FILE);
        $display("Row summary CSV     : %s", `ROW_SUMMARY_CSV_FILE);
        $display("EXP LUT file        : %s", `EXP_LUT_FILE);
        $display("Tolerance abs       : %f", TOL_ABS);
        $display("Data shape          : heads=%0d, rows/head=%0d, cols/row=%0d", NUM_HEADS, NUM_ROWS, MAX_LEN);
        $display("============================================================");

        $readmemh(`INPUT_HEX_FILE,     input_scores_bf16);
        $readmemh(`MASK_HEX_FILE,      input_masks);
        $readmemh(`EXPECTED_BF16_FILE, expected_bf16);
        $readmemh(`EXPECTED_FP32_FILE, expected_fp32);

        result_fd = $fopen(`RESULT_CSV_FILE, "w");
        if (result_fd == 0) begin
            $display("ERROR: cannot open result CSV file: %s", `RESULT_CSV_FILE);
            $finish;
        end

        row_fd = $fopen(`ROW_SUMMARY_CSV_FILE, "w");
        if (row_fd == 0) begin
            $display("ERROR: cannot open row summary CSV file: %s", `ROW_SUMMARY_CSV_FILE);
            $finish;
        end

        $fwrite(result_fd, "linear_idx,head,row,col,actual_bf16_hex,expected_bf16_hex,actual_float,expected_float,abs_err,row_error,out_last,pass\n");
        $fwrite(row_fd, "head,row,row_sum_actual,row_sum_expected,row_max_abs_err,row_fail_count,row_pass\n");

        in_valid = 1'b0;
        in_data  = 16'h0000;
        in_last  = 1'b0;
        in_mask  = 1'b0;
        out_ready = 1'b1;

        out_count = 0;
        pass_count = 0;
        fail_count = 0;
        outlast_fail_count = 0;
        row_error_count = 0;
        max_abs_err = 0.0;
        mean_abs_err_acc = 0.0;
        row_sum_actual = 0.0;
        row_sum_expected = 0.0;
        row_max_abs_err = 0.0;
        row_fail_count = 0;

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (send_head = 0; send_head < NUM_HEADS; send_head = send_head + 1) begin
            for (send_row_idx = 0; send_row_idx < NUM_ROWS; send_row_idx = send_row_idx + 1) begin
                send_row(send_head, send_row_idx);
            end
        end

        wait (out_count == TOTAL);
        repeat (10) @(posedge clk);

        $display("============================================================");
        $display("SOFTMAX_GOLDEN_SUMMARY");
        $display("Total outputs       : %0d", TOTAL);
        $display("Pass count          : %0d", pass_count);
        $display("Fail count          : %0d", fail_count);
        $display("out_last failures   : %0d", outlast_fail_count);
        $display("row_error count     : %0d", row_error_count);
        $display("Max abs error       : %.10f", max_abs_err);
        $display("Mean abs error      : %.10f", mean_abs_err_acc / TOTAL);
        if ((fail_count == 0) && (outlast_fail_count == 0) && (row_error_count == 0)) begin
            $display("TEST_RESULT: PASS");
        end else begin
            $display("TEST_RESULT: FAIL");
        end
        $display("CSV result          : %s", `RESULT_CSV_FILE);
        $display("CSV row summary     : %s", `ROW_SUMMARY_CSV_FILE);
        $display("============================================================");

        $fclose(result_fd);
        $fclose(row_fd);
        $finish;
    end

    always @(posedge clk) begin : output_monitor
        if (!rst_n) begin
            // counters are initialized in main_test after reset; keep this block passive during reset.
        end else if (out_valid && out_ready) begin
            curr_index = out_count;
            curr_head = curr_index / (NUM_ROWS * MAX_LEN);
            curr_row  = (curr_index / MAX_LEN) % NUM_ROWS;
            curr_col  = curr_index % MAX_LEN;

            actual_real = bf16_to_real(out_data);
            expected_real = fp32_bits_to_real(expected_fp32[curr_index]);
            abs_err = real_abs(actual_real - expected_real);

            if (abs_err > max_abs_err)
                max_abs_err = abs_err;
            if (abs_err > row_max_abs_err)
                row_max_abs_err = abs_err;
            mean_abs_err_acc = mean_abs_err_acc + abs_err;

            row_sum_actual = row_sum_actual + actual_real;
            row_sum_expected = row_sum_expected + expected_real;

            if (abs_err <= TOL_ABS) begin
                pass_count = pass_count + 1;
                $fwrite(result_fd, "%0d,%0d,%0d,%0d,%04h,%04h,%.10e,%.10e,%.10e,%0d,%0d,1\n",
                        curr_index, curr_head, curr_row, curr_col, out_data, expected_bf16[curr_index],
                        actual_real, expected_real, abs_err, row_error, out_last);
            end else begin
                fail_count = fail_count + 1;
                row_fail_count = row_fail_count + 1;
                $fwrite(result_fd, "%0d,%0d,%0d,%0d,%04h,%04h,%.10e,%.10e,%.10e,%0d,%0d,0\n",
                        curr_index, curr_head, curr_row, curr_col, out_data, expected_bf16[curr_index],
                        actual_real, expected_real, abs_err, row_error, out_last);
                $display("MISMATCH: head=%0d row=%0d col=%0d actual=%04h %.10e expected=%04h %.10e abs_err=%.10e tol=%.10e",
                         curr_head, curr_row, curr_col, out_data, actual_real,
                         expected_bf16[curr_index], expected_real, abs_err, TOL_ABS);
            end

            if (row_error) begin
                row_error_count = row_error_count + 1;
            end

            if (out_last !== (curr_col == MAX_LEN - 1)) begin
                outlast_fail_count = outlast_fail_count + 1;
                $display("OUT_LAST_ERROR: head=%0d row=%0d col=%0d out_last=%0d expected=%0d",
                         curr_head, curr_row, curr_col, out_last, (curr_col == MAX_LEN - 1));
            end

            if (curr_col == MAX_LEN - 1) begin
                $fwrite(row_fd, "%0d,%0d,%.10e,%.10e,%.10e,%0d,%0d\n",
                        curr_head, curr_row, row_sum_actual, row_sum_expected,
                        row_max_abs_err, row_fail_count, (row_fail_count == 0));

                if ((curr_row % 16) == 15) begin
                    $display("Progress: finished head=%0d row=%0d, outputs=%0d/%0d, current max_abs_err=%.10e, fails=%0d",
                             curr_head, curr_row, out_count + 1, TOTAL, max_abs_err, fail_count);
                end

                row_sum_actual = 0.0;
                row_sum_expected = 0.0;
                row_max_abs_err = 0.0;
                row_fail_count = 0;
            end

            out_count = out_count + 1;
        end
    end

endmodule
