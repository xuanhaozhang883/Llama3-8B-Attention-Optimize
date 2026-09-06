// CATS-R4 C2: dual-clock mixed-width AXI beat to physical Q/K/V banks.
//
// The AXI side accepts one 64-bit beat per cycle.  A beat contains four BF16
// words and is expanded in parallel into the selected physical banks; no
// four-cycle serializer is used.  The core side has one registered read port
// per physical bank (one-cycle read latency).  The memories are deliberately
// kept as independent bank arrays so Vivado can infer independent SDP RAMs or
// map them to xpm_memory_sdpram with 64-bit write/16-bit read widths.
//
// Address contract: axi_wr_word_addr is a BF16-word address relative to the
// selected ping/pong buffer and must be 4-word aligned.  Consecutive words in
// a beat are mapped round-robin to banks (Q/V feature banks and K key banks).
// The low address bits therefore select a bank and the remaining bits select
// a row in that bank.  Buffer selection is carried separately and contributes
// the high row bit in each bank.

module cats_r4_axi64_qkv_banked_mem #(
  parameter int Q_BANKS = 4,
  parameter int K_BANKS = 32,
  parameter int V_BANKS = 4,
  parameter int Q_WORDS_PER_BUF = 65536,
  parameter int K_WORDS_PER_BUF = 16384,
  parameter int V_WORDS_PER_BUF = 16384
) (
  // AXI/DMA clock domain.  A transfer is accepted when valid && ready.
  input  logic        axi_clk,
  input  logic        axi_rst_n,
  input  logic        axi_wr_valid,
  output logic        axi_wr_ready,
  input  logic [1:0]  axi_wr_kind,       // 0=Q, 1=K, 2=V, 3=reserved
  input  logic        axi_wr_buf,
  input  logic [31:0] axi_wr_word_addr,  // BF16-word address, 4-word aligned
  input  logic [63:0] axi_wr_data,
  output logic        axi_wr_fire,
  output logic        axi_wr_error,
  output logic [63:0] axi_wr_count,
  output logic [63:0] axi_error_count,

  // Core clock domain.  Each bank has a registered, one-cycle read port.
  input  logic        core_clk,
  input  logic        core_rst_n,
  input  logic [Q_BANKS-1:0] q_rd_en,
  input  logic [Q_BANKS*$clog2((Q_WORDS_PER_BUF/Q_BANKS)*2)-1:0] q_rd_addr,
  output logic [Q_BANKS*16-1:0] q_rd_data,
  output logic [Q_BANKS-1:0] q_rd_valid,
  input  logic [K_BANKS-1:0] k_rd_en,
  input  logic [K_BANKS*$clog2((K_WORDS_PER_BUF/K_BANKS)*2)-1:0] k_rd_addr,
  output logic [K_BANKS*16-1:0] k_rd_data,
  output logic [K_BANKS-1:0] k_rd_valid,
  input  logic [V_BANKS-1:0] v_rd_en,
  input  logic [V_BANKS*$clog2((V_WORDS_PER_BUF/V_BANKS)*2)-1:0] v_rd_addr,
  output logic [V_BANKS*16-1:0] v_rd_data,
  output logic [V_BANKS-1:0] v_rd_valid
);

  localparam int Q_BANK_BITS = $clog2(Q_BANKS);
  localparam int K_BANK_BITS = $clog2(K_BANKS);
  localparam int V_BANK_BITS = $clog2(V_BANKS);
  localparam int Q_ROWS = Q_WORDS_PER_BUF / Q_BANKS;
  localparam int K_ROWS = K_WORDS_PER_BUF / K_BANKS;
  localparam int V_ROWS = V_WORDS_PER_BUF / V_BANKS;
  localparam int Q_ROW_BITS = $clog2(Q_ROWS * 2);
  localparam int K_ROW_BITS = $clog2(K_ROWS * 2);
  localparam int V_ROW_BITS = $clog2(V_ROWS * 2);

  // Xilinx infers block RAM for these arrays with the attribute below.  The
  // independent clocks intentionally model a true dual-clock SDP RAM.
  (* ram_style = "block" *) logic [15:0] q_mem [0:Q_BANKS-1][0:Q_ROWS*2-1];
  (* ram_style = "block" *) logic [15:0] k_mem [0:K_BANKS-1][0:K_ROWS*2-1];
  (* ram_style = "block" *) logic [15:0] v_mem [0:V_BANKS-1][0:V_ROWS*2-1];

  logic wr_bad;
  integer lane;
  integer wr_word;
  integer wr_bank;
  integer wr_row;

  assign axi_wr_ready = axi_rst_n;
  assign axi_wr_fire = axi_wr_valid && axi_wr_ready;
  assign axi_wr_error = wr_bad;

  // Four parallel BF16 writes per accepted AXI beat.  Only the selected bank
  // array is touched; each bank receives at most one write for a beat.
  always_ff @(posedge axi_clk) begin
    if (!axi_rst_n) begin
      axi_wr_count   <= 64'd0;
      axi_error_count <= 64'd0;
      wr_bad         <= 1'b0;
    end else if (axi_wr_fire) begin
      wr_bad = 1'b0;
      if ((axi_wr_kind == 2'd3) || (axi_wr_word_addr[1:0] != 2'b00)) begin
        wr_bad = 1'b1;
      end else if ((axi_wr_kind == 2'd0) &&
                   (({32'd0, axi_wr_word_addr} + 32'd3) >= Q_WORDS_PER_BUF)) begin
        wr_bad = 1'b1;
      end else if ((axi_wr_kind == 2'd1) &&
                   (({32'd0, axi_wr_word_addr} + 32'd3) >= K_WORDS_PER_BUF)) begin
        wr_bad = 1'b1;
      end else if ((axi_wr_kind == 2'd2) &&
                   (({32'd0, axi_wr_word_addr} + 32'd3) >= V_WORDS_PER_BUF)) begin
        wr_bad = 1'b1;
      end

      if (wr_bad) begin
        axi_error_count <= axi_error_count + 64'd1;
      end else begin
        axi_wr_count <= axi_wr_count + 64'd1;
        for (lane = 0; lane < 4; lane = lane + 1) begin
          wr_word = axi_wr_word_addr + lane;
          case (axi_wr_kind)
            2'd0: begin
              wr_bank = wr_word & (Q_BANKS - 1);
              wr_row  = (wr_word >> Q_BANK_BITS) + (axi_wr_buf ? Q_ROWS : 0);
              q_mem[wr_bank][wr_row] <= axi_wr_data[lane*16 +: 16];
            end
            2'd1: begin
              wr_bank = wr_word & (K_BANKS - 1);
              wr_row  = (wr_word >> K_BANK_BITS) + (axi_wr_buf ? K_ROWS : 0);
              k_mem[wr_bank][wr_row] <= axi_wr_data[lane*16 +: 16];
            end
            2'd2: begin
              wr_bank = wr_word & (V_BANKS - 1);
              wr_row  = (wr_word >> V_BANK_BITS) + (axi_wr_buf ? V_ROWS : 0);
              v_mem[wr_bank][wr_row] <= axi_wr_data[lane*16 +: 16];
            end
            default: ;
          endcase
        end
      end
    end
  end

  integer b;
  integer q_addr_i;
  integer k_addr_i;
  integer v_addr_i;
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      q_rd_valid <= '0;
      k_rd_valid <= '0;
      v_rd_valid <= '0;
      q_rd_data  <= '0;
      k_rd_data  <= '0;
      v_rd_data  <= '0;
    end else begin
      q_rd_valid <= q_rd_en;
      k_rd_valid <= k_rd_en;
      v_rd_valid <= v_rd_en;
      for (b = 0; b < Q_BANKS; b = b + 1) begin
        if (q_rd_en[b]) begin
          q_addr_i = q_rd_addr[b*Q_ROW_BITS +: Q_ROW_BITS];
          q_rd_data[b*16 +: 16] <= q_mem[b][q_addr_i];
        end
      end
      for (b = 0; b < K_BANKS; b = b + 1) begin
        if (k_rd_en[b]) begin
          k_addr_i = k_rd_addr[b*K_ROW_BITS +: K_ROW_BITS];
          k_rd_data[b*16 +: 16] <= k_mem[b][k_addr_i];
        end
      end
      for (b = 0; b < V_BANKS; b = b + 1) begin
        if (v_rd_en[b]) begin
          v_addr_i = v_rd_addr[b*V_ROW_BITS +: V_ROW_BITS];
          v_rd_data[b*16 +: 16] <= v_mem[b][v_addr_i];
        end
      end
    end
  end

`ifndef SYNTHESIS
  // Elaboration-time checks catch illegal bank geometry in simulation before
  // modulo/shift expressions silently produce an incorrect physical map.
  initial begin
    if ((Q_BANKS < 1) || ((Q_BANKS & (Q_BANKS-1)) != 0) ||
        (K_BANKS < 1) || ((K_BANKS & (K_BANKS-1)) != 0) ||
        (V_BANKS < 1) || ((V_BANKS & (V_BANKS-1)) != 0))
      $fatal(1, "CATS_R4 bank counts must be powers of two");
    if ((Q_WORDS_PER_BUF % Q_BANKS) != 0 ||
        (K_WORDS_PER_BUF % K_BANKS) != 0 ||
        (V_WORDS_PER_BUF % V_BANKS) != 0)
      $fatal(1, "CATS_R4 words-per-buffer must divide evenly into banks");
  end
`endif

endmodule
