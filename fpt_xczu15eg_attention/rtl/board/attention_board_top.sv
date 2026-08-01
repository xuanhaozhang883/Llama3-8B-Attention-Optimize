`timescale 1ns/1ps

module attention_board_top #(
    parameter int RUN_GROUPS = 8,
    parameter bit ONLINE_MODE = 1'b1,
    parameter int QK_LANES = 2,
    parameter int CAPTURE_TILE = 4,
    parameter int PV_LANES = 2,
    parameter logic [31:0] Q_BASE_ADDR       = 32'h1000_0000,
    parameter logic [31:0] K_BASE_ADDR       = 32'h1010_0000,
    parameter logic [31:0] V_BASE_ADDR       = 32'h1014_0000,
    parameter logic [31:0] CONTEXT_BASE_ADDR = 32'h1018_0000
) (
    output logic error
);
    logic board_clk;
    logic [0:0] board_rst_n_vec;
    logic board_rst_n;
    logic [31:0] gpio_control;
    logic [31:0] gpio_status;

    logic start_d;
    logic command_start;
    logic soft_reset;
    logic engine_rst_n;
    logic causal_en;

    (* mark_debug = "true" *) logic engine_busy;
    (* mark_debug = "true" *) logic engine_done;
    (* mark_debug = "true" *) logic engine_error;
    (* mark_debug = "true" *) logic [31:0] cycle_count;
    (* mark_debug = "true" *) logic [2:0] active_group_id;
    (* mark_debug = "true" *) logic v_loaded;
    (* mark_debug = "true" *) logic core_done_seen;
    (* mark_debug = "true" *) logic context_done_seen;

    logic [31:0] prof_v_load_cycles;
    logic [31:0] prof_core_run_cycles;
    logic [31:0] prof_raw_wait_cycles;
    logic [31:0] prof_raw_busy_cycles;
    logic [31:0] prof_bc_busy_cycles;
    logic [31:0] prof_pv_busy_cycles;
    logic [31:0] prof_context_busy_cycles;
    logic [31:0] prof_context_backpressure_cycles;
    logic [31:0] prof_ddr_read_busy_cycles;
    logic [31:0] prof_ddr_write_busy_cycles;
    logic [31:0] prof_raw_req_count;
    logic [31:0] prof_read_beat_count;
    logic [31:0] prof_write_beat_count;
    logic [31:0] prof_context_word_count;
    logic [31:0] prof_read_command_count;
    logic [31:0] prof_write_command_count;
    logic [31:0] prof_error_detail;
    logic [255:0] prof_group_cycles_flat;
    logic [31:0] prof_rope_busy_cycles;
    logic [31:0] prof_qk_busy_cycles;
    logic [31:0] prof_mask_busy_cycles;
    logic [31:0] prof_softmax_busy_cycles;
    logic [31:0] prof_bc_backend_busy_cycles;
    logic [31:0] prof_capture_busy_cycles;
    logic [31:0] prof_context_transfer_cycles;
    logic [31:0] prof_bc_pv_overlap_cycles;
    logic [31:0] prof_core_idle_cycles;
    logic [31:0] prof_repack_stall_cycles;
    logic [31:0] prof_pv_feed_stall_cycles;
    logic [31:0] prof_softmax_stall_cycles;
    logic [31:0] prof_interstage_wait_cycles;
    logic [31:0] prof_qk_tiles_computed;
    logic [31:0] prof_qk_tiles_skipped;
    logic [31:0] prof_masked_tiles_emitted;
    logic [31:0] prof_pv_reductions_computed;
    logic [31:0] prof_pv_reductions_skipped;
    logic [31:0] prof_native_vectors_captured;
    logic [31:0] prof_causal_error_flags;
    logic [31:0] prof_online_tiles_processed;
    logic [31:0] prof_online_tiles_skipped;
    logic [31:0] prof_online_rescale_events;
    logic [31:0] prof_online_v_vectors_read;
    logic [31:0] prof_online_mac_terms;
    logic [5:0] profile_page;

    assign board_rst_n = board_rst_n_vec[0];
    assign soft_reset = gpio_control[2];
    assign causal_en = gpio_control[1];
    assign profile_page = gpio_control[8:3];
    assign engine_rst_n = board_rst_n && !soft_reset;
    assign command_start = gpio_control[0] && !start_d;
    assign error = engine_error;

    always_ff @(posedge board_clk) begin
        if (!board_rst_n)
            start_d <= 1'b0;
        else
            start_d <= gpio_control[0];
    end

    // GPIO channel 2 is a paged, read-only profiling window. Page zero keeps
    // the v2.2 status ABI. v2.4 expands the selector to gpio_control[8:3]
    // (64 pages) while preserving causal_en in bit 1.
    always_comb begin
        gpio_status = '0;
        case (profile_page)
            5'd0: begin
                gpio_status[0] = engine_busy;
                gpio_status[1] = engine_done;
                gpio_status[2] = engine_error;
                gpio_status[3] = !engine_busy;
                gpio_status[4] = v_loaded;
                gpio_status[5] = core_done_seen;
                gpio_status[6] = context_done_seen;
                gpio_status[10:8] = active_group_id;
                gpio_status[31:16] = cycle_count[15:0];
            end
            5'd1:  gpio_status = cycle_count;
            5'd2:  gpio_status = prof_v_load_cycles;
            5'd3:  gpio_status = prof_core_run_cycles;
            5'd4:  gpio_status = prof_raw_wait_cycles;
            5'd5:  gpio_status = prof_raw_busy_cycles;
            5'd6:  gpio_status = prof_bc_busy_cycles;
            5'd7:  gpio_status = prof_pv_busy_cycles;
            5'd8:  gpio_status = prof_context_busy_cycles;
            5'd9:  gpio_status = prof_context_backpressure_cycles;
            5'd10: gpio_status = prof_ddr_read_busy_cycles;
            5'd11: gpio_status = prof_ddr_write_busy_cycles;
            5'd12: gpio_status = prof_raw_req_count;
            5'd13: gpio_status = prof_read_beat_count;
            5'd14: gpio_status = prof_write_beat_count;
            5'd15: gpio_status = prof_context_word_count;
            5'd16: gpio_status = prof_group_cycles_flat[31:0];
            5'd17: gpio_status = prof_group_cycles_flat[63:32];
            5'd18: gpio_status = prof_group_cycles_flat[95:64];
            5'd19: gpio_status = prof_group_cycles_flat[127:96];
            5'd20: gpio_status = prof_group_cycles_flat[159:128];
            5'd21: gpio_status = prof_group_cycles_flat[191:160];
            5'd22: gpio_status = prof_group_cycles_flat[223:192];
            5'd23: gpio_status = prof_group_cycles_flat[255:224];
            5'd24: gpio_status = prof_read_command_count;
            5'd25: gpio_status = prof_write_command_count;
            5'd26: gpio_status = prof_error_detail;
            6'd27: gpio_status = prof_rope_busy_cycles;
            6'd28: gpio_status = prof_qk_busy_cycles;
            6'd29: gpio_status = prof_mask_busy_cycles;
            6'd30: gpio_status = prof_softmax_busy_cycles;
            6'd31: gpio_status = prof_bc_backend_busy_cycles;
            6'd32: gpio_status = prof_capture_busy_cycles;
            6'd33: gpio_status = prof_context_transfer_cycles;
            6'd34: gpio_status = prof_bc_pv_overlap_cycles;
            6'd35: gpio_status = prof_core_idle_cycles;
            6'd36: gpio_status = prof_repack_stall_cycles;
            6'd37: gpio_status = prof_pv_feed_stall_cycles;
            6'd38: gpio_status = prof_softmax_stall_cycles;
            6'd39: gpio_status = prof_interstage_wait_cycles;
            6'd40: gpio_status = prof_qk_tiles_computed;
            6'd41: gpio_status = prof_qk_tiles_skipped;
            6'd42: gpio_status = prof_masked_tiles_emitted;
            6'd43: gpio_status = prof_pv_reductions_computed;
            6'd44: gpio_status = prof_pv_reductions_skipped;
            6'd45: gpio_status = prof_native_vectors_captured;
            6'd46: gpio_status = prof_causal_error_flags;
            6'd47: gpio_status = prof_online_tiles_processed;
            6'd48: gpio_status = prof_online_tiles_skipped;
            6'd49: gpio_status = prof_online_rescale_events;
            6'd50: gpio_status = prof_online_v_vectors_read;
            6'd51: gpio_status = prof_online_mac_terms;
            default: gpio_status = 32'hF24F_0000 | {26'd0, profile_page};
        endcase
    end

    // AXI HP0 signals: custom master is 32-bit address/1-bit ID; the PS port
    // is wider, so upper bits are tied low exactly as in the verified example.
    logic [0:0]  m_awid;
    logic [31:0] m_awaddr;
    logic [7:0]  m_awlen;
    logic [2:0]  m_awsize;
    logic [1:0]  m_awburst;
    logic        m_awlock;
    logic [3:0]  m_awcache;
    logic [2:0]  m_awprot;
    logic [3:0]  m_awqos;
    logic [0:0]  m_awuser;
    logic        m_awvalid, m_awready;

    logic [63:0] m_wdata;
    logic [7:0]  m_wstrb;
    logic        m_wlast;
    logic [0:0]  m_wuser;
    logic        m_wvalid, m_wready;

    logic [5:0]  hp_bid;
    logic [1:0]  hp_bresp;
    logic        hp_bvalid, m_bready;

    logic [0:0]  m_arid;
    logic [31:0] m_araddr;
    logic [7:0]  m_arlen;
    logic [2:0]  m_arsize;
    logic [1:0]  m_arburst;
    logic [1:0]  m_arlock;
    logic [3:0]  m_arcache;
    logic [2:0]  m_arprot;
    logic [3:0]  m_arqos;
    logic [0:0]  m_aruser;
    logic        m_arvalid, m_arready;

    logic [5:0]  hp_rid;
    logic [63:0] hp_rdata;
    logic [1:0]  hp_rresp;
    logic        hp_rlast, hp_rvalid, m_rready;

    logic rd_start, rd_ready, rd_data_we, rd_fifo_full, rd_done, rd_error;
    logic [31:0] rd_addr, rd_len;
    logic [63:0] rd_data;

    logic wr_start, wr_ready, wr_fifo_re, wr_fifo_empty;
    logic wr_fifo_aempty, wr_done, wr_error;
    logic [31:0] wr_addr, wr_len;
    logic [63:0] wr_fifo_data;
    logic [31:0] axi_debug;

    (* mark_debug = "true" *) logic dbg_rd_start, dbg_rd_done;
    (* mark_debug = "true" *) logic dbg_wr_start, dbg_wr_done;
    assign dbg_rd_start = rd_start;
    assign dbg_rd_done  = rd_done;
    assign dbg_wr_start = wr_start;
    assign dbg_wr_done  = wr_done;

    fpt_attention_board_engine #(
        .RUN_GROUPS(RUN_GROUPS),
        .ONLINE_MODE(ONLINE_MODE),
        .QK_LANES(QK_LANES),
        .CAPTURE_TILE(CAPTURE_TILE),
        .PV_LANES(PV_LANES),
        .Q_BASE_ADDR(Q_BASE_ADDR), .K_BASE_ADDR(K_BASE_ADDR),
        .V_BASE_ADDR(V_BASE_ADDR), .CONTEXT_BASE_ADDR(CONTEXT_BASE_ADDR),
        .EXP_LUT_FILE("exp_lut_q15.mem"),
        .SIN_ROM_FILE("sin_bf16.hex"), .COS_ROM_FILE("cos_bf16.hex")
    ) u_engine (
        .clk(board_clk), .rst_n(engine_rst_n),
        .command_start, .causal_en,
        .busy(engine_busy), .done_latched(engine_done),
        .error_latched(engine_error), .cycle_count,
        .active_group_id, .v_loaded, .core_done_seen, .context_done_seen,
        .prof_v_load_cycles, .prof_core_run_cycles,
        .prof_raw_wait_cycles, .prof_raw_busy_cycles,
        .prof_bc_busy_cycles, .prof_pv_busy_cycles,
        .prof_context_busy_cycles, .prof_context_backpressure_cycles,
        .prof_ddr_read_busy_cycles, .prof_ddr_write_busy_cycles,
        .prof_raw_req_count, .prof_read_beat_count, .prof_write_beat_count,
        .prof_context_word_count, .prof_read_command_count,
        .prof_write_command_count, .prof_error_detail,
        .prof_group_cycles_flat,
        .prof_rope_busy_cycles, .prof_qk_busy_cycles,
        .prof_mask_busy_cycles, .prof_softmax_busy_cycles,
        .prof_bc_backend_busy_cycles, .prof_capture_busy_cycles,
        .prof_context_transfer_cycles, .prof_bc_pv_overlap_cycles,
        .prof_core_idle_cycles, .prof_repack_stall_cycles,
        .prof_pv_feed_stall_cycles, .prof_softmax_stall_cycles,
        .prof_interstage_wait_cycles,
        .prof_qk_tiles_computed, .prof_qk_tiles_skipped,
        .prof_masked_tiles_emitted,
        .prof_pv_reductions_computed, .prof_pv_reductions_skipped,
        .prof_native_vectors_captured, .prof_causal_error_flags,
        .prof_online_tiles_processed, .prof_online_tiles_skipped,
        .prof_online_rescale_events, .prof_online_v_vectors_read,
        .prof_online_mac_terms,
        .rd_start, .rd_ready, .rd_addr, .rd_len,
        .rd_data_we, .rd_data, .rd_fifo_full, .rd_done, .rd_error,
        .wr_start, .wr_ready, .wr_addr, .wr_len,
        .wr_fifo_re, .wr_fifo_empty, .wr_fifo_aempty, .wr_fifo_data,
        .wr_done, .wr_error
    );

    aq_axi_master_fixed u_ddr_master (
        .ARESETN(board_rst_n), .ACLK(board_clk),
        .M_AXI_AWID(m_awid), .M_AXI_AWADDR(m_awaddr),
        .M_AXI_AWLEN(m_awlen), .M_AXI_AWSIZE(m_awsize),
        .M_AXI_AWBURST(m_awburst), .M_AXI_AWLOCK(m_awlock),
        .M_AXI_AWCACHE(m_awcache), .M_AXI_AWPROT(m_awprot),
        .M_AXI_AWQOS(m_awqos), .M_AXI_AWUSER(m_awuser),
        .M_AXI_AWVALID(m_awvalid), .M_AXI_AWREADY(m_awready),
        .M_AXI_WDATA(m_wdata), .M_AXI_WSTRB(m_wstrb),
        .M_AXI_WLAST(m_wlast), .M_AXI_WUSER(m_wuser),
        .M_AXI_WVALID(m_wvalid), .M_AXI_WREADY(m_wready),
        .M_AXI_BID(hp_bid[0]), .M_AXI_BRESP(hp_bresp), .M_AXI_BUSER(1'b0),
        .M_AXI_BVALID(hp_bvalid), .M_AXI_BREADY(m_bready),
        .M_AXI_ARID(m_arid), .M_AXI_ARADDR(m_araddr),
        .M_AXI_ARLEN(m_arlen), .M_AXI_ARSIZE(m_arsize),
        .M_AXI_ARBURST(m_arburst), .M_AXI_ARLOCK(m_arlock),
        .M_AXI_ARCACHE(m_arcache), .M_AXI_ARPROT(m_arprot),
        .M_AXI_ARQOS(m_arqos), .M_AXI_ARUSER(m_aruser),
        .M_AXI_ARVALID(m_arvalid), .M_AXI_ARREADY(m_arready),
        .M_AXI_RID(hp_rid[0]), .M_AXI_RDATA(hp_rdata),
        .M_AXI_RRESP(hp_rresp), .M_AXI_RLAST(hp_rlast),
        .M_AXI_RUSER(1'b0), .M_AXI_RVALID(hp_rvalid),
        .M_AXI_RREADY(m_rready),
        .MASTER_RST(soft_reset),
        .WR_START(wr_start), .WR_ADRS(wr_addr), .WR_LEN(wr_len),
        .WR_READY(wr_ready), .WR_FIFO_RE(wr_fifo_re),
        .WR_FIFO_EMPTY(wr_fifo_empty), .WR_FIFO_AEMPTY(wr_fifo_aempty),
        .WR_FIFO_DATA(wr_fifo_data), .WR_DONE(wr_done), .WR_ERROR(wr_error),
        .RD_START(rd_start), .RD_ADRS(rd_addr), .RD_LEN(rd_len),
        .RD_READY(rd_ready), .RD_FIFO_WE(rd_data_we),
        .RD_FIFO_FULL(rd_fifo_full), .RD_FIFO_AFULL(rd_fifo_full),
        .RD_FIFO_DATA(rd_data), .RD_DONE(rd_done), .RD_ERROR(rd_error),
        .DEBUG(axi_debug)
    );

    design_1_wrapper u_ps (
        .S_AXI_HP0_araddr({17'd0, m_araddr}),
        .S_AXI_HP0_arburst(m_arburst), .S_AXI_HP0_arcache(m_arcache),
        .S_AXI_HP0_arid({5'd0, m_arid}), .S_AXI_HP0_arlen(m_arlen),
        .S_AXI_HP0_arlock(m_arlock[0]), .S_AXI_HP0_arprot(m_arprot),
        .S_AXI_HP0_arqos(m_arqos), .S_AXI_HP0_arready(m_arready),
        .S_AXI_HP0_arsize(m_arsize), .S_AXI_HP0_aruser(m_aruser),
        .S_AXI_HP0_arvalid(m_arvalid),
        .S_AXI_HP0_awaddr({17'd0, m_awaddr}),
        .S_AXI_HP0_awburst(m_awburst), .S_AXI_HP0_awcache(m_awcache),
        .S_AXI_HP0_awid({5'd0, m_awid}), .S_AXI_HP0_awlen(m_awlen),
        .S_AXI_HP0_awlock(m_awlock), .S_AXI_HP0_awprot(m_awprot),
        .S_AXI_HP0_awqos(m_awqos), .S_AXI_HP0_awready(m_awready),
        .S_AXI_HP0_awsize(m_awsize), .S_AXI_HP0_awuser(m_awuser),
        .S_AXI_HP0_awvalid(m_awvalid),
        .S_AXI_HP0_bid(hp_bid), .S_AXI_HP0_bready(m_bready),
        .S_AXI_HP0_bresp(hp_bresp), .S_AXI_HP0_bvalid(hp_bvalid),
        .S_AXI_HP0_rdata(hp_rdata), .S_AXI_HP0_rid(hp_rid),
        .S_AXI_HP0_rlast(hp_rlast), .S_AXI_HP0_rready(m_rready),
        .S_AXI_HP0_rresp(hp_rresp), .S_AXI_HP0_rvalid(hp_rvalid),
        .S_AXI_HP0_wdata(m_wdata), .S_AXI_HP0_wlast(m_wlast),
        .S_AXI_HP0_wready(m_wready), .S_AXI_HP0_wstrb(m_wstrb),
        .S_AXI_HP0_wvalid(m_wvalid),
        .axi_hp_clk(board_clk), .axi_rst_n(board_rst_n_vec),
        .pl_clk0(board_clk),
        .gpio_control(gpio_control), .gpio_status(gpio_status)
    );

    wire unused_axi = &{1'b0, axi_debug, hp_bid[5:1], hp_rid[5:1], m_wuser};
endmodule
