`timescale 1ns/1ps

// Buffered, fair join for the A-owned and B4-owned diagnostic streams.
module cats_r4_a3_error_join (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        counter_clear,

    input  logic        a_valid,
    output logic        a_ready,
    input  logic [15:0] a_epoch,
    input  logic [2:0]  a_group,
    input  logic [4:0]  a_global_q_head,
    input  logic [6:0]  a_row,
    input  logic [1:0]  a_slot_id,
    input  logic [1:0]  a_numeric_mode,
    input  logic [2:0]  a_code,
    input  logic [6:0]  a_bad_key,

    input  logic        b_valid,
    output logic        b_ready,
    input  logic [15:0] b_epoch,
    input  logic [2:0]  b_group,
    input  logic [4:0]  b_global_q_head,
    input  logic [6:0]  b_row,
    input  logic [1:0]  b_slot_id,
    input  logic [1:0]  b_numeric_mode,
    input  logic [3:0]  b_code,
    input  logic [6:0]  b_bad_key,

    output logic        error_valid,
    input  logic        error_ready,
    output logic [1:0]  error_source,
    output logic [15:0] error_epoch,
    output logic [2:0]  error_group,
    output logic [4:0]  error_global_q_head,
    output logic [6:0]  error_row,
    output logic [1:0]  error_slot_id,
    output logic [1:0]  error_numeric_mode,
    output logic [3:0]  error_code,
    output logic [6:0]  error_bad_key,

    output logic [63:0] a_errors_accepted,
    output logic [63:0] b_errors_accepted,
    output logic [63:0] errors_delivered,
    output logic [63:0] simultaneous_errors,
    output logic [63:0] error_stall_cycles
);
    logic a_buf_valid, b_buf_valid;
    logic prefer_b;
    logic select_a, select_b;
    logic out_fire;

    logic [15:0] a_buf_epoch, b_buf_epoch;
    logic [2:0]  a_buf_group, b_buf_group;
    logic [4:0]  a_buf_head, b_buf_head;
    logic [6:0]  a_buf_row, b_buf_row;
    logic [1:0]  a_buf_slot, b_buf_slot;
    logic [1:0]  a_buf_mode, b_buf_mode;
    logic [2:0]  a_buf_code;
    logic [3:0]  b_buf_code;
    logic [6:0]  a_buf_bad_key, b_buf_bad_key;

    assign select_a = a_buf_valid && (!b_buf_valid || !prefer_b);
    assign select_b = b_buf_valid && (!a_buf_valid ||  prefer_b);
    assign error_valid = select_a || select_b;
    assign out_fire = error_valid && error_ready;

    // A selected buffer may be replaced on the same edge that it drains.
    assign a_ready = !a_buf_valid || (out_fire && select_a);
    assign b_ready = !b_buf_valid || (out_fire && select_b);

    assign error_source = select_b ? 2'd1 : 2'd0;
    assign error_epoch = select_b ? b_buf_epoch : a_buf_epoch;
    assign error_group = select_b ? b_buf_group : a_buf_group;
    assign error_global_q_head = select_b ? b_buf_head : a_buf_head;
    assign error_row = select_b ? b_buf_row : a_buf_row;
    assign error_slot_id = select_b ? b_buf_slot : a_buf_slot;
    assign error_numeric_mode = select_b ? b_buf_mode : a_buf_mode;
    assign error_code = select_b ? b_buf_code : {1'b0, a_buf_code};
    assign error_bad_key = select_b ? b_buf_bad_key : a_buf_bad_key;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_buf_valid <= 1'b0;
            b_buf_valid <= 1'b0;
            prefer_b <= 1'b0;
            a_buf_epoch <= '0; a_buf_group <= '0; a_buf_head <= '0;
            a_buf_row <= '0; a_buf_slot <= '0; a_buf_mode <= '0;
            a_buf_code <= '0; a_buf_bad_key <= '0;
            b_buf_epoch <= '0; b_buf_group <= '0; b_buf_head <= '0;
            b_buf_row <= '0; b_buf_slot <= '0; b_buf_mode <= '0;
            b_buf_code <= '0; b_buf_bad_key <= '0;
        end else if (clear) begin
            a_buf_valid <= 1'b0;
            b_buf_valid <= 1'b0;
            prefer_b <= 1'b0;
        end else begin
            if (a_valid && a_ready) begin
                a_buf_valid <= 1'b1;
                a_buf_epoch <= a_epoch;
                a_buf_group <= a_group;
                a_buf_head <= a_global_q_head;
                a_buf_row <= a_row;
                a_buf_slot <= a_slot_id;
                a_buf_mode <= a_numeric_mode;
                a_buf_code <= a_code;
                a_buf_bad_key <= a_bad_key;
            end else if (out_fire && select_a) begin
                a_buf_valid <= 1'b0;
            end

            if (b_valid && b_ready) begin
                b_buf_valid <= 1'b1;
                b_buf_epoch <= b_epoch;
                b_buf_group <= b_group;
                b_buf_head <= b_global_q_head;
                b_buf_row <= b_row;
                b_buf_slot <= b_slot_id;
                b_buf_mode <= b_numeric_mode;
                b_buf_code <= b_code;
                b_buf_bad_key <= b_bad_key;
            end else if (out_fire && select_b) begin
                b_buf_valid <= 1'b0;
            end

            // Set from the winner so one-sided traffic cannot corrupt fairness.
            if (out_fire)
                prefer_b <= select_a;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_errors_accepted <= '0;
            b_errors_accepted <= '0;
            errors_delivered <= '0;
            simultaneous_errors <= '0;
            error_stall_cycles <= '0;
        end else begin
            if (a_valid && a_ready)
                a_errors_accepted <= a_errors_accepted + 1'b1;
            if (b_valid && b_ready)
                b_errors_accepted <= b_errors_accepted + 1'b1;
            if (out_fire)
                errors_delivered <= errors_delivered + 1'b1;
            if (a_valid && a_ready && b_valid && b_ready)
                simultaneous_errors <= simultaneous_errors + 1'b1;
            if (error_valid && !error_ready)
                error_stall_cycles <= error_stall_cycles + 1'b1;

            if (counter_clear) begin
                a_errors_accepted <= '0;
                b_errors_accepted <= '0;
                errors_delivered <= '0;
                simultaneous_errors <= '0;
                error_stall_cycles <= '0;
            end
        end
    end

`ifndef SYNTHESIS
    logic [47:0] held_out_payload;
    logic out_was_stalled;
    logic counter_conservation_valid;
    logic [63:0] lifetime_accepted, lifetime_delivered;
    wire [47:0] out_payload = {
        error_source, error_epoch, error_group, error_global_q_head,
        error_row, error_slot_id, error_numeric_mode, error_code,
        error_bad_key
    };

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held_out_payload <= '0;
            out_was_stalled <= 1'b0;
            counter_conservation_valid <= 1'b1;
            lifetime_accepted <= '0;
            lifetime_delivered <= '0;
        end else if (clear) begin
            out_was_stalled <= 1'b0;
        end else begin
            if (out_was_stalled &&
                ((error_valid !== 1'b1) ||
                 (out_payload !== held_out_payload)))
                $fatal(1, "A3 unified error changed while stalled");
            if (counter_conservation_valid &&
                errors_delivered > a_errors_accepted + b_errors_accepted)
                $fatal(1, "A3 unified error counter conservation failed");
            if (lifetime_delivered > lifetime_accepted)
                $fatal(1, "A3 unified error lifetime conservation failed");

            out_was_stalled <= error_valid && !error_ready;
            if (error_valid && !error_ready)
                held_out_payload <= out_payload;

            case ({a_valid && a_ready, b_valid && b_ready})
                2'b01, 2'b10:
                    lifetime_accepted <= lifetime_accepted + 1'b1;
                2'b11:
                    lifetime_accepted <= lifetime_accepted + 2'd2;
                default: ;
            endcase
            if (out_fire)
                lifetime_delivered <= lifetime_delivered + 1'b1;

            // Clearing visible counters while a report is buffered creates a
            // legitimate post-clear delivery with no post-clear acceptance.
            if (counter_clear)
                counter_conservation_valid <= !(
                    a_buf_valid || b_buf_valid ||
                    (a_valid && a_ready) || (b_valid && b_ready));
        end
    end
`endif
endmodule
