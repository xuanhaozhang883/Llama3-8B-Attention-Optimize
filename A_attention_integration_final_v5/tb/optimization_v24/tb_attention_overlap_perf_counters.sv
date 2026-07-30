`timescale 1ns/1ps

module tb_attention_overlap_perf_counters;

    localparam int NUM_GROUPS = 2;
    localparam int Q_HEADS    = 2;
    localparam int SEQ_LEN    = 2;
    localparam int HEAD_DIM   = 2;
    localparam int TOTAL      =
        NUM_GROUPS*Q_HEADS*SEQ_LEN*HEAD_DIM;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic command_start;
    logic command_busy;
    logic command_done;
    logic bc_busy;
    logic pv_busy;
    logic bc_wait_for_empty_bank;
    logic pv_wait_for_ready_bank;
    logic context_valid;
    logic context_ready;
    logic [0:0] context_group_id;
    logic [0:0] context_head;
    logic [0:0] context_row;
    logic [0:0] context_col;
    logic child_protocol_error;

    logic [63:0] total_cycles;
    logic [63:0] bc_cycles;
    logic [63:0] pv_cycles;
    logic [63:0] overlap_cycles;
    logic [63:0] bank_full_wait_cycles;
    logic [63:0] bank_empty_wait_cycles;
    logic [31:0] context_count;
    logic [31:0] duplicate_count;
    logic [31:0] missing_count;
    logic [31:0] error_bitmap;

    attention_overlap_perf_counters #(
        .NUM_GROUPS(NUM_GROUPS),
        .Q_HEADS(Q_HEADS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .GROUP_W(1),
        .HEAD_W(1),
        .POS_W(1),
        .DIM_W(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .command_start(command_start),
        .command_busy(command_busy),
        .command_done(command_done),
        .bc_busy(bc_busy),
        .pv_busy(pv_busy),
        .bc_wait_for_empty_bank(bc_wait_for_empty_bank),
        .pv_wait_for_ready_bank(pv_wait_for_ready_bank),
        .context_valid(context_valid),
        .context_ready(context_ready),
        .context_group_id(context_group_id),
        .context_head(context_head),
        .context_row(context_row),
        .context_col(context_col),
        .child_protocol_error(child_protocol_error),
        .total_cycles(total_cycles),
        .bc_cycles(bc_cycles),
        .pv_cycles(pv_cycles),
        .overlap_cycles(overlap_cycles),
        .bank_full_wait_cycles(bank_full_wait_cycles),
        .bank_empty_wait_cycles(bank_empty_wait_cycles),
        .context_count(context_count),
        .duplicate_count(duplicate_count),
        .missing_count(missing_count),
        .error_bitmap(error_bitmap)
    );

    task automatic set_context(input int linear_index);
        int value;
        begin
            value = linear_index;
            context_col      = value % HEAD_DIM;
            value            = value / HEAD_DIM;
            context_row      = value % SEQ_LEN;
            value            = value / SEQ_LEN;
            context_head     = value % Q_HEADS;
            value            = value / Q_HEADS;
            context_group_id = value;
        end
    endtask

    task automatic begin_command;
        begin
            @(negedge clk);
            command_start = 1'b1;
            command_busy  = 1'b1;
            @(negedge clk);
            command_start = 1'b0;
        end
    endtask

    integer index;

    initial begin
        command_start           = 1'b0;
        command_busy            = 1'b0;
        command_done            = 1'b0;
        bc_busy                 = 1'b0;
        pv_busy                 = 1'b0;
        bc_wait_for_empty_bank  = 1'b0;
        pv_wait_for_ready_bank  = 1'b0;
        context_valid           = 1'b0;
        context_ready           = 1'b1;
        context_group_id        = '0;
        context_head            = '0;
        context_row             = '0;
        context_col             = '0;
        child_protocol_error    = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Normal ordered command.
        begin_command();

        for (index = 0; index < TOTAL; index = index + 1) begin
            @(negedge clk);
            set_context(index);
            context_valid = 1'b1;
            bc_busy       = (index < 12);
            pv_busy       = (index >= 3);
            bc_wait_for_empty_bank =
                (index == 1 || index == 2);
            pv_wait_for_ready_bank =
                (index == 0 || index == 1 || index == 2);
            command_done  = (index == TOTAL-1);
            @(posedge clk);
        end

        @(negedge clk);
        context_valid          = 1'b0;
        command_done           = 1'b0;
        command_busy           = 1'b0;
        bc_busy                = 1'b0;
        pv_busy                = 1'b0;
        bc_wait_for_empty_bank = 1'b0;
        pv_wait_for_ready_bank = 1'b0;
        repeat (2) @(posedge clk);

        assert (context_count == TOTAL)
            else $fatal(1, "context_count=%0d", context_count);
        assert (duplicate_count == 0)
            else $fatal(1, "Unexpected duplicate_count=%0d",
                        duplicate_count);
        assert (missing_count == 0)
            else $fatal(1, "Unexpected missing_count=%0d",
                        missing_count);
        assert (error_bitmap == 0)
            else $fatal(1, "Unexpected error_bitmap=%h",
                        error_bitmap);
        assert (overlap_cycles > 0)
            else $fatal(1, "No overlap cycles counted");
        assert (bank_full_wait_cycles == 2)
            else $fatal(1, "bank_full_wait_cycles=%0d",
                        bank_full_wait_cycles);
        assert (bank_empty_wait_cycles == 3)
            else $fatal(1, "bank_empty_wait_cycles=%0d",
                        bank_empty_wait_cycles);

        // Fault-injection command: emit index 0 twice, then skip to index 2,
        // and end early. Duplicate/missing detection must become nonzero.
        begin_command();

        @(negedge clk);
        set_context(0);
        context_valid = 1'b1;
        @(posedge clk);

        @(negedge clk);
        set_context(0);
        @(posedge clk);

        @(negedge clk);
        set_context(2);
        command_done = 1'b1;
        @(posedge clk);

        @(negedge clk);
        context_valid = 1'b0;
        command_done  = 1'b0;
        command_busy  = 1'b0;
        repeat (2) @(posedge clk);

        assert (duplicate_count > 0)
            else $fatal(1, "Duplicate injection not detected");
        assert (missing_count > 0)
            else $fatal(1, "Missing injection not detected");
        assert (error_bitmap[0])
            else $fatal(1, "Duplicate bitmap bit not set");
        assert (error_bitmap[1])
            else $fatal(1, "Missing bitmap bit not set");
        assert (error_bitmap[3])
            else $fatal(1, "Count mismatch bitmap bit not set");

        $display("================================================");
        $display("[PASS] Attention overlap performance counters");
        $display("Fault duplicate count = %0d", duplicate_count);
        $display("Fault missing count   = %0d", missing_count);
        $display("Fault error bitmap    = %h", error_bitmap);
        $display("================================================");
        $finish;
    end

endmodule
