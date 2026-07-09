`timescale 1ns / 1ps

module tb_rope_pair;

    parameter CLK_PERIOD = 10;

    parameter Q_HEADS = 4;
    parameter K_HEADS = 1;
    parameter SEQ_LEN = 128;
    parameter HEAD_DIM = 128;
    parameter HALF_DIM = 64;

    parameter Q_TOTAL = Q_HEADS * SEQ_LEN * HEAD_DIM;
    parameter K_TOTAL = K_HEADS * SEQ_LEN * HEAD_DIM;
    parameter CS_TOTAL = SEQ_LEN * HALF_DIM;

    reg clk;
    reg rst_n;
    reg valid_in;
    wire valid_out;

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
    reg [15:0] q_out_mem [0:Q_TOTAL-1];
    reg [15:0] k_out_mem [0:K_TOTAL-1];

    integer h;
    integer t;
    integer d;
    integer idx0;
    integer idx1;
    integer cs_idx;
    integer idx;
    integer q_file;
    integer k_file;

    rope_pair dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .x0(x0),
        .x1(x1),
        .cos_in(cos_in),
        .sin_in(sin_in),
        .y0(y0),
        .y1(y1),
        .valid_out(valid_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        x0 = 16'h0000;
        x1 = 16'h0000;
        cos_in = 16'h0000;
        sin_in = 16'h0000;

        $readmemh("C:/Users/23858/Downloads/q_input_for_verilog.hex", q_mem);
        $readmemh("C:/Users/23858/Downloads/k_input_for_verilog.hex", k_mem);
        $readmemh("C:/Users/23858/Downloads/cos_bf16.hex", cos_mem);
        $readmemh("C:/Users/23858/Downloads/sin_bf16.hex", sin_mem);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        run_q;
        run_k;

        write_q;
        write_k;

        $display("RoPE pair TB finished.");
        $finish;
    end

    task run_q;
        begin
            $display("Start Q...");
            for (h = 0; h < Q_HEADS; h = h + 1) begin
                for (t = 0; t < SEQ_LEN; t = t + 1) begin
                    for (d = 0; d < HALF_DIM; d = d + 1) begin
                        idx0 = h * SEQ_LEN * HEAD_DIM + t * HEAD_DIM + d;
                        idx1 = h * SEQ_LEN * HEAD_DIM + t * HEAD_DIM + d + HALF_DIM;
                        cs_idx = t * HALF_DIM + d;

                        @(posedge clk);
                        x0 <= q_mem[idx0];
                        x1 <= q_mem[idx1];
                        cos_in <= cos_mem[cs_idx];
                        sin_in <= sin_mem[cs_idx];
                        valid_in <= 1'b1;

                        @(posedge clk);
                        valid_in <= 1'b0;

                        wait_valid;
                        q_out_mem[idx0] = y0;
                        q_out_mem[idx1] = y1;
                    end
                end
            end
            $display("Q done.");
        end
    endtask

    task run_k;
        begin
            $display("Start K...");
            for (h = 0; h < K_HEADS; h = h + 1) begin
                for (t = 0; t < SEQ_LEN; t = t + 1) begin
                    for (d = 0; d < HALF_DIM; d = d + 1) begin
                        idx0 = h * SEQ_LEN * HEAD_DIM + t * HEAD_DIM + d;
                        idx1 = h * SEQ_LEN * HEAD_DIM + t * HEAD_DIM + d + HALF_DIM;
                        cs_idx = t * HALF_DIM + d;

                        @(posedge clk);
                        x0 <= k_mem[idx0];
                        x1 <= k_mem[idx1];
                        cos_in <= cos_mem[cs_idx];
                        sin_in <= sin_mem[cs_idx];
                        valid_in <= 1'b1;

                        @(posedge clk);
                        valid_in <= 1'b0;

                        wait_valid;
                        k_out_mem[idx0] = y0;
                        k_out_mem[idx1] = y1;
                    end
                end
            end
            $display("K done.");
        end
    endtask

    task wait_valid;
        begin
            @(posedge clk);
            while (valid_out !== 1'b1) begin
                @(posedge clk);
            end
        end
    endtask

    task write_q;
        begin
            q_file = $fopen("C:/Users/23858/Downloads/q_rope_verilog.hex", "w");
            for (idx = 0; idx < Q_TOTAL; idx = idx + 1) begin
                $fwrite(q_file, "%04h\n", q_out_mem[idx]);
            end
            $fclose(q_file);
            $display("Write Q hex done.");
        end
    endtask

    task write_k;
        begin
            k_file = $fopen("C:/Users/23858/Downloads/k_rope_verilog.hex", "w");
            for (idx = 0; idx < K_TOTAL; idx = idx + 1) begin
                $fwrite(k_file, "%04h\n", k_out_mem[idx]);
            end
            $fclose(k_file);
            $display("Write K hex done.");
        end
    endtask

endmodule
