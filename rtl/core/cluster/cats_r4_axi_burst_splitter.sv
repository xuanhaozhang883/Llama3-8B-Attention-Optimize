`timescale 1ns/1ps

// CATS-R4 C2 AXI/DMA descriptor splitter (infrastructure only).
//
// Converts one aligned byte-range request into AXI4 burst descriptors for a
// 64-bit data bus.  Every emitted burst is at most 256 beats / 2048 bytes and
// is shortened when necessary so it never crosses a 4 KiB address boundary.
// Output payload remains stable for the full duration of valid && !ready.
//
// This block does not issue AXI transactions and is intentionally not wired
// into the production manifest or board top yet.
module cats_r4_axi_burst_splitter #(
    parameter int ADDR_W = 64,
    parameter int BYTE_COUNT_W = 32
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    clear,

    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic [ADDR_W-1:0]       in_addr,
    input  logic [BYTE_COUNT_W-1:0] in_byte_count,
    input  logic [7:0]              in_tag,

    output logic                    out_valid,
    input  logic                    out_ready,
    output logic [ADDR_W-1:0]       out_addr,
    output logic [7:0]              out_axi_len,
    output logic [8:0]              out_beats,
    output logic [11:0]             out_byte_count,
    output logic [7:0]              out_tag,
    output logic                    out_last,

    output logic                    busy,
    output logic                    protocol_error,
    output logic [31:0]             input_desc_count,
    output logic [31:0]             burst_desc_count,
    output logic [31:0]             error_count,
    output logic [63:0]             emitted_beat_count
);
    localparam int BEAT_BYTES = 8;
    localparam int MAX_BEATS  = 256;

    logic active;
    logic [ADDR_W-1:0] current_addr;
    logic [BYTE_COUNT_W-1:0] remaining_beats;
    logic [7:0] current_tag;

    logic [12:0] bytes_to_4k;
    logic [9:0]  beats_to_4k;
    logic [BYTE_COUNT_W-1:0] planned_beats_wide;
    logic [8:0] planned_beats;
    logic input_invalid;
    logic input_overflow;
    logic [ADDR_W:0] input_end_extended;

    always_comb begin
        input_end_extended = {1'b0, in_addr} + in_byte_count;
        input_overflow = input_end_extended[ADDR_W];
        input_invalid = (in_byte_count == 0) ||
                        (in_addr[2:0] != 3'b000) ||
                        (in_byte_count[2:0] != 3'b000) ||
                        input_overflow;

        bytes_to_4k = 13'd4096 - {1'b0, current_addr[11:0]};
        beats_to_4k = bytes_to_4k >> 3;
        planned_beats_wide = remaining_beats;
        if (planned_beats_wide > MAX_BEATS)
            planned_beats_wide = MAX_BEATS;
        if (planned_beats_wide > beats_to_4k)
            planned_beats_wide = beats_to_4k;
        planned_beats = planned_beats_wide[8:0];
    end

    assign in_ready = !active && !out_valid;
    assign busy = active || out_valid;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            active             <= 1'b0;
            current_addr       <= '0;
            remaining_beats    <= '0;
            current_tag        <= '0;
            out_valid          <= 1'b0;
            out_addr           <= '0;
            out_axi_len        <= '0;
            out_beats          <= '0;
            out_byte_count     <= '0;
            out_tag            <= '0;
            out_last           <= 1'b0;
            protocol_error     <= 1'b0;
            input_desc_count   <= '0;
            burst_desc_count   <= '0;
            error_count        <= '0;
            emitted_beat_count <= '0;
        end else begin
            if (in_valid && in_ready) begin
                input_desc_count <= input_desc_count + 1'b1;
                if (input_invalid) begin
                    protocol_error <= 1'b1;
                    error_count <= error_count + 1'b1;
                end else begin
                    active          <= 1'b1;
                    current_addr    <= in_addr;
                    remaining_beats <= in_byte_count >> 3;
                    current_tag     <= in_tag;
                end
            end

            if (active && !out_valid) begin
                out_valid      <= 1'b1;
                out_addr       <= current_addr;
                out_axi_len    <= planned_beats[7:0] - 1'b1;
                out_beats      <= planned_beats;
                out_byte_count <= {planned_beats, 3'b000};
                out_tag        <= current_tag;
                out_last       <= (remaining_beats == planned_beats_wide);
            end

            if (out_valid && out_ready) begin
                out_valid          <= 1'b0;
                burst_desc_count   <= burst_desc_count + 1'b1;
                emitted_beat_count <= emitted_beat_count + out_beats;
                if (out_last) begin
                    active          <= 1'b0;
                    remaining_beats <= '0;
                end else begin
                    current_addr <= current_addr +
                                    ({{(ADDR_W-9){1'b0}}, out_beats} << 3);
                    remaining_beats <= remaining_beats - out_beats;
                end
            end
        end
    end

    initial begin
        if (ADDR_W < 12)
            $error("cats_r4_axi_burst_splitter: ADDR_W must be at least 12");
        if (BYTE_COUNT_W < 12)
            $error("cats_r4_axi_burst_splitter: BYTE_COUNT_W must be at least 12");
    end
endmodule
