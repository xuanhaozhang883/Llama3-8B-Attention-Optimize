`timescale 1ns / 1ps

// File-based RoPE verification for the FPGA validation slice.
// Default paths are repository-relative. They can be overridden without
// editing this file, for example:
//   xsim rope_tb -runall -testplusarg ROPE_Q_INPUT=D:/FPT/.../q_before_rope_bf16.hex
module tb_rope_qk_file;

    parameter integer Q_HEADS = 4;
    parameter integer K_HEADS = 1;
    parameter integer SEQ_LEN = 128;
    parameter integer HEAD_DIM = 128;
    parameter integer HALF_DIM = HEAD_DIM / 2;
    parameter real    TOL_ABS = 0.001;
    parameter integer MAX_REPORT_ERRORS = 16;

    localparam integer Q_TOTAL = Q_HEADS * SEQ_LEN * HEAD_DIM;
    localparam integer K_TOTAL = K_HEADS * SEQ_LEN * HEAD_DIM;
    localparam integer CS_TOTAL = SEQ_LEN * HALF_DIM;

    reg  [15:0] x0;
    reg  [15:0] x1;
    reg  [15:0] cos_in;
    reg  [15:0] sin_in;
    wire [15:0] y0;
    wire [15:0] y1;

    reg [15:0] q_mem [0:Q_TOTAL-1];
    reg [15:0] k_mem [0:K_TOTAL-1];
    reg [15:0] cos_mem [0:CS_TOTAL-1];
    reg [15:0] sin_mem [0:CS_TOTAL-1];
    reg [15:0] q_golden_mem [0:Q_TOTAL-1];
    reg [15:0] k_golden_mem [0:K_TOTAL-1];
    reg [15:0] q_out_mem [0:Q_TOTAL-1];
    reg [15:0] k_out_mem [0:K_TOTAL-1];

    string q_input_file;
    string k_input_file;
    string sin_file;
    string cos_file;
    string q_golden_file;
    string k_golden_file;
    string q_output_file;
    string k_output_file;

    integer h;
    integer t;
    integer d;
    integer idx0;
    integer idx1;
    integer cs_idx;
    integer idx;
    integer q_file;
    integer k_file;
    integer q_errors;
    integer k_errors;
    integer report_errors;
    real q_max_abs_error;
    real k_max_abs_error;

    // The original testbench instantiated rope_pair, which does not exist in
    // this repository. rope_pair_engine is the actual combinational RTL unit.
    rope_pair_engine dut (
        .i_x_re(x0),
        .i_x_im(x1),
        .i_sin(sin_in),
        .i_cos(cos_in),
        .o_y_re(y0),
        .o_y_im(y1)
    );

    function automatic real pow2_real(input integer exponent);
        real value;
        integer i;
        begin
            value = 1.0;
            if (exponent >= 0) begin
                for (i = 0; i < exponent; i = i + 1)
                    value = value * 2.0;
            end else begin
                for (i = 0; i < -exponent; i = i + 1)
                    value = value / 2.0;
            end
            pow2_real = value;
        end
    endfunction

    function automatic real bf16_to_real(input reg [15:0] bits);
        integer exponent;
        integer fraction;
        real value;
        begin
            exponent = bits[14:7];
            fraction = bits[6:0];
            if (exponent == 0 && fraction == 0) begin
                value = 0.0;
            end else if (exponent == 0) begin
                value = (fraction / 128.0) * pow2_real(-126);
            end else if (exponent == 255) begin
                value = 1.0e30;
            end else begin
                value = (1.0 + fraction / 128.0) * pow2_real(exponent - 127);
            end
            bf16_to_real = bits[15] ? -value : value;
        end
    endfunction

    function automatic real real_abs(input real value);
        begin
            real_abs = (value < 0.0) ? -value : value;
        end
    endfunction

    task automatic require_readable(input string name, input string path);
        integer fd;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $fatal(1, "ERROR: cannot open %s: %s", name, path);
            end
            $fclose(fd);
        end
    endtask

    task automatic check_word(
        input string tensor_name,
        input integer linear_idx,
        input reg [15:0] got,
        input reg [15:0] expected,
        inout integer error_count,
        inout integer printed_count,
        inout real max_abs_error
    );
        real abs_error;
        begin
            abs_error = real_abs(bf16_to_real(got) - bf16_to_real(expected));
            if (abs_error > max_abs_error)
                max_abs_error = abs_error;
            if ((^got === 1'bx) || (abs_error > TOL_ABS)) begin
                error_count = error_count + 1;
                if (printed_count < MAX_REPORT_ERRORS) begin
                    $display("MISMATCH %s idx=%0d got=%04h expected=%04h abs_error=%f",
                             tensor_name, linear_idx, got, expected, abs_error);
                    printed_count = printed_count + 1;
                end
            end
        end
    endtask

    task automatic run_q;
        begin
            $display("RoPE: processing Q vectors (%0d BF16 words)", Q_TOTAL);
            for (h = 0; h < Q_HEADS; h = h + 1) begin
                for (t = 0; t < SEQ_LEN; t = t + 1) begin
                    for (d = 0; d < HALF_DIM; d = d + 1) begin
                        idx0 = (h * SEQ_LEN + t) * HEAD_DIM + d;
                        idx1 = idx0 + HALF_DIM;
                        cs_idx = t * HALF_DIM + d;
                        x0 = q_mem[idx0];
                        x1 = q_mem[idx1];
                        cos_in = cos_mem[cs_idx];
                        sin_in = sin_mem[cs_idx];
                        #1;
                        q_out_mem[idx0] = y0;
                        q_out_mem[idx1] = y1;
                    end
                end
            end
        end
    endtask

    task automatic run_k;
        begin
            $display("RoPE: processing K vectors (%0d BF16 words)", K_TOTAL);
            for (h = 0; h < K_HEADS; h = h + 1) begin
                for (t = 0; t < SEQ_LEN; t = t + 1) begin
                    for (d = 0; d < HALF_DIM; d = d + 1) begin
                        idx0 = (h * SEQ_LEN + t) * HEAD_DIM + d;
                        idx1 = idx0 + HALF_DIM;
                        cs_idx = t * HALF_DIM + d;
                        x0 = k_mem[idx0];
                        x1 = k_mem[idx1];
                        cos_in = cos_mem[cs_idx];
                        sin_in = sin_mem[cs_idx];
                        #1;
                        k_out_mem[idx0] = y0;
                        k_out_mem[idx1] = y1;
                    end
                end
            end
        end
    endtask

    task automatic check_q;
        begin
            for (idx = 0; idx < Q_TOTAL; idx = idx + 1)
                check_word("Q", idx, q_out_mem[idx], q_golden_mem[idx], q_errors, report_errors, q_max_abs_error);
        end
    endtask

    task automatic check_k;
        begin
            for (idx = 0; idx < K_TOTAL; idx = idx + 1)
                check_word("K", idx, k_out_mem[idx], k_golden_mem[idx], k_errors, report_errors, k_max_abs_error);
        end
    endtask

    task automatic write_q;
        begin
            q_file = $fopen(q_output_file, "w");
            if (q_file == 0)
                $fatal(1, "ERROR: cannot open Q output: %s", q_output_file);
            for (idx = 0; idx < Q_TOTAL; idx = idx + 1)
                $fwrite(q_file, "%04h\n", q_out_mem[idx]);
            $fclose(q_file);
        end
    endtask

    task automatic write_k;
        begin
            k_file = $fopen(k_output_file, "w");
            if (k_file == 0)
                $fatal(1, "ERROR: cannot open K output: %s", k_output_file);
            for (idx = 0; idx < K_TOTAL; idx = idx + 1)
                $fwrite(k_file, "%04h\n", k_out_mem[idx]);
            $fclose(k_file);
        end
    endtask

    initial begin
        q_input_file  = "RoPE/data/q_before_rope_bf16.hex";
        k_input_file  = "RoPE/data/k_before_rope_bf16.hex";
        sin_file      = "RoPE/data/sin_bf16.hex";
        cos_file      = "RoPE/data/cos_bf16.hex";
        q_golden_file = "RoPE/data/q_after_rope_golden_bf16.hex";
        k_golden_file = "RoPE/data/k_after_rope_golden_bf16.hex";
        q_output_file = "RoPE/results/q_rope_verilog.hex";
        k_output_file = "RoPE/results/k_rope_verilog.hex";

        void'($value$plusargs("ROPE_Q_INPUT=%s", q_input_file));
        void'($value$plusargs("ROPE_K_INPUT=%s", k_input_file));
        void'($value$plusargs("ROPE_SIN=%s", sin_file));
        void'($value$plusargs("ROPE_COS=%s", cos_file));
        void'($value$plusargs("ROPE_Q_GOLDEN=%s", q_golden_file));
        void'($value$plusargs("ROPE_K_GOLDEN=%s", k_golden_file));
        void'($value$plusargs("ROPE_Q_OUTPUT=%s", q_output_file));
        void'($value$plusargs("ROPE_K_OUTPUT=%s", k_output_file));

        require_readable("Q input", q_input_file);
        require_readable("K input", k_input_file);
        require_readable("sin table", sin_file);
        require_readable("cos table", cos_file);
        require_readable("Q golden", q_golden_file);
        require_readable("K golden", k_golden_file);

        $display("============================================================");
        $display("RoPE file testbench: Q=%0d heads, K=%0d heads, seq=%0d, dim=%0d", Q_HEADS, K_HEADS, SEQ_LEN, HEAD_DIM);
        $display("Q input   : %s", q_input_file);
        $display("K input   : %s", k_input_file);
        $display("Q golden  : %s", q_golden_file);
        $display("K golden  : %s", k_golden_file);
        $display("Tolerance : %f", TOL_ABS);
        $display("============================================================");

        $readmemh(q_input_file, q_mem);
        $readmemh(k_input_file, k_mem);
        $readmemh(sin_file, sin_mem);
        $readmemh(cos_file, cos_mem);
        $readmemh(q_golden_file, q_golden_mem);
        $readmemh(k_golden_file, k_golden_mem);

        x0 = 16'h0000;
        x1 = 16'h0000;
        cos_in = 16'h0000;
        sin_in = 16'h0000;
        q_errors = 0;
        k_errors = 0;
        report_errors = 0;
        q_max_abs_error = 0.0;
        k_max_abs_error = 0.0;

        run_q;
        run_k;
        check_q;
        check_k;
        write_q;
        write_k;

        $display("Q mismatch count = %0d / %0d", q_errors, Q_TOTAL);
        $display("Q max abs error  = %f", q_max_abs_error);
        $display("K mismatch count = %0d / %0d", k_errors, K_TOTAL);
        $display("K max abs error  = %f", k_max_abs_error);
        if (q_errors == 0 && k_errors == 0) begin
            $display("TEST_RESULT: PASS");
        end else begin
            $display("TEST_RESULT: FAIL");
        end
        $finish;
    end

endmodule
