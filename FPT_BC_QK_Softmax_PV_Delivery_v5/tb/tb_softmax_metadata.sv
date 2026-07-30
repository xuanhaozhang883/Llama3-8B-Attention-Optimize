`timescale 1ns/1ps

module tb_softmax_metadata;
    localparam int LEN    = 4;
    localparam int HEAD_W = 2;
    localparam int POS_W  = 3;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic in_valid, in_ready;
    logic [15:0] in_data;
    logic in_last, in_mask;
    logic [HEAD_W-1:0] in_head;
    logic [POS_W-1:0] in_row, in_col;

    logic out_valid, out_ready;
    logic [15:0] out_data;
    logic out_first, out_last;
    logic [HEAD_W-1:0] out_head;
    logic [POS_W-1:0] out_row, out_col;
    logic busy, row_error, metadata_error;

    int recv_count;
    int ready_cycle;
    logic stalled_prev;
    localparam int HOLD_W = 16+2+HEAD_W+2*POS_W;
    logic [HOLD_W-1:0] held_bundle;

    softmax_bf16 #(
        .MAX_LEN(LEN), .HEAD_W(HEAD_W), .POS_W(POS_W),
        .EXP_LUT_FILE("exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .in_data, .in_last, .in_mask,
        .in_head, .in_row, .in_col,
        .out_valid, .out_ready, .out_data, .out_first, .out_last,
        .out_head, .out_row, .out_col,
        .busy, .row_error, .metadata_error
    );

    task automatic send_row(input int head, input int row);
        begin
            for (int col = 0; col < LEN; col++) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data  = 16'h0000; // all equal -> each probability should be 1/LEN
                in_mask  = 1'b0;
                in_last  = (col == LEN-1);
                in_head  = head[HEAD_W-1:0];
                in_row   = row[POS_W-1:0];
                in_col   = col[POS_W-1:0];
                do @(posedge clk); while (!in_ready);
                @(negedge clk);
                in_valid = 1'b0;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            out_ready <= 1'b0;
        end else begin
            ready_cycle <= ready_cycle + 1;
            out_ready <= ((ready_cycle % 5) != 1);
        end
    end

    always_ff @(posedge clk) begin
        int exp_head;
        int exp_row;
        int exp_col;
        logic [HOLD_W-1:0] now_bundle;
        if (!rst_n) begin
            recv_count <= 0;
            stalled_prev <= 1'b0;
        end else begin
            now_bundle = {out_data,out_first,out_last,out_head,out_row,out_col};
            if (stalled_prev && (!out_valid || now_bundle !== held_bundle))
                $fatal(1, "Softmax metadata/data changed while stalled");
            stalled_prev <= out_valid && !out_ready;
            if (out_valid && !out_ready)
                held_bundle <= now_bundle;

            if (out_valid && out_ready) begin
                exp_head = (recv_count < LEN) ? 2 : 1;
                exp_row  = (recv_count < LEN) ? 3 : 5;
                exp_col  = recv_count % LEN;

                if (out_head !== exp_head[HEAD_W-1:0] ||
                    out_row !== exp_row[POS_W-1:0] ||
                    out_col !== exp_col[POS_W-1:0])
                    $fatal(1, "Softmax metadata mismatch at %0d", recv_count);
                if (out_first !== (exp_col == 0) || out_last !== (exp_col == LEN-1))
                    $fatal(1, "Softmax boundary mismatch at %0d", recv_count);
                if (out_data !== 16'h3E80)
                    $fatal(1, "Expected BF16 0.25, got %h", out_data);
                if (row_error || metadata_error)
                    $fatal(1, "Unexpected softmax error flag");
                recv_count <= recv_count + 1;
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        in_valid = 1'b0;
        in_data = '0;
        in_last = 1'b0;
        in_mask = 1'b0;
        in_head = '0;
        in_row = '0;
        in_col = '0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        send_row(2,3);
        send_row(1,5);

        wait (recv_count == 2*LEN);
        repeat (5) @(posedge clk);
        $display("PASS: tb_softmax_metadata");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "Timeout");
    end
endmodule
