`timescale 1ns/1ps
module tb_cats_r4_dma_group_scheduler;
  logic clk=0;always #5 clk=~clk;logic rst_n=0,counter_clear=0;
  logic start_valid=0,start_ready;logic[15:0]start_epoch;
  logic[63:0]start_q_base,start_k_base,start_v_base,start_context_base;
  logic prep_valid,prep_ready=1,prep_buffer;logic[15:0]prep_epoch;
  logic publish_valid,publish_ready=1,publish_buffer;logic[15:0]publish_epoch;
  logic activate_valid,activate_ready=1,activate_buffer;logic[15:0]activate_epoch;
  logic cmd_valid,cmd_ready=0;logic[15:0]cmd_epoch;logic[1:0]cmd_cluster_id;
  logic[2:0]cmd_group_id;logic[4:0]cmd_q_head_base;logic cmd_kv_buffer;
  logic cluster_done_valid=0,cluster_done_ready;logic[15:0]cluster_done_epoch;
  logic[2:0]cluster_done_group;logic cluster_done_error=0;
  logic dma_desc_valid,dma_desc_ready,dma_desc_write;logic[1:0]dma_desc_kind;
  logic[2:0]dma_desc_group;logic dma_desc_buffer;logic[5:0]dma_desc_tag;
  logic[63:0]dma_desc_addr;logic[31:0]dma_desc_byte_count;
  logic dma_cpl_valid=0,dma_cpl_ready;logic[5:0]dma_cpl_tag;logic dma_cpl_error=0;
  logic running,transaction_done,halted,error_sticky;logic[1:0]buffer_ready_state;
  logic[63:0]read_desc_count,write_desc_count,read_completion_count;
  logic[63:0]write_completion_count,read_byte_count,write_byte_count;
  logic[63:0]groups_loaded,groups_started,groups_compute_done,groups_written;
  logic[63:0]buffer_reuse_stall_cycles,protocol_errors,dma_errors,cluster_errors;
  cats_r4_dma_group_scheduler dut(.*);
  logic burst_valid,burst_ready,burst_last,split_busy,split_error;
  logic[63:0]burst_addr;logic[7:0]burst_axi_len,burst_tag;
  logic[8:0]burst_beats;logic[11:0]burst_byte_count;
  logic[31:0]split_inputs,split_bursts,split_errors;
  logic[63:0]split_beats;
  cats_r4_axi_burst_splitter splitter(
    .clk,.rst_n,.clear(1'b0),
    .in_valid(dma_desc_valid),.in_ready(dma_desc_ready),
    .in_addr(dma_desc_addr),.in_byte_count(dma_desc_byte_count),
    .in_tag({2'b00,dma_desc_tag}),.out_valid(burst_valid),
    .out_ready(burst_ready),.out_addr(burst_addr),
    .out_axi_len(burst_axi_len),.out_beats(burst_beats),
    .out_byte_count(burst_byte_count),.out_tag(burst_tag),
    .out_last(burst_last),.busy(split_busy),.protocol_error(split_error),
    .input_desc_count(split_inputs),.burst_desc_count(split_bursts),
    .error_count(split_errors),.emitted_beat_count(split_beats)
  );

  logic[5:0]ptag[0:63];integer pdelay[0:63];logic perror[0:63],pvalid[0:63];
  logic[3:0]desc_seen[0:7];logic[2:0]read_done_seen[0:7];
  logic[7:0]cmd_seen,write_done_seen,compute_done_seen;
  integer i,slot,cycles,publish_count,activate_count,pending_count,cluster_delay;
  integer burst_count;
  logic cluster_pending,cluster_handshook;logic[2:0]cluster_group;logic[15:0]cluster_epoch;
  logic active_model_valid,active_model_buffer,overlap_seen,inject_error,error_injected;
  integer post_halt_descs,post_halt_cmds;

  task automatic fail(input string s);begin $display("FAIL: %s",s);$fatal(1);end endtask
  task automatic tick;begin @(posedge clk);#1;end endtask
  task automatic init_model;begin
    dma_cpl_valid=0;dma_cpl_error=0;cluster_done_valid=0;
    cluster_done_error=0;
    for(i=0;i<64;i=i+1)begin pvalid[i]=0;pdelay[i]=0;ptag[i]=0;perror[i]=0;end
    for(i=0;i<8;i=i+1)begin desc_seen[i]=0;read_done_seen[i]=0;end
    cmd_seen=0;write_done_seen=0;compute_done_seen=0;publish_count=0;
    activate_count=0;pending_count=0;burst_count=0;cluster_pending=0;cluster_handshook=0;cluster_delay=0;
    active_model_valid=0;active_model_buffer=0;overlap_seen=0;error_injected=0;
    post_halt_descs=0;post_halt_cmds=0;
  end endtask
  task automatic begin_run(input logic[15:0] ep);begin
    @(negedge clk);start_epoch=ep;start_q_base=64'h1000_0000;
    start_k_base=64'h2000_0000;start_v_base=64'h3000_0000;
    start_context_base=64'h4000_0000;start_valid=1;#1;
    if(!start_ready)fail("start not ready");tick();@(negedge clk);start_valid=0;
  end endtask

  // Random ready and independently delayed, out-of-order DMA completions.
  always @(negedge clk)if(rst_n)begin
    burst_ready=($urandom_range(0,3)!=0);cmd_ready=($urandom_range(0,2)!=0);
    if(dma_cpl_valid&&dma_cpl_ready)begin
      slot=-1;for(i=0;i<64;i=i+1)if(slot<0&&pvalid[i]&&ptag[i]==dma_cpl_tag&&pdelay[i]==0)slot=i;
      if(slot<0)fail("completion was not pending");pvalid[slot]=0;pending_count=pending_count-1;
      dma_cpl_valid=0;dma_cpl_error=0;
    end
    for(i=0;i<64;i=i+1)if(pvalid[i]&&pdelay[i]>0)pdelay[i]=pdelay[i]-1;
    if(!dma_cpl_valid&&dma_cpl_ready)begin
      slot=-1;for(i=0;i<64;i=i+1)if(slot<0&&pvalid[i]&&pdelay[i]==0)slot=i;
      if(slot>=0)begin dma_cpl_valid=1;dma_cpl_tag=ptag[slot];dma_cpl_error=perror[slot];end
    end
    if(cluster_handshook)begin
      cluster_done_valid=0;cluster_pending=0;cluster_handshook=0;
    end
    if(cluster_pending&&cluster_delay>0)cluster_delay=cluster_delay-1;
    if(cluster_pending&&cluster_delay==0&&!cluster_done_valid)begin
      cluster_done_valid=1;cluster_done_group=cluster_group;
      cluster_done_epoch=cluster_epoch;cluster_done_error=0;
    end
  end

  always @(posedge clk)if(rst_n)begin
    cycles=cycles+1;
    if(dma_desc_valid&&dma_desc_ready)begin
      if(desc_seen[dma_desc_group][dma_desc_kind])fail("duplicate descriptor");
      desc_seen[dma_desc_group][dma_desc_kind]=1;
      if(dma_desc_buffer!==dma_desc_group[0]||
         dma_desc_tag!=={dma_desc_write,dma_desc_group,dma_desc_kind})fail("descriptor identity");
      case(dma_desc_kind)
       0:if(dma_desc_write||dma_desc_byte_count!=131072||dma_desc_addr!=64'h1000_0000+({61'd0,dma_desc_group}<<17))fail("Q descriptor");
       1:if(dma_desc_write||dma_desc_byte_count!=32768||dma_desc_addr!=64'h2000_0000+({61'd0,dma_desc_group}<<15))fail("K descriptor");
       2:if(dma_desc_write||dma_desc_byte_count!=32768||dma_desc_addr!=64'h3000_0000+({61'd0,dma_desc_group}<<15))fail("V descriptor");
       3:if(!dma_desc_write||dma_desc_byte_count!=131072||dma_desc_addr!=64'h4000_0000+({61'd0,dma_desc_group}<<17))fail("write descriptor");
      endcase
      if(dma_desc_group==1&&!dma_desc_write&&!compute_done_seen[0])overlap_seen=1;
    end
    if(burst_valid&&burst_ready)begin
      burst_count=burst_count+1;
      if(burst_beats<1||burst_beats>256||
         burst_axi_len!==burst_beats[7:0]-1'b1||
         burst_byte_count!=={burst_beats,3'b000})
        fail("split burst length");
      if(({1'b0,burst_addr[11:0]}+{1'b0,burst_byte_count})>13'd4096)
        fail("split burst crossed 4KiB");
      if(burst_last)begin
        $display("LAST t=%0t tag=%h bursts=%0d",$time,burst_tag,burst_count);
        slot=-1;for(i=0;i<64;i=i+1)if(slot<0&&!pvalid[i])slot=i;
        if(slot<0)fail("pending table full");
        pvalid[slot]=1;ptag[slot]=burst_tag[5:0];
        pdelay[slot]=$urandom_range(2,10);
        perror[slot]=inject_error&&!error_injected&&!burst_tag[5]&&
          burst_tag[4:2]==2&&burst_tag[1:0]==1;
        if(perror[slot])error_injected=1;
        pending_count=pending_count+1;
      end
    end
    if(dma_cpl_valid&&dma_cpl_ready)begin
      $display("CPL t=%0t tag=%h err=%0d ls=%0d lg=%0d acc=%b done=%b match=%0d",
        $time,dma_cpl_tag,dma_cpl_error,dut.ls,dut.lg,dut.accepted,
        dut.completed,dut.read_cpl_match);
      if(dma_cpl_tag[5])write_done_seen[dma_cpl_tag[4:2]]=1;
      else read_done_seen[dma_cpl_tag[4:2]][dma_cpl_tag[1:0]]=1;
    end
    if(publish_valid&&publish_ready)begin
      if(publish_buffer!==publish_count[0]||read_done_seen[publish_count]!=3'b111)
        fail("publish barrier");publish_count=publish_count+1;
    end
    if(activate_valid&&activate_ready)begin
      if(activate_count>=publish_count||activate_buffer!==activate_count[0])fail("activate barrier");
      if(active_model_valid&&active_model_buffer==activate_buffer)fail("active buffer overwrite");
      active_model_valid=1;active_model_buffer=activate_buffer;activate_count=activate_count+1;
    end
    if(cmd_valid&&cmd_ready)begin
      if(cmd_seen[cmd_group_id])fail("duplicate command");
      if(cmd_group_id>=activate_count)fail("command before activate");
      if(cmd_group_id>0&&!write_done_seen[cmd_group_id-1])fail("write barrier");
      if(cmd_q_head_base!={cmd_group_id,2'b00}||cmd_kv_buffer!=cmd_group_id[0]||cmd_cluster_id!=0)fail("command identity");
      cmd_seen[cmd_group_id]=1;cluster_pending=1;cluster_group=cmd_group_id;
      cluster_epoch=cmd_epoch;cluster_delay=$urandom_range(15,30);
    end
    if(cluster_done_valid&&cluster_done_ready)begin
      compute_done_seen[cluster_done_group]=1;cluster_handshook=1;
    end
    if(halted)begin
      if(dma_desc_valid&&dma_desc_ready)post_halt_descs=post_halt_descs+1;
      if(cmd_valid&&cmd_ready)post_halt_cmds=post_halt_cmds+1;
    end
  end

  initial begin
    init_model();inject_error=0;cycles=0;start_epoch=0;start_q_base=0;
    start_k_base=0;start_v_base=0;start_context_base=0;dma_cpl_tag=0;burst_ready=0;
    cluster_done_epoch=0;cluster_done_group=0;repeat(3)tick();rst_n=1;tick();
    begin_run(16'h1010);while(!transaction_done&&!halted&&cycles<10000)tick();
    if(halted||!transaction_done)begin
      $display("DEBUG run=%0d halt=%0d ls=%0d cs=%0d lg=%0d cg=%0d next_lg=%0d next_cg=%0d acc=%b cpl=%b loaded=%0d started=%0d computed=%0d written=%0d pending=%0d",
        running,halted,dut.ls,dut.cs,dut.lg,dut.cg,dut.next_lg,dut.next_cg,
        dut.accepted,dut.completed,groups_loaded,groups_started,
        groups_compute_done,groups_written,pending_count);
      fail("happy path incomplete");
    end
    for(i=0;i<8;i=i+1)if(desc_seen[i]!=4'hf)fail("group descriptor coverage");
    if(cmd_seen!=8'hff||write_done_seen!=8'hff||publish_count!=8||activate_count!=8)fail("lifecycle coverage");
    if(!overlap_seen)fail("prefetch overlap missing");
    if(burst_count!=1280||split_inputs!=32||split_bursts!=1280||
       split_beats!=327680||split_error||split_errors)fail("burst splitter closure");
    if(read_desc_count!=24||write_desc_count!=8||read_completion_count!=24||write_completion_count!=8)fail("descriptor counters");
    if(read_byte_count!=1572864||write_byte_count!=1048576)fail("byte counters");
    if(groups_loaded!=8||groups_started!=8||groups_compute_done!=8||groups_written!=8||protocol_errors||dma_errors||cluster_errors)fail("group counters");
    @(negedge clk);rst_n=0;repeat(2)tick();init_model();inject_error=1;cycles=0;
    @(negedge clk);rst_n=1;tick();begin_run(16'h2020);
    while(!halted&&cycles<1000)tick();
    if(!halted||!error_sticky||dma_errors!=1||protocol_errors!=1)fail("DMA error stop");
    repeat(20)tick();if(post_halt_descs||post_halt_cmds)fail("traffic after halt");
    if(transaction_done)fail("error reported done");
    $display("PASS cats_r4_dma_group_scheduler prefetch/barrier/random-latency/error-stop");$finish;
  end
endmodule
