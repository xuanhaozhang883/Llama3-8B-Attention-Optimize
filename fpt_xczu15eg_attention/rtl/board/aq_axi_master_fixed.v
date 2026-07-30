/*
 * Based on the AQUAXIS/ALINX aq_axi_master used by the verified vendor
 * PL<->PS DDR reference design.  The local FIFO handshakes were corrected
 * for a conventional ready/valid-style source and sink:
 *   - WR_FIFO_RE pulses only when one W beat is accepted.
 *   - RD_FIFO_WE pulses only when one R beat is accepted.
 *   - read backpressure uses RD_FIFO_FULL safely.
 * Additional sticky AXI response error outputs are provided.
 */
module aq_axi_master_fixed(
  input           ARESETN,
  input           ACLK,

  output [0:0]  M_AXI_AWID,
  output [31:0] M_AXI_AWADDR,
  output [7:0]  M_AXI_AWLEN,
  output [2:0]  M_AXI_AWSIZE,
  output [1:0]  M_AXI_AWBURST,
  output        M_AXI_AWLOCK,
  output [3:0]  M_AXI_AWCACHE,
  output [2:0]  M_AXI_AWPROT,
  output [3:0]  M_AXI_AWQOS,
  output [0:0]  M_AXI_AWUSER,
  output        M_AXI_AWVALID,
  input         M_AXI_AWREADY,

  output [63:0] M_AXI_WDATA,
  output [7:0]  M_AXI_WSTRB,
  output        M_AXI_WLAST,
  output [0:0]  M_AXI_WUSER,
  output        M_AXI_WVALID,
  input         M_AXI_WREADY,

  input [0:0]   M_AXI_BID,
  input [1:0]   M_AXI_BRESP,
  input [0:0]   M_AXI_BUSER,
  input         M_AXI_BVALID,
  output        M_AXI_BREADY,

  output [0:0]  M_AXI_ARID,
  output [31:0] M_AXI_ARADDR,
  output [7:0]  M_AXI_ARLEN,
  output [2:0]  M_AXI_ARSIZE,
  output [1:0]  M_AXI_ARBURST,
  output [1:0]  M_AXI_ARLOCK,
  output [3:0]  M_AXI_ARCACHE,
  output [2:0]  M_AXI_ARPROT,
  output [3:0]  M_AXI_ARQOS,
  output [0:0]  M_AXI_ARUSER,
  output        M_AXI_ARVALID,
  input         M_AXI_ARREADY,

  input [0:0]   M_AXI_RID,
  input [63:0]  M_AXI_RDATA,
  input [1:0]   M_AXI_RRESP,
  input         M_AXI_RLAST,
  input [0:0]   M_AXI_RUSER,
  input         M_AXI_RVALID,
  output        M_AXI_RREADY,

  input         MASTER_RST,

  input         WR_START,
  input [31:0]  WR_ADRS,
  input [31:0]  WR_LEN,
  output        WR_READY,
  output        WR_FIFO_RE,
  input         WR_FIFO_EMPTY,
  input         WR_FIFO_AEMPTY,
  input [63:0]  WR_FIFO_DATA,
  output        WR_DONE,
  output reg    WR_ERROR,

  input         RD_START,
  input [31:0]  RD_ADRS,
  input [31:0]  RD_LEN,
  output        RD_READY,
  output        RD_FIFO_WE,
  input         RD_FIFO_FULL,
  input         RD_FIFO_AFULL,
  output [63:0] RD_FIFO_DATA,
  output        RD_DONE,
  output reg    RD_ERROR,

  output [31:0] DEBUG
);

  localparam S_WR_IDLE  = 3'd0;
  localparam S_WA_WAIT  = 3'd1;
  localparam S_WA_START = 3'd2;
  localparam S_WD_WAIT  = 3'd3;
  localparam S_WD_PROC  = 3'd4;
  localparam S_WR_WAIT  = 3'd5;
  localparam S_WR_DONE  = 3'd6;

  reg [2:0]  wr_state;
  reg [31:0] reg_wr_adrs;
  reg [31:0] reg_wr_len;
  reg        reg_awvalid;
  reg        reg_wvalid;
  reg        reg_w_last;
  reg [7:0]  reg_w_len;

  assign WR_DONE    = (wr_state == S_WR_DONE);
  assign WR_READY   = (wr_state == S_WR_IDLE);
  assign WR_FIFO_RE = reg_wvalid && !WR_FIFO_EMPTY && M_AXI_WREADY;

  always @(posedge ACLK or negedge ARESETN) begin
    if (!ARESETN) begin
      wr_state      <= S_WR_IDLE;
      reg_wr_adrs   <= 32'd0;
      reg_wr_len    <= 32'd0;
      reg_awvalid   <= 1'b0;
      reg_wvalid    <= 1'b0;
      reg_w_last    <= 1'b0;
      reg_w_len     <= 8'd0;
      WR_ERROR      <= 1'b0;
    end else if (MASTER_RST) begin
      wr_state      <= S_WR_IDLE;
      reg_awvalid   <= 1'b0;
      reg_wvalid    <= 1'b0;
      WR_ERROR      <= 1'b0;
    end else begin
      case (wr_state)
        S_WR_IDLE: begin
          reg_awvalid <= 1'b0;
          reg_wvalid  <= 1'b0;
          if (WR_START) begin
            if (WR_LEN == 0 || WR_LEN[2:0] != 0) begin
              WR_ERROR <= 1'b1;
            end else begin
              reg_wr_adrs <= WR_ADRS;
              reg_wr_len  <= WR_LEN - 1'b1;
              wr_state    <= S_WA_WAIT;
            end
          end
        end

        S_WA_WAIT: begin
          if (!WR_FIFO_AEMPTY || (reg_wr_len[31:11] == 0))
            wr_state <= S_WA_START;
        end

        S_WA_START: begin
          reg_awvalid <= 1'b1;
          wr_state    <= S_WD_WAIT;
          if (reg_wr_len[31:11] != 0) begin
            reg_wr_len[31:11] <= reg_wr_len[31:11] - 1'b1;
            reg_w_len         <= 8'hFF;
            reg_w_last        <= 1'b0;
          end else begin
            reg_w_len  <= reg_wr_len[10:3];
            reg_w_last <= 1'b1;
          end
        end

        S_WD_WAIT: begin
          if (M_AXI_AWREADY) begin
            reg_awvalid <= 1'b0;
            reg_wvalid  <= 1'b1;
            wr_state    <= S_WD_PROC;
          end
        end

        S_WD_PROC: begin
          if (WR_FIFO_RE) begin
            if (reg_w_len == 0) begin
              reg_wvalid <= 1'b0;
              wr_state   <= S_WR_WAIT;
            end else begin
              reg_w_len <= reg_w_len - 1'b1;
            end
          end
        end

        S_WR_WAIT: begin
          if (M_AXI_BVALID) begin
            if (M_AXI_BRESP != 2'b00)
              WR_ERROR <= 1'b1;
            if (reg_w_last) begin
              wr_state <= S_WR_DONE;
            end else begin
              reg_wr_adrs <= reg_wr_adrs + 32'd2048;
              wr_state    <= S_WA_WAIT;
            end
          end
        end

        S_WR_DONE: wr_state <= S_WR_IDLE;
        default:   wr_state <= S_WR_IDLE;
      endcase
    end
  end

  assign M_AXI_AWID    = 1'b0;
  assign M_AXI_AWADDR  = reg_wr_adrs;
  assign M_AXI_AWLEN   = reg_w_len;
  assign M_AXI_AWSIZE  = 3'b011;
  assign M_AXI_AWBURST = 2'b01;
  assign M_AXI_AWLOCK  = 1'b0;
  assign M_AXI_AWCACHE = 4'b0011;
  assign M_AXI_AWPROT  = 3'b000;
  assign M_AXI_AWQOS   = 4'b0000;
  assign M_AXI_AWUSER  = 1'b1;
  assign M_AXI_AWVALID = reg_awvalid;

  assign M_AXI_WDATA  = WR_FIFO_DATA;
  assign M_AXI_WSTRB  = (reg_wvalid && !WR_FIFO_EMPTY) ? 8'hFF : 8'h00;
  assign M_AXI_WLAST  = (reg_w_len == 0);
  assign M_AXI_WUSER  = 1'b1;
  assign M_AXI_WVALID = reg_wvalid && !WR_FIFO_EMPTY;
  assign M_AXI_BREADY = 1'b1;

  localparam S_RD_IDLE  = 3'd0;
  localparam S_RA_WAIT  = 3'd1;
  localparam S_RA_START = 3'd2;
  localparam S_RD_WAIT  = 3'd3;
  localparam S_RD_PROC  = 3'd4;
  localparam S_RD_DONE  = 3'd5;

  reg [2:0]  rd_state;
  reg [31:0] reg_rd_adrs;
  reg [31:0] reg_rd_len;
  reg        reg_arvalid;
  reg        reg_r_last;
  reg [7:0]  reg_r_len;

  assign RD_DONE = (rd_state == S_RD_DONE);
  assign RD_READY = (rd_state == S_RD_IDLE);

  always @(posedge ACLK or negedge ARESETN) begin
    if (!ARESETN) begin
      rd_state    <= S_RD_IDLE;
      reg_rd_adrs <= 32'd0;
      reg_rd_len  <= 32'd0;
      reg_arvalid <= 1'b0;
      reg_r_last  <= 1'b0;
      reg_r_len   <= 8'd0;
      RD_ERROR    <= 1'b0;
    end else if (MASTER_RST) begin
      rd_state    <= S_RD_IDLE;
      reg_arvalid <= 1'b0;
      RD_ERROR    <= 1'b0;
    end else begin
      if (M_AXI_RVALID && M_AXI_RREADY && M_AXI_RRESP != 2'b00)
        RD_ERROR <= 1'b1;

      case (rd_state)
        S_RD_IDLE: begin
          reg_arvalid <= 1'b0;
          if (RD_START) begin
            if (RD_LEN == 0 || RD_LEN[2:0] != 0) begin
              RD_ERROR <= 1'b1;
            end else begin
              reg_rd_adrs <= RD_ADRS;
              reg_rd_len  <= RD_LEN - 1'b1;
              rd_state    <= S_RA_WAIT;
            end
          end
        end

        S_RA_WAIT: begin
          if (!RD_FIFO_AFULL)
            rd_state <= S_RA_START;
        end

        S_RA_START: begin
          reg_arvalid <= 1'b1;
          rd_state    <= S_RD_WAIT;
          if (reg_rd_len[31:11] != 0) begin
            reg_rd_len[31:11] <= reg_rd_len[31:11] - 1'b1;
            reg_r_len         <= 8'hFF;
            reg_r_last        <= 1'b0;
          end else begin
            reg_r_len  <= reg_rd_len[10:3];
            reg_r_last <= 1'b1;
          end
        end

        S_RD_WAIT: begin
          if (M_AXI_ARREADY) begin
            reg_arvalid <= 1'b0;
            rd_state    <= S_RD_PROC;
          end
        end

        S_RD_PROC: begin
          if (M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST) begin
            if (reg_r_last) begin
              rd_state <= S_RD_DONE;
            end else begin
              reg_rd_adrs <= reg_rd_adrs + 32'd2048;
              rd_state    <= S_RA_WAIT;
            end
          end
        end

        S_RD_DONE: rd_state <= S_RD_IDLE;
        default:   rd_state <= S_RD_IDLE;
      endcase
    end
  end

  assign M_AXI_ARID    = 1'b0;
  assign M_AXI_ARADDR  = reg_rd_adrs;
  assign M_AXI_ARLEN   = reg_r_len;
  assign M_AXI_ARSIZE  = 3'b011;
  assign M_AXI_ARBURST = 2'b01;
  assign M_AXI_ARLOCK  = 2'b00;
  assign M_AXI_ARCACHE = 4'b0011;
  assign M_AXI_ARPROT  = 3'b000;
  assign M_AXI_ARQOS   = 4'b0000;
  assign M_AXI_ARUSER  = 1'b1;
  assign M_AXI_ARVALID = reg_arvalid;

  assign M_AXI_RREADY   = !RD_FIFO_FULL;
  assign RD_FIFO_WE      = M_AXI_RVALID && M_AXI_RREADY;
  assign RD_FIFO_DATA    = M_AXI_RDATA;

  assign DEBUG = {24'd0, wr_state, 1'b0, rd_state};

  wire unused_inputs = &{1'b0, M_AXI_BID, M_AXI_BUSER, M_AXI_RID,
                         M_AXI_RUSER, RD_FIFO_AFULL};
endmodule
