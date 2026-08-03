`timescale 1ns/1ps

module tb_v34_flash_pv_o_tile_update;
    localparam integer TILE = 4;
    localparam integer V_LANES = 8;
    localparam integer EXP_W = 24;
    localparam integer O_ACC_W = 40;
    localparam integer MAX_CASES = 512;
    localparam integer EXPECTED_LATENCY = 8;

    logic clk;
    logic rst_n;
    logic in_valid;
    logic in_ready;
    logic [TILE-1:0] in_new_state_valid;
    logic [TILE-1:0] in_old_o_valid;
    logic [TILE*EXP_W-1:0] in_alpha_q23;
    logic [TILE*TILE*EXP_W-1:0] in_weights_q23;
    logic [TILE*V_LANES*16-1:0] in_v_tile_bf16;
    logic [TILE*V_LANES*O_ACC_W-1:0] in_old_o_fixed;
    logic out_valid;
    logic out_ready;
    logic [TILE-1:0] out_o_valid;
    logic [TILE*V_LANES*O_ACC_W-1:0] out_o_fixed;
    logic [TILE-1:0] out_numeric_error;
    logic busy;

    integer case_id [0:MAX_CASES-1];
    logic [TILE-1:0] vec_new_valid [0:MAX_CASES-1];
    logic [TILE-1:0] vec_old_valid [0:MAX_CASES-1];
    logic [TILE*EXP_W-1:0] vec_alpha [0:MAX_CASES-1];
    logic [TILE*TILE*EXP_W-1:0] vec_weights [0:MAX_CASES-1];
    logic [TILE*V_LANES*16-1:0] vec_v [0:MAX_CASES-1];
    logic [TILE*V_LANES*O_ACC_W-1:0] vec_old_o [0:MAX_CASES-1];
    logic [TILE-1:0] vec_expected_valid [0:MAX_CASES-1];
    logic [TILE*V_LANES*O_ACC_W-1:0] vec_expected_o [0:MAX_CASES-1];
    logic [TILE-1:0] vec_expected_error [0:MAX_CASES-1];

    integer case_count;
    integer completed_count;
    integer cycle_count;
    integer accepted_cycle;
    integer fd;
    integer scan_result;
    integer driver_index;
    integer gap_cycles;
    integer marker_fd;
    integer stall_left;
    logic inflight;
    logic out_valid_d;
    logic held_valid;
    logic [TILE-1:0] held_o_valid;
    logic [TILE*V_LANES*O_ACC_W-1:0] held_o;
    logic [TILE-1:0] held_error;
    logic [31:0] lfsr;
    reg [1023:0] vectors_name;
    reg [1023:0] marker_name;

    flash_pv_o_tile_update dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_new_state_valid(in_new_state_valid),
        .in_old_o_valid(in_old_o_valid),
        .in_alpha_q23(in_alpha_q23),
        .in_weights_q23(in_weights_q23),
        .in_v_tile_bf16(in_v_tile_bf16),
        .in_old_o_fixed(in_old_o_fixed),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_o_valid(out_o_valid),
        .out_o_fixed(out_o_fixed),
        .out_numeric_error(out_numeric_error),
        .busy(busy)
    );

    initial clk = 1'b0;
    always #3.333 clk = ~clk;

    always @(negedge clk) begin
        if (!rst_n) begin
            lfsr <= 32'h1ace_b00c;
            stall_left <= 0;
            out_ready <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (stall_left > 0) begin
                out_ready <= 1'b0;
                stall_left <= stall_left - 1;
            end else if (lfsr[5:0] == 6'h00) begin
                out_ready <= 1'b0;
                stall_left <= 4 + lfsr[9:6];
            end else begin
                out_ready <= lfsr[0] | lfsr[3];
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            accepted_cycle <= 0;
            completed_count <= 0;
            inflight <= 1'b0;
            out_valid_d <= 1'b0;
            held_valid <= 1'b0;
            held_o_valid <= '0;
            held_o <= '0;
            held_error <= '0;
        end else begin
            cycle_count <= cycle_count + 1;
            out_valid_d <= out_valid;

            if (in_valid && in_ready) begin
                if (inflight)
                    $fatal(1, "Accepted a second request while busy");
                inflight <= 1'b1;
                accepted_cycle <= cycle_count + 1;
            end

            if (out_valid && !out_valid_d) begin
                if (!inflight)
                    $fatal(1, "Output appeared without an input request");
                if ((cycle_count - accepted_cycle) != EXPECTED_LATENCY)
                    $fatal(1,
                        "Case %0d latency mismatch: got %0d expected %0d",
                        case_id[completed_count],
                        cycle_count - accepted_cycle,
                        EXPECTED_LATENCY);
            end

            if (out_valid && !out_ready) begin
                if (held_valid) begin
                    if ((out_o_valid !== held_o_valid) ||
                        (out_o_fixed !== held_o) ||
                        (out_numeric_error !== held_error))
                        $fatal(1, "Output changed while backpressured");
                end else begin
                    held_o_valid <= out_o_valid;
                    held_o <= out_o_fixed;
                    held_error <= out_numeric_error;
                    held_valid <= 1'b1;
                end
            end else begin
                held_valid <= 1'b0;
            end

            if (out_valid && out_ready) begin
                if (completed_count >= case_count)
                    $fatal(1, "DUT produced more outputs than inputs");
                if (out_o_valid !== vec_expected_valid[completed_count])
                    $fatal(1,
                        "Case %0d out_o_valid mismatch: got %h expected %h",
                        case_id[completed_count], out_o_valid,
                        vec_expected_valid[completed_count]);
                if (out_o_fixed !== vec_expected_o[completed_count])
                    $fatal(1, "Case %0d out_o_fixed mismatch",
                           case_id[completed_count]);
                if (out_numeric_error !==
                    vec_expected_error[completed_count])
                    $fatal(1,
                        "Case %0d error mismatch: got %h expected %h",
                        case_id[completed_count], out_numeric_error,
                        vec_expected_error[completed_count]);
                completed_count <= completed_count + 1;
                inflight <= 1'b0;
            end
        end
    end

    initial begin
        if (!$value$plusargs("VECTORS=%s", vectors_name))
            vectors_name = "v34_pv_o_vectors.txt";
        if (!$value$plusargs("MARKER=%s", marker_name))
            marker_name = "v34_pv_o_tile_pass.txt";

        fd = $fopen(vectors_name, "r");
        if (fd == 0)
            $fatal(1, "Could not open vector file %0s", vectors_name);

        case_count = 0;
        while (!$feof(fd) && case_count < MAX_CASES) begin
            scan_result = $fscanf(fd,
                "%d %h %h %h %h %h %h %h %h %h\n",
                case_id[case_count],
                vec_new_valid[case_count],
                vec_old_valid[case_count],
                vec_alpha[case_count],
                vec_weights[case_count],
                vec_v[case_count],
                vec_old_o[case_count],
                vec_expected_valid[case_count],
                vec_expected_o[case_count],
                vec_expected_error[case_count]);
            if (scan_result == 10)
                case_count = case_count + 1;
            else if (!$feof(fd))
                $fatal(1, "Malformed vector line after case %0d", case_count);
        end
        $fclose(fd);
        if (case_count == 0)
            $fatal(1, "No Stage 3A vectors were loaded");

        rst_n = 1'b0;
        in_valid = 1'b0;
        in_new_state_valid = '0;
        in_old_o_valid = '0;
        in_alpha_q23 = '0;
        in_weights_q23 = '0;
        in_v_tile_bf16 = '0;
        in_old_o_fixed = '0;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;

        for (driver_index = 0; driver_index < case_count;
             driver_index = driver_index + 1) begin
            gap_cycles = (driver_index * 5 + (driver_index >> 2)) % 4;
            repeat (gap_cycles) @(negedge clk);
            in_new_state_valid = vec_new_valid[driver_index];
            in_old_o_valid = vec_old_valid[driver_index];
            in_alpha_q23 = vec_alpha[driver_index];
            in_weights_q23 = vec_weights[driver_index];
            in_v_tile_bf16 = vec_v[driver_index];
            in_old_o_fixed = vec_old_o[driver_index];
            in_valid = 1'b1;
            do @(posedge clk); while (!(in_valid && in_ready));
            @(negedge clk);
            in_valid = 1'b0;
            while (completed_count <= driver_index)
                @(negedge clk);
        end

        repeat (4) @(posedge clk);
        if (busy)
            $fatal(1, "DUT remained busy after the final response");
        if (completed_count != case_count)
            $fatal(1, "Completed %0d of %0d cases",
                   completed_count, case_count);

        marker_fd = $fopen(marker_name, "w");
        if (marker_fd == 0)
            $fatal(1, "Could not create marker file %0s", marker_name);
        $fdisplay(marker_fd, "V3.4_STAGE3A_PASS cases=%0d", case_count);
        $fclose(marker_fd);
        $display("V34_FLASH_PV_O_TILE_TEST: PASS (%0d cases)", case_count);
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "Stage 3A simulation timeout");
    end

endmodule
