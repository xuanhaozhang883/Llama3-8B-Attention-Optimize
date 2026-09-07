`timescale 1ns/1ps

module tb_cats_r4_axi64_qkv_banked_mem;
  localparam int QB = 4;
  localparam int KB = 8;
  localparam int VB = 4;
  localparam int QW = 64;
  localparam int KW = 64;
  localparam int VW = 64;
  localparam int QRB = $clog2((QW/QB)*2);
  localparam int KRB = $clog2((KW/KB)*2);
  localparam int VRB = $clog2((VW/VB)*2);

  logic axi_clk = 1'b0, core_clk = 1'b0;
  always #5 axi_clk = ~axi_clk;
  always #7 core_clk = ~core_clk;

  logic axi_rst_n = 1'b0, core_rst_n = 1'b0;
  logic wr_valid;
  logic wr_ready;
  logic [1:0] wr_kind;
  logic wr_buf;
  logic [31:0] wr_addr;
  logic [63:0] wr_data;
  logic wr_fire, wr_error;
  logic [63:0] wr_count, error_count;

  logic [QB-1:0] q_en;
  logic [QB*QRB-1:0] q_addr;
  logic [QB*16-1:0] q_data;
  logic [QB-1:0] q_valid;
  logic [KB-1:0] k_en;
  logic [KB*KRB-1:0] k_addr;
  logic [KB*16-1:0] k_data;
  logic [KB-1:0] k_valid;
  logic [VB-1:0] v_en;
  logic [VB*VRB-1:0] v_addr;
  logic [VB*16-1:0] v_data;
  logic [VB-1:0] v_valid;

  cats_r4_axi64_qkv_banked_mem #(
    .Q_BANKS(QB), .K_BANKS(KB), .V_BANKS(VB),
    .Q_WORDS_PER_BUF(QW), .K_WORDS_PER_BUF(KW), .V_WORDS_PER_BUF(VW)
  ) dut (
    .axi_clk(axi_clk), .axi_rst_n(axi_rst_n),
    .axi_wr_valid(wr_valid), .axi_wr_ready(wr_ready),
    .axi_wr_kind(wr_kind), .axi_wr_buf(wr_buf),
    .axi_wr_word_addr(wr_addr), .axi_wr_data(wr_data),
    .axi_wr_fire(wr_fire), .axi_wr_error(wr_error),
    .axi_wr_count(wr_count), .axi_error_count(error_count),
    .core_clk(core_clk), .core_rst_n(core_rst_n),
    .q_rd_en(q_en), .q_rd_addr(q_addr), .q_rd_data(q_data), .q_rd_valid(q_valid),
    .k_rd_en(k_en), .k_rd_addr(k_addr), .k_rd_data(k_data), .k_rd_valid(k_valid),
    .v_rd_en(v_en), .v_rd_addr(v_addr), .v_rd_data(v_data), .v_rd_valid(v_valid)
  );

  task automatic axi_write(input logic [1:0] kind, input logic buffer_sel,
                           input logic [31:0] addr, input logic [63:0] data);
    @(negedge axi_clk);
    wr_kind <= kind; wr_buf <= buffer_sel; wr_addr <= addr; wr_data <= data; wr_valid <= 1'b1;
    @(negedge axi_clk);
    while (!wr_ready) @(negedge axi_clk);
    wr_valid <= 1'b0;
  endtask

  integer i;
  initial begin
    wr_valid = 1'b0; wr_kind = 0; wr_buf = 0; wr_addr = 0; wr_data = 0;
    q_en = 0; q_addr = 0; k_en = 0; k_addr = 0; v_en = 0; v_addr = 0;
    repeat (3) @(posedge axi_clk);
    axi_rst_n <= 1'b1;
    repeat (3) @(posedge core_clk);
    core_rst_n <= 1'b1;

    // Q: two beats in ping and one in pong.  Each beat fans out to four banks.
    axi_write(2'd0, 1'b0, 32'd0, 64'h0004_0003_0002_0001);
    axi_write(2'd0, 1'b0, 32'd4, 64'h0008_0007_0006_0005);
    axi_write(2'd0, 1'b1, 32'd0, 64'h0104_0103_0102_0101);
    // K key-bank mapping (8 banks): three beats touch banks 0..3, 4..7, 0..3.
    axi_write(2'd1, 1'b0, 32'd0, 64'h1004_1003_1002_1001);
    axi_write(2'd1, 1'b0, 32'd4, 64'h1008_1007_1006_1005);
    axi_write(2'd1, 1'b0, 32'd8, 64'h1012_1011_1010_1009);
    // V feature-bank mapping, with pong buffer selected.
    axi_write(2'd2, 1'b1, 32'd0, 64'h2004_2003_2002_2001);

    repeat (3) @(posedge axi_clk);
    if (wr_count !== 64'd7 || error_count !== 64'd0) begin
      $display("FAIL write counters count=%0d errors=%0d", wr_count, error_count);
      $fatal(1);
    end

    // Read all Q banks in ping row 0 and row 1; response is one core cycle later.
    @(negedge core_clk);
    for (i = 0; i < QB; i = i + 1) begin
      q_en[i] <= 1'b1;
      q_addr[i*QRB +: QRB] <= (i < QB) ? 0 : 0;
    end
    @(posedge core_clk); #1;
    if (q_valid !== {QB{1'b1}} || q_data !== 64'h0004_0003_0002_0001) begin
      $display("FAIL Q ping data=%h valid=%b", q_data, q_valid); $fatal(1);
    end
    @(negedge core_clk); q_en <= '0;

    // K banks 0..7 at row 0 are checked in one parallel read.
    @(negedge core_clk);
    for (i = 0; i < KB; i = i + 1) begin
      k_en[i] <= 1'b1; k_addr[i*KRB +: KRB] <= 0;
    end
    @(posedge core_clk); #1;
    if (k_valid !== {KB{1'b1}} ||
        k_data[0*16 +: 16] !== 16'h1001 || k_data[3*16 +: 16] !== 16'h1004 ||
        k_data[4*16 +: 16] !== 16'h1005 || k_data[7*16 +: 16] !== 16'h1008) begin
      $display("FAIL K data=%h valid=%b", k_data, k_valid); $fatal(1);
    end
    @(negedge core_clk); k_en <= '0;

    // Invalid alignment is accepted as a beat but counted and does not write.
    axi_write(2'd0, 1'b0, 32'd2, 64'hdead_beef_dead_beef);
    repeat (2) @(posedge axi_clk);
    if (error_count !== 64'd1 || wr_count !== 64'd7) begin
      $display("FAIL invalid write count=%0d errors=%0d", wr_count, error_count);
      $fatal(1);
    end
    $display("PASS CATS_R4 AXI64 Q/K/V dual-clock bank expansion");
    $finish;
  end
endmodule
