`timescale 1ns / 1ps

module tb_rope_head_engine_pipe;

    localparam POS_W      = 8;
    localparam PAIR_IDX_W = 8;

    reg                  clk;
    reg                  rst_n;

    reg [POS_W-1:0]      i_pos;
    reg [15:0]           i_x_re;
    reg [15:0]           i_x_im;
    reg                  i_valid;

    wire [PAIR_IDX_W-1:0] o_pair_idx;
    wire [15:0]           o_y_re;
    wire [15:0]           o_y_im;
    wire                  o_valid;

    integer error_count;
    integer output_count;
    integer timeout_count;

    // --------------------------------------------------------
    // BF16 constants
    // --------------------------------------------------------
    localparam [15:0] BF16_ZERO   = 16'h0000;

    localparam [15:0] BF16_1      = 16'h3F80;
    localparam [15:0] BF16_2      = 16'h4000;
    localparam [15:0] BF16_3      = 16'h4040;
    localparam [15:0] BF16_4      = 16'h4080;
    localparam [15:0] BF16_5      = 16'h40A0;
    localparam [15:0] BF16_6      = 16'h40C0;
    localparam [15:0] BF16_7      = 16'h40E0;
    localparam [15:0] BF16_8      = 16'h4100;

    localparam [15:0] BF16_NEG_2  = 16'hC000;
    localparam [15:0] BF16_NEG_4  = 16'hC080;
    localparam [15:0] BF16_NEG_6  = 16'hC0C0;
    localparam [15:0] BF16_NEG_8  = 16'hC100;

    // --------------------------------------------------------
    // DUT
    //
    // Port names exactly match rope_head_engine_pipe_default.
    // --------------------------------------------------------
    rope_head_engine_pipe_default #(
        .POS_W      (POS_W),
        .PAIR_IDX_W (PAIR_IDX_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),

        .i_pos      (i_pos),
        .i_x_re     (i_x_re),
        .i_x_im     (i_x_im),
        .i_valid    (i_valid),

        .o_pair_idx (o_pair_idx),
        .o_y_re     (o_y_re),
        .o_y_im     (o_y_im),
        .o_valid    (o_valid)
    );

    // --------------------------------------------------------
    // Clock: 100 MHz
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Send one BF16 complex pair.
    // --------------------------------------------------------
    task send_pair;
        input [POS_W-1:0] pos;
        input [15:0]      x_re;
        input [15:0]      x_im;
        begin
            @(negedge clk);
            i_pos   = pos;
            i_x_re  = x_re;
            i_x_im  = x_im;
            i_valid = 1'b1;
        end
    endtask

    task stop_input;
        begin
            @(negedge clk);
            i_valid = 1'b0;
            i_pos   = {POS_W{1'b0}};
            i_x_re  = 16'h0000;
            i_x_im  = 16'h0000;
        end
    endtask

    // --------------------------------------------------------
    // Output checker.
    //
    // Expected input/output sequence:
    //
    // pair 0, pos=0:
    //   (1, 2) -> (1, 2)
    //
    // pair 1, pos=1:
    //   (3, 4) -> (-4, 3)
    //
    // pair 2, pos=2:
    //   (5, 6) -> (-5, -6)
    //
    // pair 3, pos=3:
    //   (7, 8) -> (8, -7)
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (o_valid) begin
            

            case (output_count)
                0: begin
                    if (o_pair_idx !== 8'd0 ||
                        o_y_re     !== BF16_1 ||
                        o_y_im     !== BF16_2) begin

                        $display("FAIL pair 0");
                        $display("  idx got=%0d expected=0", o_pair_idx);
                        $display("  re  got=%h expected=%h", o_y_re, BF16_1);
                        $display("  im  got=%h expected=%h", o_y_im, BF16_2);
                        error_count = error_count + 1;
                    end else begin
                        $display("PASS pair 0: (1,2) -> (1,2)");
                    end
                end

                1: begin
                    if (o_pair_idx !== 8'd1 ||
                        o_y_re     !== BF16_NEG_4 ||
                        o_y_im     !== BF16_3) begin

                        $display("FAIL pair 1");
                        $display("  idx got=%0d expected=1", o_pair_idx);
                        $display("  re  got=%h expected=%h", o_y_re, BF16_NEG_4);
                        $display("  im  got=%h expected=%h", o_y_im, BF16_3);
                        error_count = error_count + 1;
                    end else begin
                        $display("PASS pair 1: (3,4) -> (-4,3)");
                    end
                end

                2: begin
                    if (o_pair_idx !== 8'd2 ||
                        o_y_re     !== 16'hC0A0 ||
                        o_y_im     !== BF16_NEG_6) begin

                        $display("FAIL pair 2");
                        $display("  idx got=%0d expected=2", o_pair_idx);
                        $display("  re  got=%h expected=%h", o_y_re, 16'hC0A0);
                        $display("  im  got=%h expected=%h", o_y_im, BF16_NEG_6);
                        error_count = error_count + 1;
                    end else begin
                        $display("PASS pair 2: (5,6) -> (-5,-6)");
                    end
                end

                3: begin
                    if (o_pair_idx !== 8'd3 ||
                        o_y_re     !== BF16_8 ||
                        o_y_im     !== 16'hC0E0) begin

                        $display("FAIL pair 3");
                        $display("  idx got=%0d expected=3", o_pair_idx);
                        $display("  re  got=%h expected=%h", o_y_re, BF16_8);
                        $display("  im  got=%h expected=%h", o_y_im, 16'hC0E0);
                        error_count = error_count + 1;
                    end else begin
                        $display("PASS pair 3: (7,8) -> (8,-7)");
                    end
                end

                default: begin
                    $display("FAIL: unexpected extra output");
                    error_count = error_count + 1;
                end
            endcase

            output_count = output_count + 1;
        end
    end

    // --------------------------------------------------------
    // Main test
    // --------------------------------------------------------
    initial begin
        error_count   = 0;
        output_count  = 0;
        timeout_count = 0;

        rst_n   = 1'b0;
        i_pos   = {POS_W{1'b0}};
        i_x_re  = BF16_ZERO;
        i_x_im  = BF16_ZERO;
        i_valid = 1'b0;

        repeat (3) @(posedge clk);

        @(negedge clk);
        rst_n = 1'b1;

        // Input 0: position 0, no rotation.
        send_pair(8'd0, BF16_1, BF16_2);

        // Input 1: position 1, 90 degree rotation.
        send_pair(8'd1, BF16_3, BF16_4);

        // Input 2: position 2, 180 degree rotation.
        send_pair(8'd2, BF16_5, BF16_6);

        // Input 3: position 3, 270 degree rotation.
        send_pair(8'd3, BF16_7, BF16_8);

        stop_input();

        while ((output_count < 4) && (timeout_count < 30)) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
        end

        #10;

        if (output_count != 4) begin
            $display("ROPE_HEAD_TEST: FAIL, timeout.");
            $display("Expected 4 outputs, got %0d outputs.", output_count);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("ROPE_HEAD_TEST: PASS");
        end else begin
            $display("ROPE_HEAD_TEST: FAIL, errors=%0d", error_count);
        end

        $finish;
    end

endmodule
