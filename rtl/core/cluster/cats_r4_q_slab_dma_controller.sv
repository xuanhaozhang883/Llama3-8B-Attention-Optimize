`timescale 1ns/1ps

// CATS-R4 IF_V2 Q-slab DMA adapter (C2 infrastructure only).
//
// One accepted q_fill token becomes exactly one aligned 4 KiB read
// descriptor. The matching DMA completion becomes q_publish only after both
// its epoch and opaque tag match. Only one descriptor is outstanding in this
// C2 adapter; fill still overlaps compute from the other Q half.
//
// NOT READY: this core-clock model still requires the AXI/core async command
// and write-data gearbox before it may enter the production manifest.
module cats_r4_q_slab_dma_controller #(
    parameter int ADDR_W = 64,
    parameter int DMA_TAG_W = 12
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   counter_clear,

    input  logic                   start_valid,
    output logic                   start_ready,
    input  logic [15:0]            start_epoch,
    input  logic [ADDR_W-1:0]      start_q_base,

    input  logic                   q_fill_valid,
    output logic                   q_fill_ready,
    input  logic                   q_fill_buffer,
    input  logic [15:0]            q_fill_epoch,
    input  logic [2:0]             q_fill_group,
    input  logic [4:0]             q_fill_global_q_head,
    input  logic [2:0]             q_fill_row_window,

    output logic                   q_publish_valid,
    input  logic                   q_publish_ready,
    output logic                   q_publish_buffer,
    output logic [15:0]            q_publish_epoch,
    output logic [2:0]             q_publish_group,
    output logic [4:0]             q_publish_global_q_head,
    output logic [2:0]             q_publish_row_window,

    output logic                   dma_desc_valid,
    input  logic                   dma_desc_ready,
    output logic [ADDR_W-1:0]      dma_desc_addr,
    output logic [31:0]            dma_desc_byte_count,
    output logic [DMA_TAG_W-1:0]   dma_desc_tag,
    output logic [15:0]            dma_desc_epoch,

    input  logic                   dma_cpl_valid,
    output logic                   dma_cpl_ready,
    input  logic [DMA_TAG_W-1:0]   dma_cpl_tag,
    input  logic [15:0]            dma_cpl_epoch,
    input  logic                   dma_cpl_error,

    output logic                   running,
    output logic                   transaction_done,
    output logic                   halted,
    output logic                   error_sticky,
    output logic [63:0]            q_slab_desc_count,
    output logic [63:0]            q_slab_completion_count,
    output logic [63:0]            q_slab_publish_count,
    output logic [63:0]            q_slab_byte_count,
    output logic [63:0]            q_slab_beat_count,
    output logic [63:0]            q_slab_burst_count,
    output logic [63:0]            q_slab_desc_wait_cycles,
    output logic [63:0]            q_slab_publish_wait_cycles,
    output logic [63:0]            q_slab_tag_errors,
    output logic [63:0]            q_slab_epoch_errors,
    output logic [63:0]            protocol_errors,
    output logic [63:0]            dma_errors
);
    localparam logic [1:0] IDLE = 2'd0;
    localparam logic [1:0] DESC = 2'd1;
    localparam logic [1:0] WAIT_CPL = 2'd2;
    localparam logic [1:0] PUBLISH = 2'd3;
    localparam logic [2:0] Q_TAG_PREFIX = 3'b001;
    localparam logic [31:0] Q_SLAB_BYTES = 32'd4096;
    localparam logic [63:0] Q_SLAB_BEATS = 64'd512;
    localparam logic [63:0] Q_SLAB_BURSTS = 64'd2;

    logic [1:0] state;
    logic [15:0] epoch_reg;
    logic [ADDR_W-1:0] q_base_reg;
    logic token_buffer;
    logic [15:0] token_epoch;
    logic [2:0] token_group;
    logic [4:0] token_head;
    logic [2:0] token_window;
    logic [DMA_TAG_W-1:0] token_tag;
    logic [8:0] expected_ordinal;
    logic q_fill_token_sane;
    logic q_fill_token_ordered;
    logic q_fill_invalid;
    logic q_fill_reject_seen;
    logic cpl_tag_match;
    logic cpl_epoch_match;

    function automatic [DMA_TAG_W-1:0] make_tag(
        input logic buffer_sel,
        input logic [4:0] head,
        input logic [2:0] window
    );
        logic [11:0] raw_tag;
        begin
            raw_tag = {Q_TAG_PREFIX, buffer_sel, head, window};
            make_tag = '0;
            make_tag[11:0] = raw_tag;
        end
    endfunction

    assign start_ready = !running && !halted && (state == IDLE);

    assign q_fill_token_sane =
        (q_fill_epoch == epoch_reg) &&
        (q_fill_global_q_head[4:2] == q_fill_group);
    assign q_fill_token_ordered =
        ({1'b0, q_fill_global_q_head, q_fill_row_window} ==
         expected_ordinal);
    assign q_fill_invalid = q_fill_valid && running && (state == IDLE) &&
                            (!q_fill_token_sane || !q_fill_token_ordered);
    assign q_fill_ready = running && !halted && (state == IDLE) &&
                          q_fill_token_sane && q_fill_token_ordered;

    assign dma_desc_valid = running && !halted && (state == DESC);
    assign dma_desc_addr = q_base_reg +
                           ({{(ADDR_W-5){1'b0}}, token_head} << 15) +
                           ({{(ADDR_W-3){1'b0}}, token_window} << 12);
    assign dma_desc_byte_count = Q_SLAB_BYTES;
    assign dma_desc_tag = token_tag;
    assign dma_desc_epoch = token_epoch;

    assign dma_cpl_ready = running && !halted;
    assign cpl_tag_match = (dma_cpl_tag == token_tag);
    assign cpl_epoch_match = (dma_cpl_epoch == token_epoch);

    assign q_publish_valid = running && !halted && (state == PUBLISH);
    assign q_publish_buffer = token_buffer;
    assign q_publish_epoch = token_epoch;
    assign q_publish_group = token_group;
    assign q_publish_global_q_head = token_head;
    assign q_publish_row_window = token_window;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            epoch_reg <= '0;
            q_base_reg <= '0;
            token_buffer <= 1'b0;
            token_epoch <= '0;
            token_group <= '0;
            token_head <= '0;
            token_window <= '0;
            token_tag <= '0;
            expected_ordinal <= '0;
            q_fill_reject_seen <= 1'b0;
            running <= 1'b0;
            transaction_done <= 1'b0;
            halted <= 1'b0;
            error_sticky <= 1'b0;
            q_slab_desc_count <= '0;
            q_slab_completion_count <= '0;
            q_slab_publish_count <= '0;
            q_slab_byte_count <= '0;
            q_slab_beat_count <= '0;
            q_slab_burst_count <= '0;
            q_slab_desc_wait_cycles <= '0;
            q_slab_publish_wait_cycles <= '0;
            q_slab_tag_errors <= '0;
            q_slab_epoch_errors <= '0;
            protocol_errors <= '0;
            dma_errors <= '0;
        end else begin
            if (!q_fill_valid || q_fill_ready)
                q_fill_reject_seen <= 1'b0;
            else if (q_fill_invalid && !q_fill_reject_seen) begin
                q_fill_reject_seen <= 1'b1;
                protocol_errors <= protocol_errors + 1'b1;
                error_sticky <= 1'b1;
                if (q_fill_epoch != epoch_reg)
                    q_slab_epoch_errors <= q_slab_epoch_errors + 1'b1;
                if ((q_fill_global_q_head[4:2] != q_fill_group) ||
                    !q_fill_token_ordered)
                    q_slab_tag_errors <= q_slab_tag_errors + 1'b1;
            end

            if (start_valid && start_ready) begin
                epoch_reg <= start_epoch;
                q_base_reg <= start_q_base;
                expected_ordinal <= '0;
                running <= 1'b1;
                transaction_done <= 1'b0;
                error_sticky <= 1'b0;
                q_slab_desc_count <= '0;
                q_slab_completion_count <= '0;
                q_slab_publish_count <= '0;
                q_slab_byte_count <= '0;
                q_slab_beat_count <= '0;
                q_slab_burst_count <= '0;
                q_slab_desc_wait_cycles <= '0;
                q_slab_publish_wait_cycles <= '0;
                q_slab_tag_errors <= '0;
                q_slab_epoch_errors <= '0;
                protocol_errors <= '0;
                dma_errors <= '0;
                if (start_q_base[11:0] != 12'd0) begin
                    running <= 1'b0;
                    halted <= 1'b1;
                    error_sticky <= 1'b1;
                    protocol_errors <= 64'd1;
                end
            end else if (running && !halted) begin
                case (state)
                    IDLE: begin
                        if (q_fill_valid && q_fill_ready) begin
                            token_buffer <= q_fill_buffer;
                            token_epoch <= q_fill_epoch;
                            token_group <= q_fill_group;
                            token_head <= q_fill_global_q_head;
                            token_window <= q_fill_row_window;
                            token_tag <= make_tag(
                                q_fill_buffer,
                                q_fill_global_q_head,
                                q_fill_row_window
                            );
                            state <= DESC;
                        end
                    end

                    DESC: begin
                        if (dma_desc_valid && dma_desc_ready) begin
                            q_slab_desc_count <= q_slab_desc_count + 1'b1;
                            q_slab_byte_count <=
                                q_slab_byte_count + Q_SLAB_BYTES;
                            q_slab_beat_count <=
                                q_slab_beat_count + Q_SLAB_BEATS;
                            q_slab_burst_count <=
                                q_slab_burst_count + Q_SLAB_BURSTS;
                            state <= WAIT_CPL;
                        end else begin
                            q_slab_desc_wait_cycles <=
                                q_slab_desc_wait_cycles + 1'b1;
                        end
                    end

                    WAIT_CPL: begin
                        if (dma_cpl_valid && dma_cpl_ready) begin
                            if (dma_cpl_error || !cpl_tag_match ||
                                !cpl_epoch_match) begin
                                running <= 1'b0;
                                halted <= 1'b1;
                                error_sticky <= 1'b1;
                                protocol_errors <= protocol_errors + 1'b1;
                                if (dma_cpl_error)
                                    dma_errors <= dma_errors + 1'b1;
                                if (!cpl_tag_match)
                                    q_slab_tag_errors <=
                                        q_slab_tag_errors + 1'b1;
                                if (!cpl_epoch_match)
                                    q_slab_epoch_errors <=
                                        q_slab_epoch_errors + 1'b1;
                            end else begin
                                q_slab_completion_count <=
                                    q_slab_completion_count + 1'b1;
                                state <= PUBLISH;
                            end
                        end
                    end

                    PUBLISH: begin
                        if (q_publish_valid && q_publish_ready) begin
                            q_slab_publish_count <=
                                q_slab_publish_count + 1'b1;
                            if (expected_ordinal == 9'd255) begin
                                running <= 1'b0;
                                transaction_done <= 1'b1;
                                expected_ordinal <= '0;
                            end else begin
                                expected_ordinal <= expected_ordinal + 1'b1;
                            end
                            state <= IDLE;
                        end else begin
                            q_slab_publish_wait_cycles <=
                                q_slab_publish_wait_cycles + 1'b1;
                        end
                    end

                    default: begin
                        running <= 1'b0;
                        halted <= 1'b1;
                        error_sticky <= 1'b1;
                        protocol_errors <= protocol_errors + 1'b1;
                        state <= IDLE;
                    end
                endcase

                if (dma_cpl_valid && dma_cpl_ready &&
                    (state != WAIT_CPL)) begin
                    running <= 1'b0;
                    halted <= 1'b1;
                    error_sticky <= 1'b1;
                    protocol_errors <= protocol_errors + 1'b1;
                    q_slab_tag_errors <= q_slab_tag_errors + 1'b1;
                end
            end

            if (counter_clear) begin
                q_slab_desc_count <= '0;
                q_slab_completion_count <= '0;
                q_slab_publish_count <= '0;
                q_slab_byte_count <= '0;
                q_slab_beat_count <= '0;
                q_slab_burst_count <= '0;
                q_slab_desc_wait_cycles <= '0;
                q_slab_publish_wait_cycles <= '0;
                q_slab_tag_errors <= '0;
                q_slab_epoch_errors <= '0;
                protocol_errors <= '0;
                dma_errors <= '0;
                error_sticky <= 1'b0;
            end
        end
    end

    initial begin
        if (ADDR_W < 20)
            $error("cats_r4_q_slab_dma_controller: ADDR_W must be >= 20");
        if (DMA_TAG_W < 12)
            $error("cats_r4_q_slab_dma_controller: DMA_TAG_W must be >= 12");
    end
endmodule
