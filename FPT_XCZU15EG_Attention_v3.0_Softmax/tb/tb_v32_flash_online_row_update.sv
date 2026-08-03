`timescale 1ns/1ps

module tb_v32_flash_online_row_update;

    localparam integer TILE_COLS = 4;
    localparam integer SCORE_W = 24;
    localparam integer L_SUM_W = 32;

    logic clk;
    logic rst_n;

    logic                    in_valid;
    logic                    in_ready;
    logic [63:0]             in_scores_bf16;
    logic [3:0]              in_mask;
    logic                    in_state_valid;
    logic signed [23:0]      in_m_fixed;
    logic [31:0]             in_l_q23;

    logic                    out_valid;
    logic                    out_ready;
    logic                    out_state_valid;
    logic signed [23:0]      out_m_fixed;
    logic [31:0]             out_l_q23;
    logic [23:0]             out_alpha_q23;
    logic [15:0]             out_alpha_q15;
    logic [15:0]             out_alpha_bf16;
    logic [95:0]             out_weights_q23;
    logic [63:0]             out_weights_q15;
    logic [63:0]             out_weights_bf16;
    logic [31:0]             out_row_sum_q23;
    logic                    out_all_masked_tile;
    logic                    out_numeric_error;
    logic                    busy;

    integer vector_file;
    integer marker_file;
    integer scan_count;
    integer case_id;
    integer completed_cases;
    integer cycle_count;
    integer accept_cycle;
    integer max_latency;
    integer timeout_cycles;

    logic [31:0] ready_lfsr;

    logic [63:0] vector_scores;
    logic [3:0]  vector_mask;
    logic        vector_in_state;
    logic [23:0] vector_in_m;
    logic [31:0] vector_in_l;
    logic        expected_state;
    logic [23:0] expected_m;
    logic [31:0] expected_l;
    logic [23:0] expected_alpha_q23;
    logic [15:0] expected_alpha_q15;
    logic [15:0] expected_alpha_bf16;
    logic [95:0] expected_weights_q23;
    logic [63:0] expected_weights;
    logic [63:0] expected_weights_bf16;
    logic [31:0] expected_row_sum;
    logic        expected_all_masked;
    logic        expected_error;

    logic                    held_state;
    logic [23:0]             held_m;
    logic [31:0]             held_l;
    logic [23:0]             held_alpha_q23;
    logic [15:0]             held_alpha_q15;
    logic [15:0]             held_alpha_bf16;
    logic [95:0]             held_weights_q23;
    logic [63:0]             held_weights;
    logic [63:0]             held_weights_bf16;
    logic [31:0]             held_row_sum;
    logic                    held_all_masked;
    logic                    held_error;

    flash_online_row_update #(
        .TILE_COLS(TILE_COLS),
        .MAX_LEN(128),
        .SCORE_W(SCORE_W),
        .SCORE_FRAC(14),
        .EXP_W(24),
        .EXP_FRAC(23),
        .L_SUM_W(L_SUM_W),
        .EXP_LUT_FILE("exp_lut_q23.mem")
    ) dut (
        .clk,
        .rst_n,
        .in_valid,
        .in_ready,
        .in_scores_bf16,
        .in_mask,
        .in_state_valid,
        .in_m_fixed,
        .in_l_q23,
        .out_valid,
        .out_ready,
        .out_state_valid,
        .out_m_fixed,
        .out_l_q23,
        .out_alpha_q23,
        .out_alpha_q15,
        .out_alpha_bf16,
        .out_weights_q23,
        .out_weights_q15,
        .out_weights_bf16,
        .out_row_sum_q23,
        .out_all_masked_tile,
        .out_numeric_error,
        .busy
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    task automatic check_expected_output;
        begin
            if (out_state_valid !== expected_state)
                $fatal(1, "case %0d: state_valid got=%b expected=%b",
                       case_id, out_state_valid, expected_state);
            if (out_m_fixed !== expected_m)
                $fatal(1, "case %0d: m got=%h expected=%h",
                       case_id, out_m_fixed, expected_m);
            if (out_l_q23 !== expected_l)
                $fatal(1, "case %0d: l got=%h expected=%h",
                       case_id, out_l_q23, expected_l);
            if (out_alpha_q23 !== expected_alpha_q23)
                $fatal(1, "case %0d: alpha Q23 got=%h expected=%h",
                       case_id, out_alpha_q23, expected_alpha_q23);
            if (out_alpha_q15 !== expected_alpha_q15)
                $fatal(1, "case %0d: alpha Q15 got=%h expected=%h",
                       case_id, out_alpha_q15, expected_alpha_q15);
            if (out_alpha_bf16 !== expected_alpha_bf16)
                $fatal(1, "case %0d: BF16 alpha got=%h expected=%h",
                       case_id, out_alpha_bf16, expected_alpha_bf16);
            if (out_weights_q23 !== expected_weights_q23)
                $fatal(1, "case %0d: Q23 weights got=%h expected=%h",
                       case_id, out_weights_q23, expected_weights_q23);
            if (out_weights_q15 !== expected_weights)
                $fatal(1, "case %0d: weights got=%h expected=%h",
                       case_id, out_weights_q15, expected_weights);
            if (out_weights_bf16 !== expected_weights_bf16)
                $fatal(1, "case %0d: BF16 weights got=%h expected=%h",
                       case_id, out_weights_bf16, expected_weights_bf16);
            if (out_row_sum_q23 !== expected_row_sum)
                $fatal(1, "case %0d: row_sum got=%h expected=%h",
                       case_id, out_row_sum_q23, expected_row_sum);
            if (out_all_masked_tile !== expected_all_masked)
                $fatal(1, "case %0d: all_masked got=%b expected=%b",
                       case_id, out_all_masked_tile, expected_all_masked);
            if (out_numeric_error !== expected_error)
                $fatal(1, "case %0d: error got=%b expected=%b",
                       case_id, out_numeric_error, expected_error);
        end
    endtask

    task automatic capture_held_output;
        begin
            held_state = out_state_valid;
            held_m = out_m_fixed;
            held_l = out_l_q23;
            held_alpha_q23 = out_alpha_q23;
            held_alpha_q15 = out_alpha_q15;
            held_alpha_bf16 = out_alpha_bf16;
            held_weights_q23 = out_weights_q23;
            held_weights = out_weights_q15;
            held_weights_bf16 = out_weights_bf16;
            held_row_sum = out_row_sum_q23;
            held_all_masked = out_all_masked_tile;
            held_error = out_numeric_error;
        end
    endtask

    task automatic check_held_output;
        begin
            if (!out_valid)
                $fatal(1, "case %0d: out_valid dropped during backpressure", case_id);
            if ((out_state_valid !== held_state) ||
                (out_m_fixed !== held_m) ||
                (out_l_q23 !== held_l) ||
                (out_alpha_q23 !== held_alpha_q23) ||
                (out_alpha_q15 !== held_alpha_q15) ||
                (out_alpha_bf16 !== held_alpha_bf16) ||
                (out_weights_q23 !== held_weights_q23) ||
                (out_weights_q15 !== held_weights) ||
                (out_weights_bf16 !== held_weights_bf16) ||
                (out_row_sum_q23 !== held_row_sum) ||
                (out_all_masked_tile !== held_all_masked) ||
                (out_numeric_error !== held_error))
                $fatal(1, "case %0d: output payload changed during backpressure", case_id);
        end
    endtask

    task automatic run_vector;
        integer stall_cycle;
        integer latency;
        begin
            while (!in_ready)
                @(negedge clk);

            in_scores_bf16 = vector_scores;
            in_mask = vector_mask;
            in_state_valid = vector_in_state;
            in_m_fixed = vector_in_m;
            in_l_q23 = vector_in_l;
            in_valid = 1'b1;

            @(posedge clk);
            accept_cycle = cycle_count;
            @(negedge clk);
            in_valid = 1'b0;

            timeout_cycles = 0;
            while (!out_valid) begin
                ready_lfsr = {ready_lfsr[30:0],
                              ready_lfsr[31] ^ ready_lfsr[21] ^
                              ready_lfsr[1] ^ ready_lfsr[0]};
                out_ready = ready_lfsr[0];
                @(negedge clk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 32)
                    $fatal(1, "case %0d: timed out waiting for output", case_id);
            end

            check_expected_output();
            latency = cycle_count - accept_cycle;
            if (latency > max_latency)
                max_latency = latency;

            // Every seventh result is held for three clocks to verify that the
            // complete payload remains stable while the consumer is stalled.
            if ((case_id % 7) == 0) begin
                out_ready = 1'b0;
                capture_held_output();
                for (stall_cycle = 0; stall_cycle < 3; stall_cycle = stall_cycle + 1) begin
                    @(posedge clk);
                    #1;
                    check_held_output();
                end
                @(negedge clk);
            end

            out_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            out_ready = 1'b0;
            completed_cases = completed_cases + 1;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        in_valid = 1'b0;
        in_scores_bf16 = '0;
        in_mask = '0;
        in_state_valid = 1'b0;
        in_m_fixed = '0;
        in_l_q23 = '0;
        out_ready = 1'b0;
        completed_cases = 0;
        cycle_count = 0;
        max_latency = 0;
        ready_lfsr = 32'h1ace_b00c;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        if (out_valid || busy)
            $fatal(1, "DUT not idle after reset");

        vector_file = $fopen("v32_online_row_vectors.txt", "r");
        if (vector_file == 0)
            $fatal(1, "cannot open v32_online_row_vectors.txt");

        scan_count = $fscanf(
            vector_file,
            "%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
            case_id,
            vector_scores,
            vector_mask,
            vector_in_state,
            vector_in_m,
            vector_in_l,
            expected_state,
            expected_m,
            expected_l,
            expected_alpha_q23,
            expected_alpha_q15,
            expected_alpha_bf16,
            expected_weights_q23,
            expected_weights,
            expected_weights_bf16,
            expected_row_sum,
            expected_all_masked,
            expected_error
        );

        while (scan_count == 18) begin
            run_vector();
            scan_count = $fscanf(
                vector_file,
                "%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                case_id,
                vector_scores,
                vector_mask,
                vector_in_state,
                vector_in_m,
                vector_in_l,
                expected_state,
                expected_m,
                expected_l,
                expected_alpha_q23,
                expected_alpha_q15,
                expected_alpha_bf16,
                expected_weights_q23,
                expected_weights,
                expected_weights_bf16,
                expected_row_sum,
                expected_all_masked,
                expected_error
            );
        end
        $fclose(vector_file);

        if (completed_cases != 512)
            $fatal(1, "expected 512 vectors, completed %0d", completed_cases);
        if (scan_count != -1)
            $fatal(1, "malformed vector file, final fscanf count=%0d", scan_count);

        marker_file = $fopen("v32_online_row_update_pass.txt", "w");
        if (marker_file == 0)
            $fatal(1, "cannot create PASS marker");
        $fdisplay(marker_file, "V3.2 Stage 2A online row update: PASS");
        $fdisplay(marker_file, "vectors=%0d", completed_cases);
        $fdisplay(marker_file, "max_latency=%0d", max_latency);
        $fclose(marker_file);

        $display("============================================================");
        $display("V32_FLASH_ONLINE_ROW_UPDATE_TEST: PASS");
        $display("vectors=%0d max_latency=%0d", completed_cases, max_latency);
        $display("============================================================");
        $finish;
    end

endmodule
