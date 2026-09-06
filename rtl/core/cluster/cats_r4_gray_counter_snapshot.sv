`timescale 1ns/1ps

// Coherent multi-bit counter snapshot across asynchronous clock domains.
// The source freezes a binary-to-Gray encoded snapshot until the destination
// consumes it.  A toggle request/ack handshake permits exactly one outstanding
// sample.  The destination waits two clocks after seeing the request before
// converting the independently synchronized Gray bus, so no live multi-bit
// binary value is sampled across the boundary.
module cats_r4_gray_counter_snapshot #(
    parameter int WIDTH = 64
) (
    input  logic             arst_n,
    input  logic             src_clk,
    input  logic [WIDTH-1:0] src_counter,
    input  logic             src_snapshot_valid,
    output logic             src_snapshot_ready,
    output logic             src_protocol_error,

    input  logic             dst_clk,
    output logic             dst_snapshot_valid,
    input  logic             dst_snapshot_ready,
    output logic [WIDTH-1:0] dst_snapshot_data,
    output logic             dst_protocol_error
);
    logic req_toggle_src;
    logic ack_toggle_dst;
    logic [WIDTH-1:0] held_gray_src;
    logic src_waiting;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] ack_sync_src;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] req_sync_dst;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [WIDTH-1:0] gray_sync_dst_0;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [WIDTH-1:0] gray_sync_dst_1;

    logic req_seen_dst;
    logic [1:0] settle_count;
    logic capture_pending;

    function automatic logic [WIDTH-1:0] binary_to_gray(
        input logic [WIDTH-1:0] value
    );
        binary_to_gray = value ^ (value >> 1);
    endfunction

    function automatic logic [WIDTH-1:0] gray_to_binary(
        input logic [WIDTH-1:0] value
    );
        integer bit_index;
        begin
            gray_to_binary[WIDTH-1] = value[WIDTH-1];
            for (bit_index = WIDTH-2; bit_index >= 0; bit_index = bit_index-1)
                gray_to_binary[bit_index] =
                    gray_to_binary[bit_index+1] ^ value[bit_index];
        end
    endfunction

    assign src_snapshot_ready = (ack_sync_src[1] == req_toggle_src);

    always_ff @(posedge src_clk or negedge arst_n) begin
        if (!arst_n) begin
            req_toggle_src    <= 1'b0;
            held_gray_src     <= '0;
            ack_sync_src      <= '0;
            src_waiting       <= 1'b0;
            src_protocol_error<= 1'b0;
        end else begin
            ack_sync_src <= {ack_sync_src[0], ack_toggle_dst};
            if (src_snapshot_valid && src_snapshot_ready) begin
                held_gray_src  <= binary_to_gray(src_counter);
                req_toggle_src <= ~req_toggle_src;
                src_waiting    <= 1'b0;
            end else if (!src_waiting && src_snapshot_valid) begin
                // Standard ready/valid permits valid to remain asserted while
                // busy.  Remember that obligation so only an early withdraw
                // is treated as a protocol error.
                src_waiting <= 1'b1;
            end else if (src_waiting && !src_snapshot_valid) begin
                src_protocol_error <= 1'b1;
                src_waiting <= 1'b0;
            end
        end
    end

    always_ff @(posedge dst_clk or negedge arst_n) begin
        if (!arst_n) begin
            req_sync_dst       <= '0;
            gray_sync_dst_0    <= '0;
            gray_sync_dst_1    <= '0;
            req_seen_dst       <= 1'b0;
            settle_count       <= '0;
            capture_pending    <= 1'b0;
            dst_snapshot_valid <= 1'b0;
            dst_snapshot_data  <= '0;
            ack_toggle_dst     <= 1'b0;
            dst_protocol_error <= 1'b0;
        end else begin
            req_sync_dst    <= {req_sync_dst[0], req_toggle_src};
            gray_sync_dst_0 <= held_gray_src;
            gray_sync_dst_1 <= gray_sync_dst_0;

            if ((req_sync_dst[1] != req_seen_dst) &&
                (capture_pending || dst_snapshot_valid))
                dst_protocol_error <= 1'b1;

            if ((req_sync_dst[1] != req_seen_dst) &&
                !capture_pending && !dst_snapshot_valid) begin
                req_seen_dst    <= req_sync_dst[1];
                settle_count    <= 2;
                capture_pending <= 1'b1;
            end else if (capture_pending) begin
                if (settle_count != 0)
                    settle_count <= settle_count - 1'b1;
                else begin
                    dst_snapshot_data  <= gray_to_binary(gray_sync_dst_1);
                    dst_snapshot_valid <= 1'b1;
                    capture_pending    <= 1'b0;
                end
            end

            if (dst_snapshot_valid && dst_snapshot_ready) begin
                dst_snapshot_valid <= 1'b0;
                ack_toggle_dst     <= req_seen_dst;
            end
        end
    end

    initial begin
        if (WIDTH < 2)
            $error("cats_r4_gray_counter_snapshot: WIDTH must be at least 2");
    end
endmodule
