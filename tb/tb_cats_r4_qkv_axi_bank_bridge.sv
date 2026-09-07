`timescale 1ns/1ps

module tb_cats_r4_qkv_axi_bank_bridge;
  logic axi_clk = 0, core_clk = 0;
  always #2 axi_clk = ~axi_clk;
  always #3 core_clk = ~core_clk;

  logic axi_rst_n = 0, core_rst_n = 0;
  logic wr_valid, wr_ready, wr_buffer, wr_last;
  logic [1:0] wr_kind;
  logic [15:0] wr_epoch;
  logic [2:0] wr_group;
  logic [4:0] wr_global_q_head;
  logic [2:0] wr_row_window;
  logic [11:0] wr_beat_index;
  logic [63:0] wr_data;
  logic [7:0] wr_strb;
  logic done_valid, done_ready, done_buffer;
  logic [1:0] done_kind;
  logic [15:0] done_epoch;
  logic [2:0] done_group;
  logic [4:0] done_global_q_head;
  logic [2:0] done_row_window;

  logic active_valid, active_buffer;
  logic q_req_valid, q_req_ready, q_rsp_valid;
  logic [3:0] q_req_context_tag, q_rsp_context_tag;
  logic [6:0] q_req_d;
  logic [15:0] q_rsp_bf16;
  logic k_req_valid, k_req_ready, k_rsp_valid;
  logic [3:0] k_req_context_tag, k_rsp_context_tag;
  logic [1:0] k_req_key_block;
  logic [6:0] k_req_d;
  logic [511:0] k_rsp_vec;
  logic v_req_valid, v_req_ready, v_rsp_valid;
  logic [3:0] v_req_context_tag, v_rsp_context_tag;
  logic [6:0] v_req_key;
  logic [1:0] v_req_feature_block;
  logic [511:0] v_rsp_vec;
  logic [63:0] q_beats_accepted, k_beats_accepted, v_beats_accepted;
  logic [63:0] protocol_errors;
  logic protocol_error_sticky;

  cats_r4_qkv_axi_bank_bridge dut (
    .axi_clk, .axi_rst_n, .wr_valid, .wr_ready, .wr_kind, .wr_buffer,
    .wr_epoch, .wr_group, .wr_global_q_head, .wr_row_window, .wr_beat_index,
    .wr_data, .wr_strb, .wr_last, .done_valid, .done_ready, .done_kind,
    .done_buffer, .done_epoch, .done_group, .done_global_q_head,
    .done_row_window, .core_clk, .core_rst_n, .active_valid, .active_buffer,
    .q_req_valid, .q_req_ready, .q_req_context_tag, .q_req_d, .q_rsp_valid,
    .q_rsp_context_tag, .q_rsp_bf16, .k_req_valid, .k_req_ready,
    .k_req_context_tag, .k_req_key_block, .k_req_d, .k_rsp_valid,
    .k_rsp_context_tag, .k_rsp_vec, .v_req_valid, .v_req_ready,
    .v_req_context_tag, .v_req_key, .v_req_feature_block, .v_rsp_valid,
    .v_rsp_context_tag, .v_rsp_vec, .q_beats_accepted, .k_beats_accepted,
    .v_beats_accepted, .protocol_errors, .protocol_error_sticky
  );

  task automatic fail(input string msg);
    begin $display("FAIL: %s", msg); $fatal(1); end
  endtask

  function automatic logic [15:0] w16(input integer value);
    w16 = value[15:0];
  endfunction

  task automatic send_descriptor(input logic [1:0] kind, input integer beats);
    integer beat;
    logic [63:0] data;
    begin
      $display("DESC_BEGIN kind=%0d beats=%0d t=%0t", kind, beats, $time);
      for (beat = 0; beat < beats; beat = beat + 1) begin
        @(negedge axi_clk);
        case (kind)
          2'd0: data = {w16(16'h1000 + beat*4 + 3), w16(16'h1000 + beat*4 + 2),
                         w16(16'h1000 + beat*4 + 1), w16(16'h1000 + beat*4)};
          2'd1: data = {4{w16(16'h2000 + beat)}};
          default: data = {w16(16'h3000 + beat*4 + 3), w16(16'h3000 + beat*4 + 2),
                           w16(16'h3000 + beat*4 + 1), w16(16'h3000 + beat*4)};
        endcase
        wr_kind = kind; wr_buffer = 1'b0; wr_epoch = 16'h55aa;
        wr_group = 3'd0; wr_global_q_head = 5'd0; wr_row_window = 3'd0;
        wr_beat_index = beat[11:0]; wr_data = data; wr_strb = 8'hff;
        wr_last = (beat == beats-1); wr_valid = 1'b1;
        #1;
        if (!wr_ready) fail("unexpected write backpressure");
      end
      @(negedge axi_clk);
      wr_valid = 1'b0;
      $display("DESC_ACCEPTED kind=%0d beats=%0d t=%0t", kind, beats, $time);
    end
  endtask

  task automatic wait_done(input logic [1:0] kind, input logic [63:0] count,
                           input string label);
    begin
      while (!done_valid) @(posedge axi_clk);
      if (done_kind !== kind || done_epoch !== 16'h55aa || done_group !== 3'd0 ||
          done_global_q_head !== 5'd0 || done_row_window !== 3'd0 || done_buffer !== 1'b0)
        fail({label, " done descriptor mismatch"});
      done_ready <= 1'b1;
      @(posedge axi_clk); #1;
      done_ready <= 1'b0;
      if (kind == 2'd0 && q_beats_accepted !== count) fail({label, " Q count"});
      if (kind == 2'd1 && k_beats_accepted !== count) fail({label, " K count"});
      if (kind == 2'd2 && v_beats_accepted !== count) fail({label, " V count"});
      if (protocol_errors !== 0 || protocol_error_sticky) fail({label, " protocol error"});
    end
  endtask

  integer i;
  logic [15:0] expected_q;
  logic [15:0] expected_k0, expected_k31;
  logic [15:0] expected_v4;
  time q_fire_time, k_fire_time, v_fire_time;
  time q_rsp_time, k_rsp_time, v_rsp_time;
  always @(posedge core_clk) begin
    if (q_req_valid && q_req_ready) q_fire_time = $time;
    if (k_req_valid && k_req_ready) k_fire_time = $time;
    if (v_req_valid && v_req_ready) v_fire_time = $time;
    if (q_rsp_valid) q_rsp_time = $time;
    if (k_rsp_valid) k_rsp_time = $time;
    if (v_rsp_valid) v_rsp_time = $time;
  end
  always @(posedge q_rsp_valid) q_rsp_time = $time;
  always @(posedge k_rsp_valid) k_rsp_time = $time;
  always @(posedge v_rsp_valid) v_rsp_time = $time;
  initial begin
    wr_valid = 0; wr_kind = 0; wr_buffer = 0; wr_epoch = 0; wr_group = 0;
    q_fire_time = 0; k_fire_time = 0; v_fire_time = 0;
    q_rsp_time = 0; k_rsp_time = 0; v_rsp_time = 0;
    wr_global_q_head = 0; wr_row_window = 0; wr_beat_index = 0; wr_data = 0;
    wr_strb = 0; wr_last = 0; done_ready = 0; active_valid = 0; active_buffer = 0;
    q_req_valid = 0; q_req_context_tag = 0; q_req_d = 0;
    k_req_valid = 0; k_req_context_tag = 0; k_req_key_block = 0; k_req_d = 0;
    v_req_valid = 0; v_req_context_tag = 0; v_req_key = 0; v_req_feature_block = 0;
    $display("START bridge test");

    repeat (3) @(posedge axi_clk); axi_rst_n <= 1;
    repeat (3) @(posedge core_clk); core_rst_n <= 1; active_valid <= 1;
    $display("RESET_DONE t=%0t", $time);

    send_descriptor(2'd0, 512);
    wait_done(2'd0, 64'd512, "Q");
    $display("Q_DONE t=%0t", $time);

`ifndef CATS_R4_PROTOCOL_ONLY
    // Q read: context 2, d=5 maps to bank 1, row 65, beat 65 lane 1.
    @(negedge core_clk); q_req_context_tag <= 4'd2; q_req_d <= 7'd5; q_req_valid <= 1;
    while (!q_req_ready) @(negedge core_clk);
    @(negedge core_clk); q_req_valid <= 0;
    while (!q_rsp_valid) @(posedge core_clk);
    expected_q = 16'h1000 + 65*4 + 1;
    if (q_rsp_context_tag !== 4'd2 || q_rsp_bf16 !== expected_q) fail("Q readback");
    if ((q_rsp_time - q_fire_time) !== 12) fail("Q response latency is not two core cycles");
`endif

    send_descriptor(2'd1, 4096);
    wait_done(2'd1, 64'd4096, "K");
    $display("K_DONE t=%0t", $time);

`ifndef CATS_R4_PROTOCOL_ONLY
    // K read: block 1,d=7. Bank 0 comes from beat 1025, bank 31 from 2017.
    @(negedge core_clk); k_req_context_tag <= 4'd3; k_req_key_block <= 2'd1;
    k_req_d <= 7'd7; k_req_valid <= 1;
    while (!k_req_ready) @(negedge core_clk);
    @(negedge core_clk); k_req_valid <= 0;
    while (!k_rsp_valid) @(posedge core_clk);
    expected_k0 = 16'h2000 + 1025; expected_k31 = 16'h2000 + 2017;
    if (k_rsp_context_tag !== 4'd3 || k_rsp_vec[0 +: 16] !== expected_k0 ||
        k_rsp_vec[31*16 +: 16] !== expected_k31) fail("K readback");
    if ((k_rsp_time - k_fire_time) !== 12) fail("K response latency is not two core cycles");
`endif

    send_descriptor(2'd2, 4096);
    wait_done(2'd2, 64'd4096, "V");
    $display("V_DONE t=%0t", $time);

`ifndef CATS_R4_PROTOCOL_ONLY
    // V read: key 3, feature block 1; bank 4 stores feature 36 from beat 105.
    @(negedge core_clk); v_req_context_tag <= 4'd4; v_req_key <= 7'd3;
    v_req_feature_block <= 2'd1; v_req_valid <= 1;
    while (!v_req_ready) @(negedge core_clk);
    @(negedge core_clk); v_req_valid <= 0;
    while (!v_rsp_valid) @(posedge core_clk);
    expected_v4 = 16'h3000 + 105*4 + 0;
    if (v_rsp_context_tag !== 4'd4 || v_rsp_vec[4*16 +: 16] !== expected_v4)
      fail("V readback");
    if ((v_rsp_time - v_fire_time) !== 12) fail("V response latency is not two core cycles");
`endif

`ifdef CATS_R4_PROTOCOL_ONLY
    // Premature wr_last must be counted, suppress done, and sticky-stop writes.
    @(negedge axi_clk);
    wr_kind = 2'd0; wr_buffer = 1'b0; wr_epoch = 16'h55aa;
    wr_group = 3'd0; wr_global_q_head = 5'd0; wr_row_window = 3'd0;
    wr_beat_index = 12'd0; wr_data = '0; wr_strb = 8'hff;
    wr_last = 1'b1; wr_valid = 1'b1;
    #1;
    if (!wr_ready) fail("malformed descriptor first beat not accepted");
    @(posedge axi_clk); #1;
    wr_valid = 1'b0;
    if (!protocol_error_sticky || protocol_errors !== 64'd1)
      fail("premature wr_last did not set one sticky protocol error");
    if (done_valid) fail("premature wr_last emitted done");
    if (wr_ready) fail("sticky protocol error did not stop writes");
    if (q_beats_accepted !== 64'd513)
      fail("malformed accepted beat was not counted");
    $display("NEGATIVE_GATE_DONE t=%0t", $time);
    // Reset must clear the sticky protocol stop and descriptor state.  After
    // reset, deliberately change the descriptor group on beat 1; the token
    // mismatch must be rejected and counted instead of being accepted.
    axi_rst_n <= 1'b0;
    repeat (3) @(posedge axi_clk);
    axi_rst_n <= 1'b1;
    @(negedge axi_clk);
    wr_kind = 2'd0; wr_buffer = 1'b0; wr_epoch = 16'h0101;
    wr_group = 3'd0; wr_global_q_head = 5'd0; wr_row_window = 3'd0;
    wr_beat_index = 12'd0; wr_data = '0; wr_strb = 8'hff;
    wr_last = 1'b0; wr_valid = 1'b1;
    #1;
    if (!wr_ready) fail("reset did not reopen descriptor endpoint");
    @(posedge axi_clk);
    @(negedge axi_clk);
    wr_group = 3'd1; wr_beat_index = 12'd1;
    #1;
    if (wr_ready) fail("token mismatch was accepted");
    @(posedge axi_clk); #1;
    wr_valid = 1'b0;
    if (!protocol_error_sticky || protocol_errors !== 64'd1)
      fail("token mismatch did not set one sticky protocol error");
    $display("TOKEN_MISMATCH_GATE_DONE t=%0t", $time);
`endif

`ifdef CATS_R4_PROTOCOL_ONLY
    $display("PASS: CATS-R4 AXI/core bank bridge descriptors and counters");
`else
    $display("PASS: CATS-R4 AXI/core bank bridge descriptors, counters, and readback");
`endif
    $finish;
  end
endmodule
