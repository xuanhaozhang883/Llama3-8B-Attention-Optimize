`timescale 1ns/1ps

// Production single-GQA data engine.
// The DMA ingress frame is captured by axis_qkv_memory_bridge, V is loaded
// into the existing production cache, and the unchanged
// RoPE->QK->Scale/Mask->Softmax->PV core is executed. Context BF16 values are
// packed back to an AXI4-Stream frame.
module attention_axis_single_gqa_engine #(
    parameter int AXIS_DATA_W = 128,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int Q_HEADS = 4
) (
    input  logic                       aclk,
    input  logic                       aresetn,

    input  logic                       command_start,
    output logic                       command_ready,
    output logic                       busy,
    output logic                       done_pulse,
    output logic                       frame_loaded,
    output logic                       protocol_error,

    input  logic [AXIS_DATA_W-1:0]     s_axis_tdata,
    input  logic [AXIS_DATA_W/8-1:0]   s_axis_tkeep,
    input  logic                       s_axis_tlast,
    input  logic                       s_axis_tvalid,
    output logic                       s_axis_tready,

    output logic [AXIS_DATA_W-1:0]     m_axis_tdata,
    output logic [AXIS_DATA_W/8-1:0]   m_axis_tkeep,
    output logic                       m_axis_tlast,
    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,

    output logic [63:0]                kernel_cycles,
    output logic [63:0]                fifo_stall_cycles,
    output logic [31:0]                input_beats,
    output logic [31:0]                output_beats,
    output logic [7:0]                 error_vector
);
    localparam int GLOBAL_Q_HEAD_W =
        ((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS));
    localparam int POS_W = ((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN));
    localparam int DIM_W = ((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM));
    localparam int PAIR_W =
        (((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2));
    localparam int V_ADDR_W =
        (((SEQ_LEN*HEAD_DIM) <= 1) ? 1 : $clog2(SEQ_LEN*HEAD_DIM));

    typedef enum logic [2:0] {
        ST_LOAD, ST_PRELOAD, ST_WAIT_CORE, ST_RUN, ST_FINISH
    } state_t;
    state_t state;

    logic frame_clear;
    logic preload_start;
    logic preload_busy;
    logic preload_done;

    logic raw_req_valid;
    logic raw_req_ready;
    logic raw_req_is_k;
    logic [GLOBAL_Q_HEAD_W-1:0] raw_req_head;
    logic [POS_W-1:0] raw_req_token;
    logic [PAIR_W-1:0] raw_req_pair;
    logic raw_rsp_valid;
    logic raw_rsp_ready;
    logic [15:0] raw_rsp_x0;
    logic [15:0] raw_rsp_x1;

    logic v_load_valid;
    logic v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr;
    logic [31:0] v_load_data;

    logic core_start;
    logic core_start_ready;
    logic core_busy;
    logic core_done;
    logic core_context_valid;
    logic core_context_ready;
    logic [15:0] core_context_bf16;
    logic core_context_last;

    logic core_start_while_busy_error;
    logic core_controller_error;
    logic core_bc_protocol_error;
    logic core_v_cache_error;
    logic core_repack_error;
    logic core_protocol_error;
    logic ingress_protocol_error;
    logic command_protocol_error;
    logic output_frame_done;
    logic core_done_seen;
    logic output_done_seen;

    assign command_ready = (state == ST_LOAD) && frame_loaded &&
                           !ingress_protocol_error;
    assign busy = (state != ST_LOAD);
    assign protocol_error = |error_vector;
    assign error_vector = {
        command_protocol_error,
        ingress_protocol_error,
        core_protocol_error,
        core_repack_error,
        core_v_cache_error,
        core_bc_protocol_error,
        core_controller_error,
        core_start_while_busy_error
    };

    axis_qkv_memory_bridge #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS)
    ) u_qkv_bridge (
        .aclk(aclk),
        .aresetn(aresetn),
        .frame_clear(frame_clear),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .frame_loaded(frame_loaded),
        .ingress_protocol_error(ingress_protocol_error),
        .input_beats(input_beats),
        .raw_req_valid(raw_req_valid),
        .raw_req_ready(raw_req_ready),
        .raw_req_is_k(raw_req_is_k),
        .raw_req_head(raw_req_head),
        .raw_req_token(raw_req_token),
        .raw_req_pair(raw_req_pair),
        .raw_rsp_valid(raw_rsp_valid),
        .raw_rsp_ready(raw_rsp_ready),
        .raw_rsp_x0(raw_rsp_x0),
        .raw_rsp_x1(raw_rsp_x1),
        .preload_start(preload_start),
        .preload_busy(preload_busy),
        .preload_done_pulse(preload_done),
        .v_load_valid(v_load_valid),
        .v_load_ready(v_load_ready),
        .v_load_addr(v_load_addr),
        .v_load_data(v_load_data)
    );

    axis_bf16_packer #(
        .AXIS_DATA_W(AXIS_DATA_W)
    ) u_context_packer (
        .aclk(aclk),
        .aresetn(aresetn),
        .frame_clear(frame_clear),
        .s_bf16_data(core_context_bf16),
        .s_bf16_last(core_context_last),
        .s_bf16_valid(core_context_valid),
        .s_bf16_ready(core_context_ready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .output_beats(output_beats),
        .frame_done_pulse(output_frame_done)
    );

    attention_system_with_rope_pv_top #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(1),
        .RUN_GQA_GROUPS(1),
        .ALLOW_REDUCED_GQA(1'b1)
    ) u_attention (
        .clk(aclk),
        .rst_n(aresetn && !frame_clear),
        .start(core_start),
        .start_ready(core_start_ready),
        .busy(core_busy),
        .done(core_done),
        .causal_en(1'b1),
        .raw_req_valid(raw_req_valid),
        .raw_req_ready(raw_req_ready),
        .raw_req_is_k(raw_req_is_k),
        .raw_req_head(raw_req_head),
        .raw_req_token(raw_req_token),
        .raw_req_pair(raw_req_pair),
        .raw_rsp_valid(raw_rsp_valid),
        .raw_rsp_ready(raw_rsp_ready),
        .raw_rsp_x0(raw_rsp_x0),
        .raw_rsp_x1(raw_rsp_x1),
        .v_load_valid(v_load_valid),
        .v_load_ready(v_load_ready),
        .v_load_addr(v_load_addr),
        .v_load_data(v_load_data),
        .context_valid(core_context_valid),
        .context_ready(core_context_ready),
        .context_bf16(core_context_bf16),
        .context_global_last(core_context_last),
        .start_while_busy_error(core_start_while_busy_error),
        .controller_error(core_controller_error),
        .bc_protocol_error(core_bc_protocol_error),
        .v_cache_error(core_v_cache_error),
        .repack_error(core_repack_error),
        .protocol_error(core_protocol_error)
    );

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state <= ST_LOAD;
            frame_clear <= 1'b0;
            preload_start <= 1'b0;
            core_start <= 1'b0;
            done_pulse <= 1'b0;
            command_protocol_error <= 1'b0;
            core_done_seen <= 1'b0;
            output_done_seen <= 1'b0;
            kernel_cycles <= '0;
            fifo_stall_cycles <= '0;
        end else begin
            frame_clear <= 1'b0;
            preload_start <= 1'b0;
            core_start <= 1'b0;
            done_pulse <= 1'b0;

            if (command_start && !command_ready)
                command_protocol_error <= 1'b1;

            if ((state == ST_RUN) && core_context_valid &&
                !core_context_ready)
                fifo_stall_cycles <= fifo_stall_cycles + 1'b1;

            case (state)
                ST_LOAD: if (command_start && command_ready) begin
                    preload_start <= 1'b1;
                    core_done_seen <= 1'b0;
                    output_done_seen <= 1'b0;
                    kernel_cycles <= '0;
                    fifo_stall_cycles <= '0;
                    state <= ST_PRELOAD;
                end
                ST_PRELOAD: if (preload_done)
                    state <= ST_WAIT_CORE;
                ST_WAIT_CORE: if (core_start_ready) begin
                    core_start <= 1'b1;
                    state <= ST_RUN;
                end
                ST_RUN: begin
                    kernel_cycles <= kernel_cycles + 1'b1;
                    if (core_done)
                        core_done_seen <= 1'b1;
                    if (output_frame_done)
                        output_done_seen <= 1'b1;
                    if ((core_done_seen || core_done) &&
                        (output_done_seen || output_frame_done))
                        state <= ST_FINISH;
                end
                ST_FINISH: begin
                    done_pulse <= 1'b1;
                    frame_clear <= 1'b1;
                    state <= ST_LOAD;
                end
                default: state <= ST_LOAD;
            endcase
        end
    end
endmodule
