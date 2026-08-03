`timescale 1ns/1ps

module tb_v25_pingpong_integration;
    localparam int SEQ_LEN    = 8;
    localparam int HEAD_DIM   = 8;
    localparam int Q_HEADS    = 4;
    localparam int NUM_GROUPS = 4;
    localparam int HEAD_W     = 2;
    localparam int GROUP_W    = 2;
    localparam int GLOBAL_W   = 4;
    localparam int POS_W      = 3;
    localparam int DIM_W      = 3;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic start;
    logic start_ready;
    logic sched_busy;
    logic done;
    logic buffer_start;

    logic fill_start_valid;
    logic fill_start_ready;
    logic [GROUP_W-1:0] fill_start_group_id;
    logic bc_group_start;
    logic bc_group_start_ready;
    logic [GROUP_W-1:0] bc_group_id;
    logic bc_group_done;
    logic bc_busy;

    logic [31:0] in_p_vec_bf16;
    logic [31:0] in_v_vec_bf16;
    logic in_valid;
    logic in_ready;
    logic in_first;
    logic in_last;
    logic in_group_last;
    logic [GROUP_W-1:0] in_group_id;
    logic [HEAD_W-1:0] in_head;
    logic [GLOBAL_W-1:0] in_global_q_head;
    logic [POS_W-1:0] in_row_base;
    logic [DIM_W-1:0] in_feature_base;
    logic [POS_W-1:0] in_reduce_index;

    logic capture_complete;
    logic capture_done;
    logic capture_busy;
    logic drain_valid;
    logic drain_ready;
    logic [GROUP_W-1:0] drain_group_id;
    logic drain_release;

    logic pv_start;
    logic pv_feed_enable;
    logic [GROUP_W-1:0] pv_group_id;
    logic pv_done;
    logic pv_busy;
    logic [HEAD_W-1:0] req_head;
    logic [POS_W-1:0] req_row_base;
    logic [DIM_W-1:0] req_col_base;
    logic [POS_W-1:0] req_reduce;
    logic [63:0] out_p_vec_bf16;
    logic [63:0] out_v_vec_bf16;
    logic out_valid;
    logic out_ready;

    logic [1:0] bank0_state;
    logic [1:0] bank1_state;
    logic drain_active;
    logic buffer_busy;
    logic buffer_error;
    logic controller_error;
    logic group_complete;
    logic [GROUP_W-1:0] completed_group_id;
    logic [GROUP_W-1:0] active_group_id;
    logic start_busy_error;

    logic [HEAD_W-1:0] src_head;
    logic [POS_W-1:0] src_row_base;
    logic [DIM_W-1:0] src_feature_base;
    logic [POS_W-1:0] src_reduce;
    logic [GROUP_W-1:0] src_group;

    logic [GROUP_W-1:0] pv_group_reg;
    integer overlap_cycles;
    integer cycle_count;
    integer lane;

    function automatic [15:0] p_value(
        input integer group_i,
        input integer head_i,
        input integer row_i,
        input integer reduce_i
    );
        integer value;
        begin
            value = group_i*4000 + head_i*800 + row_i*40 + reduce_i;
            p_value = value[15:0];
        end
    endfunction

    function automatic [15:0] v_value(
        input integer group_i,
        input integer reduce_i,
        input integer col_i
    );
        integer value;
        begin
            value = 16'h8000 + group_i*500 + reduce_i*20 + col_i;
            v_value = value[15:0];
        end
    endfunction

    assign bc_group_start_ready = !bc_busy;
    assign in_valid             = bc_busy;
    assign in_group_id          = src_group;
    assign in_head              = src_head;
    assign in_global_q_head     = src_group*Q_HEADS + src_head;
    assign in_row_base          = src_row_base;
    assign in_feature_base      = src_feature_base;
    assign in_reduce_index      = src_reduce;
    assign in_first             = (src_reduce == 0);
    assign in_last              = (src_reduce == SEQ_LEN-1);
    assign in_group_last        =
        (src_head == Q_HEADS-1) &&
        (src_row_base == SEQ_LEN-2) &&
        (src_feature_base == HEAD_DIM-2) &&
        (src_reduce == SEQ_LEN-1);
    assign in_p_vec_bf16 = {
        p_value(src_group, src_head, src_row_base+1, src_reduce),
        p_value(src_group, src_head, src_row_base,   src_reduce)
    };
    assign in_v_vec_bf16 = {
        v_value(src_group, src_reduce, src_feature_base+1),
        v_value(src_group, src_reduce, src_feature_base)
    };

    always_ff @(posedge clk) begin
        if (!rst_n || buffer_start) begin
            bc_group_done    <= 1'b0;
            bc_busy          <= 1'b0;
            src_group        <= '0;
            src_head         <= '0;
            src_row_base     <= '0;
            src_feature_base <= '0;
            src_reduce       <= '0;
        end else begin
            bc_group_done <= 1'b0;

            if (bc_group_start) begin
                bc_busy          <= 1'b1;
                src_group        <= bc_group_id;
                src_head         <= '0;
                src_row_base     <= '0;
                src_feature_base <= '0;
                src_reduce       <= '0;
            end

            if (in_valid && in_ready) begin
                if (src_reduce < SEQ_LEN-1) begin
                    src_reduce <= src_reduce + 1'b1;
                end else begin
                    src_reduce <= '0;
                    if (src_feature_base < HEAD_DIM-2) begin
                        src_feature_base <= src_feature_base + 2;
                    end else begin
                        src_feature_base <= '0;
                        if (src_row_base < SEQ_LEN-2) begin
                            src_row_base <= src_row_base + 2;
                        end else begin
                            src_row_base <= '0;
                            if (src_head < Q_HEADS-1) begin
                                src_head <= src_head + 1'b1;
                            end else begin
                                bc_busy       <= 1'b0;
                                bc_group_done <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    assign out_ready =
        pv_busy && ((cycle_count % 5) != 2);

    always_ff @(posedge clk) begin
        if (!rst_n || buffer_start) begin
            pv_done      <= 1'b0;
            pv_busy      <= 1'b0;
            pv_group_reg <= '0;
            req_head     <= '0;
            req_row_base <= '0;
            req_col_base <= '0;
            req_reduce   <= '0;
            overlap_cycles <= 0;
            cycle_count  <= 0;
        end else begin
            pv_done     <= 1'b0;
            cycle_count <= cycle_count + 1;

            if (bc_busy && pv_busy)
                overlap_cycles <= overlap_cycles + 1;

            if (pv_start) begin
                pv_busy      <= 1'b1;
                pv_group_reg <= pv_group_id;
                req_head     <= '0;
                req_row_base <= '0;
                req_col_base <= '0;
                req_reduce   <= '0;
            end

            if (out_valid && out_ready) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (out_p_vec_bf16[lane*16 +: 16] !==
                        p_value(pv_group_reg, req_head,
                                req_row_base+lane, req_reduce)) begin
                        $fatal(
                            1,
                            "P mismatch g=%0d h=%0d rb=%0d c=%0d k=%0d lane=%0d",
                            pv_group_reg, req_head, req_row_base,
                            req_col_base, req_reduce, lane
                        );
                    end
                    if (out_v_vec_bf16[lane*16 +: 16] !==
                        v_value(pv_group_reg, req_reduce,
                                req_col_base+lane)) begin
                        $fatal(
                            1,
                            "V mismatch g=%0d h=%0d rb=%0d c=%0d k=%0d lane=%0d",
                            pv_group_reg, req_head, req_row_base,
                            req_col_base, req_reduce, lane
                        );
                    end
                end

                if (req_reduce < SEQ_LEN-1) begin
                    req_reduce <= req_reduce + 1'b1;
                end else begin
                    req_reduce <= '0;
                    if (req_col_base < HEAD_DIM-4) begin
                        req_col_base <= req_col_base + 4;
                    end else begin
                        req_col_base <= '0;
                        if (req_row_base < SEQ_LEN-4) begin
                            req_row_base <= req_row_base + 4;
                        end else begin
                            req_row_base <= '0;
                            if (req_head < Q_HEADS-1) begin
                                req_head <= req_head + 1'b1;
                            end else begin
                                pv_busy <= 1'b0;
                                pv_done <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    pv_tile2_to_tile4_pingpong_adapter #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(NUM_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) u_buffer (
        .clk,
        .rst_n,
        .start(buffer_start),
        .fill_start_valid,
        .fill_start_ready,
        .fill_start_group_id,
        .in_p_vec_bf16,
        .in_v_vec_bf16,
        .in_valid,
        .in_ready,
        .in_first,
        .in_last,
        .in_group_last,
        .in_group_id,
        .in_head,
        .in_global_q_head,
        .in_row_base,
        .in_feature_base,
        .in_reduce_index,
        .capture_complete,
        .capture_done,
        .capture_busy,
        .drain_valid,
        .drain_ready,
        .drain_group_id,
        .drain_release,
        .feed_enable(pv_feed_enable),
        .req_head,
        .req_row_base,
        .req_col_base,
        .req_reduce,
        .out_p_vec_bf16,
        .out_v_vec_bf16,
        .out_valid,
        .out_ready,
        .bank0_state,
        .bank1_state,
        .drain_active,
        .buffer_busy,
        .protocol_error(buffer_error)
    );

    attention_group_pingpong_controller #(
        .NUM_GROUPS(NUM_GROUPS),
        .GROUP_W(GROUP_W)
    ) u_scheduler (
        .clk,
        .rst_n,
        .start,
        .start_ready,
        .busy(sched_busy),
        .done,
        .buffer_start,
        .fill_start_valid,
        .fill_start_ready,
        .fill_start_group_id,
        .bc_group_start,
        .bc_group_start_ready,
        .bc_group_id,
        .bc_group_done,
        .bc_busy,
        .capture_done,
        .drain_valid,
        .drain_ready,
        .drain_group_id,
        .pv_start,
        .pv_feed_enable,
        .pv_group_id,
        .pv_done,
        .pv_busy,
        .drain_release,
        .child_protocol_error(buffer_error),
        .group_complete,
        .completed_group_id,
        .active_group_id,
        .start_while_busy_error(start_busy_error),
        .protocol_error(controller_error)
    );

    initial begin
        start = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin
                wait (done);
            end
            begin
                repeat (200000) @(posedge clk);
                $fatal(1, "Timeout waiting for v2.5 Ping-Pong completion");
            end
        join_any
        disable fork;

        @(posedge clk);
        if (buffer_error || controller_error || start_busy_error)
            $fatal(
                1,
                "Protocol error: buffer=%0b controller=%0b start=%0b",
                buffer_error, controller_error, start_busy_error
            );
        if ((bank0_state != 0) || (bank1_state != 0) ||
            drain_active || buffer_busy)
            $fatal(
                1,
                "Banks not empty: b0=%0d b1=%0d drain=%0b buffer_busy=%0b",
                bank0_state, bank1_state, drain_active, buffer_busy
            );
        if (overlap_cycles == 0)
            $fatal(1, "No B+C/PV overlap was observed");
        if (completed_group_id != NUM_GROUPS-1)
            $fatal(1, "Wrong final completed Group");

        $display("V25_PINGPONG_INTEGRATION_TEST: PASS");
        $display(
            "overlap_cycles=%0d final_group=%0d active_group=%0d",
            overlap_cycles, completed_group_id, active_group_id
        );
        $finish;
    end

endmodule
