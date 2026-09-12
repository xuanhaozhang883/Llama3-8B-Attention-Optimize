`timescale 1ns/1ps

// CATS-R4 C2 single-cluster output CDC. A row tag becomes visible only after
// all four 512-bit chunks / 32 payload beats for that row enter the payload
// FIFO. The AXI side consumes exactly one tagged row at a time. No C3 arbiter.
module cats_r4_output_cdc #(parameter logic [13:0] FINAL_CHUNK = 14'h3fff) (
    input logic core_clk, core_rst_n, core_counter_clear,
    input logic in_valid,
    output logic in_ready,
    input logic [15:0] in_epoch,
    input logic [4:0] in_global_q_head,
    input logic [6:0] in_row,
    input logic [1:0] in_feature_block,
    input logic [511:0] in_data_bf16,
    input logic in_row_last, in_tensor_last,
    input logic axi_clk, axi_rst_n, axi_counter_clear,
    output logic out_valid,
    input logic out_ready,
    output logic [63:0] out_data,
    output logic [15:0] out_epoch,
    output logic [11:0] out_seq,
    output logic [4:0] out_global_q_head,
    output logic [6:0] out_row,
    output logic [5:0] out_beat_in_row,
    output logic out_row_last, out_tensor_last,
    output logic [63:0] payload_push_count, payload_pop_count,
    output logic [63:0] tag_push_count, tag_pop_count,
    output logic [63:0] full_stall_count, empty_stall_count,
    output logic [63:0] max_payload_occupancy, max_tag_occupancy,
    output logic [63:0] overflow_count, underflow_count,
    output logic [63:0] seq_error_count, epoch_error_count,
    output logic core_protocol_error, axi_protocol_error
);

    logic [13:0] input_chunk, expected_chunk;
    logic epoch_valid, seq_fault_latched;
    logic [15:0] active_epoch;
    logic input_epoch_bad,input_last_bad,input_seq_bad,input_fire;
    logic chunk_active;
    logic [511:0] chunk_data;
    logic [2:0] chunk_beat;
    logic [1:0] chunk_feature_block;
    logic [15:0] row_epoch;
    logic [11:0] row_seq;
    logic [4:0] row_head;
    logic [6:0] row_number;
    logic row_tensor_last,row_tag_pending;
    logic payload_wr_en,payload_wr_full,payload_rd_en,payload_rd_empty;
    logic [63:0] payload_wr_data,payload_rd_data;
    logic [10:0] payload_wr_level,payload_rd_level;
    logic tag_wr_en,tag_wr_full,tag_rd_en,tag_rd_empty;
    logic [63:0] tag_wr_data,tag_rd_data;
    logic [5:0] tag_wr_level,tag_rd_level;
    logic row_active_axi,tag_read_pending,tag_capture_wait;
    logic payload_read_pending,payload_capture_wait;
    logic [5:0] row_beat_axi;
    logic [63:0] active_tag_axi;

    assign input_chunk={in_global_q_head,in_row,in_feature_block};
    assign input_epoch_bad=epoch_valid&&(in_epoch!=active_epoch);
    assign input_last_bad=(in_row_last!=(in_feature_block==2'd3))||
        (in_tensor_last!=(input_chunk==FINAL_CHUNK));
    assign input_seq_bad=(input_chunk!=expected_chunk)||input_last_bad;
    // Old-epoch traffic is consumed and counted. Sequence faults stop ready.
    assign in_ready=!chunk_active&&!row_tag_pending&&!seq_fault_latched&&
        (!in_valid||input_epoch_bad||!input_seq_bad);
    assign input_fire=in_valid&&in_ready;
    assign payload_wr_en=chunk_active&&!payload_wr_full;
    assign payload_wr_data=chunk_data[chunk_beat*64+:64];
    assign tag_wr_en=row_tag_pending&&!tag_wr_full;
    assign tag_wr_data={row_epoch,row_seq,row_head,row_number,row_tensor_last,23'd0};

    cats_r4_async_fifo #(.DATA_WIDTH(64),.ADDR_WIDTH(10)) u_payload_fifo(
        .wr_clk(core_clk),.wr_rst_n(core_rst_n),.wr_en(payload_wr_en),
        .wr_data(payload_wr_data),.wr_full(payload_wr_full),.wr_level(payload_wr_level),
        .rd_clk(axi_clk),.rd_rst_n(axi_rst_n),.rd_en(payload_rd_en),
        .rd_data(payload_rd_data),.rd_empty(payload_rd_empty),.rd_level(payload_rd_level));
    cats_r4_async_fifo #(.DATA_WIDTH(64),.ADDR_WIDTH(5)) u_tag_fifo(
        .wr_clk(core_clk),.wr_rst_n(core_rst_n),.wr_en(tag_wr_en),
        .wr_data(tag_wr_data),.wr_full(tag_wr_full),.wr_level(tag_wr_level),
        .rd_clk(axi_clk),.rd_rst_n(axi_rst_n),.rd_en(tag_rd_en),
        .rd_data(tag_rd_data),.rd_empty(tag_rd_empty),.rd_level(tag_rd_level));

    always_ff @(posedge core_clk) begin
        if(!core_rst_n) begin
            expected_chunk<='0; epoch_valid<=0; active_epoch<='0;
            seq_fault_latched<=0; chunk_active<=0; chunk_data<='0;
            chunk_beat<='0; chunk_feature_block<='0; row_epoch<='0;
            row_seq<='0; row_head<='0; row_number<='0; row_tensor_last<=0;
            row_tag_pending<=0; payload_push_count<='0; tag_push_count<='0;
            full_stall_count<='0; max_payload_occupancy<='0;
            max_tag_occupancy<='0; overflow_count<='0; seq_error_count<='0;
            epoch_error_count<='0; core_protocol_error<=0;
        end else begin
            if(payload_wr_level>max_payload_occupancy)
                max_payload_occupancy<=payload_wr_level;
            if(tag_wr_level>max_tag_occupancy) max_tag_occupancy<=tag_wr_level;
            if(in_valid&&!input_epoch_bad&&input_seq_bad&&!seq_fault_latched) begin
                seq_fault_latched<=1; seq_error_count<=seq_error_count+1'b1;
                core_protocol_error<=1;
            end
            if(input_fire) begin
                if(input_epoch_bad) begin
                    epoch_error_count<=epoch_error_count+1'b1;
                    core_protocol_error<=1;
                end else begin
                    chunk_active<=1; chunk_data<=in_data_bf16; chunk_beat<='0;
                    chunk_feature_block<=in_feature_block;
                    if(!epoch_valid) begin epoch_valid<=1; active_epoch<=in_epoch; end
                    if(in_feature_block==0) begin
                        row_epoch<=in_epoch; row_seq<={in_global_q_head,in_row};
                        row_head<=in_global_q_head; row_number<=in_row;
                        row_tensor_last<=in_tensor_last;
                    end else if(in_tensor_last) row_tensor_last<=1;
                    expected_chunk<=(input_chunk==FINAL_CHUNK)?'0:input_chunk+1'b1;
                end
            end
            if((chunk_active&&payload_wr_full)||
               (row_tag_pending&&tag_wr_full))
                full_stall_count<=full_stall_count+1'b1;
            if(payload_wr_en) begin
                payload_push_count<=payload_push_count+1'b1;
                if(chunk_beat==7) begin
                    chunk_active<=0; chunk_beat<='0;
                    if(chunk_feature_block==3) row_tag_pending<=1;
                end else chunk_beat<=chunk_beat+1'b1;
            end
            if(tag_wr_en) begin
                row_tag_pending<=0; tag_push_count<=tag_push_count+1'b1;
                if(row_tensor_last) epoch_valid<=0;
            end
            // These are signoff invariants; safe enable gating keeps them zero.
            if((payload_wr_en&&payload_wr_full)||(tag_wr_en&&tag_wr_full)) begin
                overflow_count<=overflow_count+1'b1; core_protocol_error<=1;
            end
            if(core_counter_clear) begin
                payload_push_count<='0; tag_push_count<='0; full_stall_count<='0;
                max_payload_occupancy<=payload_wr_level;
                max_tag_occupancy<=tag_wr_level; overflow_count<='0;
                seq_error_count<='0; epoch_error_count<='0;
                core_protocol_error<=0;
            end
        end
    end

    assign out_epoch=active_tag_axi[63:48];
    assign out_seq=active_tag_axi[47:36];
    assign out_global_q_head=active_tag_axi[35:31];
    assign out_row=active_tag_axi[30:24];
    assign out_beat_in_row=row_beat_axi;
    assign out_row_last=out_valid&&(row_beat_axi==31);
    assign out_tensor_last=out_row_last&&active_tag_axi[23];

    always_ff @(posedge axi_clk) begin
        if(!axi_rst_n) begin
            tag_rd_en<=0; payload_rd_en<=0; row_active_axi<=0;
            tag_read_pending<=0; tag_capture_wait<=0;
            payload_read_pending<=0; payload_capture_wait<=0;
            row_beat_axi<='0;
            active_tag_axi<='0; out_valid<=0; out_data<='0;
            payload_pop_count<='0; tag_pop_count<='0; empty_stall_count<='0;
            underflow_count<='0; axi_protocol_error<=0;
        end else begin
            tag_rd_en<=0; payload_rd_en<=0;
            if(!row_active_axi&&!tag_read_pending&&!tag_capture_wait&&
               !tag_rd_empty) begin
                tag_rd_en<=1; tag_read_pending<=1;
            end else if(tag_read_pending) begin
                // cats_r4_async_fifo performs a synchronous read on the
                // cycle after registered rd_en.  Capture rd_data one further
                // AXI edge later, after the FIFO nonblocking update commits.
                tag_read_pending<=0; tag_capture_wait<=1;
            end else if(tag_capture_wait) begin
                active_tag_axi<=tag_rd_data; tag_capture_wait<=0;
                row_active_axi<=1; row_beat_axi<='0;
                tag_pop_count<=tag_pop_count+1'b1;
            end
            if(row_active_axi&&!out_valid&&!payload_read_pending&&
               !payload_capture_wait&&!payload_rd_empty) begin
                payload_rd_en<=1; payload_read_pending<=1;
            end else if(payload_read_pending) begin
                payload_read_pending<=0; payload_capture_wait<=1;
            end else if(payload_capture_wait) begin
                out_data<=payload_rd_data; out_valid<=1;
                payload_capture_wait<=0;
            end
            if(row_active_axi&&!out_valid&&!payload_read_pending&&
               !payload_capture_wait&&payload_rd_empty)
                empty_stall_count<=empty_stall_count+1'b1;
            if(out_valid&&out_ready) begin
                out_valid<=0; payload_pop_count<=payload_pop_count+1'b1;
                if(row_beat_axi==31) begin row_active_axi<=0; row_beat_axi<='0; end
                else row_beat_axi<=row_beat_axi+1'b1;
            end
            if((payload_rd_en&&payload_rd_empty)||(tag_rd_en&&tag_rd_empty)) begin
                underflow_count<=underflow_count+1'b1; axi_protocol_error<=1;
            end
            if(axi_counter_clear) begin
                payload_pop_count<='0; tag_pop_count<='0; empty_stall_count<='0;
                underflow_count<='0; axi_protocol_error<=0;
            end
        end
    end
endmodule
