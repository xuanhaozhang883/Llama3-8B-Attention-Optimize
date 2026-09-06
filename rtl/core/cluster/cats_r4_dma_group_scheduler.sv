`timescale 1ns/1ps

// CATS-R4 single-cluster DMA group scheduler (C2 infrastructure only).
// Long logical descriptors are split into AXI bursts by the existing splitter.
// NOT READY: no AXI master, CDC, board, or A/B datapath is instantiated here.
module cats_r4_dma_group_scheduler #(
    parameter int ADDR_W = 64,
    parameter int GROUPS = 8
) (
    input logic clk, input logic rst_n, input logic counter_clear,
    input logic start_valid, output logic start_ready,
    input logic [15:0] start_epoch,
    input logic [ADDR_W-1:0] start_q_base, start_k_base, start_v_base,
    input logic [ADDR_W-1:0] start_context_base,
    output logic prep_valid, input logic prep_ready,
    output logic prep_buffer, output logic [15:0] prep_epoch,
    output logic publish_valid, input logic publish_ready,
    output logic publish_buffer, output logic [15:0] publish_epoch,
    output logic activate_valid, input logic activate_ready,
    output logic activate_buffer, output logic [15:0] activate_epoch,
    output logic cmd_valid, input logic cmd_ready,
    output logic [15:0] cmd_epoch, output logic [1:0] cmd_cluster_id,
    output logic [2:0] cmd_group_id, output logic [4:0] cmd_q_head_base,
    output logic cmd_kv_buffer,
    input logic cluster_done_valid, output logic cluster_done_ready,
    input logic [15:0] cluster_done_epoch,
    input logic [2:0] cluster_done_group, input logic cluster_done_error,
    output logic dma_desc_valid, input logic dma_desc_ready,
    output logic dma_desc_write, output logic [1:0] dma_desc_kind,
    output logic [2:0] dma_desc_group, output logic dma_desc_buffer,
    output logic [5:0] dma_desc_tag,
    output logic [ADDR_W-1:0] dma_desc_addr,
    output logic [31:0] dma_desc_byte_count,
    input logic dma_cpl_valid, output logic dma_cpl_ready,
    input logic [5:0] dma_cpl_tag, input logic dma_cpl_error,
    output logic running, output logic transaction_done,
    output logic halted, output logic error_sticky,
    output logic [1:0] buffer_ready_state,
    output logic [63:0] read_desc_count, write_desc_count,
    output logic [63:0] read_completion_count, write_completion_count,
    output logic [63:0] read_byte_count, write_byte_count,
    output logic [63:0] groups_loaded, groups_started,
    output logic [63:0] groups_compute_done, groups_written,
    output logic [63:0] buffer_reuse_stall_cycles,
    output logic [63:0] protocol_errors, dma_errors, cluster_errors
);
    localparam logic [1:0] Q=0, K=1, V=2, CTX=3;
    localparam logic [2:0] EMPTY=0, LOADING=1, READY=2, ACTIVE=3;
    localparam logic [2:0] LI=0, LP=1, LD=2, LW=3, LPU=4;
    localparam logic [2:0] CI=0, CA=1, CC=2, CW=3, CDO=4, CDW=5;
    localparam logic [31:0] Q_BYTES=131072, KV_BYTES=32768, O_BYTES=131072;

    logic [2:0] ls, cs, lg, cg;
    logic [3:0] next_lg, next_cg;
    logic [1:0] issue_kind;
    logic [2:0] accepted, completed;
    logic write_pending;
    logic [2:0] bstate[0:1], bgroup[0:1];
    logic active_buf_valid, active_buf;
    logic [15:0] epoch;
    logic [ADDR_W-1:0] qb,kb,vb,ob;
    logic read_req, write_req, read_cpl_match, write_cpl_match;
    logic desc_locked;
    logic held_write, held_buffer;
    logic [1:0] held_kind;
    logic [2:0] held_group;
    logic [5:0] held_tag;
    logic [ADDR_W-1:0] held_addr;
    logic [31:0] held_byte_count;
    logic cand_write, cand_buffer;
    logic [1:0] cand_kind;
    logic [2:0] cand_group;
    logic [5:0] cand_tag;
    logic [ADDR_W-1:0] cand_addr;
    logic [31:0] cand_byte_count;

    function automatic [ADDR_W-1:0] goff(input logic[2:0] g,input integer sh);
        logic [ADDR_W-1:0] x;
        begin x={{(ADDR_W-3){1'b0}},g};goff=x<<sh;end
    endfunction

    assign start_ready=!running&&!halted;
    assign buffer_ready_state={(bstate[1]==READY),(bstate[0]==READY)};
    assign prep_valid=running&&!halted&&(ls==LP);
    assign prep_buffer=lg[0];assign prep_epoch=epoch;
    assign publish_valid=running&&!halted&&(ls==LPU);
    assign publish_buffer=lg[0];assign publish_epoch=epoch;
    assign activate_valid=running&&!halted&&(cs==CA);
    assign activate_buffer=cg[0];assign activate_epoch=epoch;
    assign cmd_valid=running&&!halted&&(cs==CC);
    assign cmd_epoch=epoch;assign cmd_cluster_id=0;assign cmd_group_id=cg;
    assign cmd_q_head_base={cg,2'b00};assign cmd_kv_buffer=cg[0];
    assign cluster_done_ready=running&&!halted&&(cs==CW);

    assign read_req=(ls==LD);assign write_req=(cs==CDO);
    assign cand_write=write_req;
    assign cand_kind=write_req?CTX:issue_kind;
    assign cand_group=write_req?cg:lg;
    assign cand_buffer=cand_group[0];
    assign cand_tag={cand_write,cand_group,cand_kind};
    assign dma_desc_valid=!halted&&(desc_locked||
                          (running&&(write_req||read_req)));
    assign dma_desc_write=desc_locked?held_write:cand_write;
    assign dma_desc_kind=desc_locked?held_kind:cand_kind;
    assign dma_desc_group=desc_locked?held_group:cand_group;
    assign dma_desc_buffer=desc_locked?held_buffer:cand_buffer;
    assign dma_desc_tag=desc_locked?held_tag:cand_tag;
    assign dma_desc_addr=desc_locked?held_addr:cand_addr;
    assign dma_desc_byte_count=desc_locked?held_byte_count:cand_byte_count;
    always_comb begin
        cand_addr='0;cand_byte_count='0;
        if(write_req)begin cand_addr=ob+goff(cg,17);cand_byte_count=O_BYTES;end
        else case(issue_kind)
          Q:begin cand_addr=qb+goff(lg,17);cand_byte_count=Q_BYTES;end
          K:begin cand_addr=kb+goff(lg,15);cand_byte_count=KV_BYTES;end
          V:begin cand_addr=vb+goff(lg,15);cand_byte_count=KV_BYTES;end
          default:begin cand_addr='0;cand_byte_count='0;end
        endcase
    end
    assign dma_cpl_ready=running&&!halted;
    assign read_cpl_match=!dma_cpl_tag[5]&&(dma_cpl_tag[4:2]==lg)&&
      (dma_cpl_tag[1:0]!=CTX)&&accepted[dma_cpl_tag[1:0]]&&
      !completed[dma_cpl_tag[1:0]]&&((ls==LD)||(ls==LW));
    assign write_cpl_match=dma_cpl_tag[5]&&(dma_cpl_tag[4:2]==cg)&&
      (dma_cpl_tag[1:0]==CTX)&&write_pending&&(cs==CDW);

    always_ff @(posedge clk) begin
      if(!rst_n)begin
        running<=0;transaction_done<=0;halted<=0;error_sticky<=0;
        epoch<='0;qb<='0;kb<='0;vb<='0;ob<='0;ls<=LI;cs<=CI;
        next_lg<=0;next_cg<=0;lg<=0;cg<=0;issue_kind<=Q;
        accepted<=0;completed<=0;write_pending<=0;
        desc_locked<=0;held_write<=0;held_kind<=0;held_group<=0;
        held_buffer<=0;held_tag<=0;held_addr<=0;held_byte_count<=0;
        bstate[0]<=EMPTY;bstate[1]<=EMPTY;bgroup[0]<=0;bgroup[1]<=0;
        active_buf_valid<=0;active_buf<=0;
        read_desc_count<=0;write_desc_count<=0;read_completion_count<=0;
        write_completion_count<=0;read_byte_count<=0;write_byte_count<=0;
        groups_loaded<=0;groups_started<=0;groups_compute_done<=0;
        groups_written<=0;buffer_reuse_stall_cycles<=0;protocol_errors<=0;
        dma_errors<=0;cluster_errors<=0;
      end else begin
        if(start_valid&&start_ready)begin
          running<=1;transaction_done<=0;error_sticky<=0;epoch<=start_epoch;
          qb<=start_q_base;kb<=start_k_base;vb<=start_v_base;ob<=start_context_base;
          ls<=LI;cs<=CI;next_lg<=0;next_cg<=0;accepted<=0;completed<=0;
          write_pending<=0;desc_locked<=0;bstate[0]<=EMPTY;bstate[1]<=EMPTY;
          active_buf_valid<=0;
          read_desc_count<=0;write_desc_count<=0;read_completion_count<=0;
          write_completion_count<=0;read_byte_count<=0;write_byte_count<=0;
          groups_loaded<=0;groups_started<=0;groups_compute_done<=0;
          groups_written<=0;buffer_reuse_stall_cycles<=0;protocol_errors<=0;
          dma_errors<=0;cluster_errors<=0;
        end else if(running&&!halted)begin
          if(!desc_locked&&(write_req||read_req)&&!dma_desc_ready)begin
            desc_locked<=1;held_write<=cand_write;held_kind<=cand_kind;
            held_group<=cand_group;held_buffer<=cand_buffer;
            held_tag<=cand_tag;held_addr<=cand_addr;
            held_byte_count<=cand_byte_count;
          end else if(desc_locked&&dma_desc_ready)desc_locked<=0;
          if(ls==LI&&next_lg<GROUPS)begin
            if(bstate[next_lg[0]]==EMPTY)begin lg<=next_lg[2:0];ls<=LP;end
            else buffer_reuse_stall_cycles<=buffer_reuse_stall_cycles+1;
          end
          if(prep_valid&&prep_ready)begin
            bstate[lg[0]]<=LOADING;bgroup[lg[0]]<=lg;accepted<=0;completed<=0;
            issue_kind<=Q;ls<=LD;
          end
          if(dma_desc_valid&&dma_desc_ready&&!dma_desc_write)begin
            accepted[dma_desc_kind]<=1;read_desc_count<=read_desc_count+1;
            read_byte_count<=read_byte_count+dma_desc_byte_count;
            if(dma_desc_kind==V)ls<=LW;else issue_kind<=dma_desc_kind+1;
          end
          if(ls==LW&&(&accepted)&&(&completed))ls<=LPU;
          if(publish_valid&&publish_ready)begin
            bstate[lg[0]]<=READY;groups_loaded<=groups_loaded+1;
            next_lg<=next_lg+1;ls<=LI;
          end
          if(cs==CI&&next_cg<GROUPS&&bstate[next_cg[0]]==READY&&
             bgroup[next_cg[0]]==next_cg[2:0])begin cg<=next_cg[2:0];cs<=CA;end
          if(activate_valid&&activate_ready)begin
            if(active_buf_valid)bstate[active_buf]<=EMPTY;
            active_buf_valid<=1;active_buf<=cg[0];bstate[cg[0]]<=ACTIVE;cs<=CC;
          end
          if(cmd_valid&&cmd_ready)begin groups_started<=groups_started+1;cs<=CW;end
          if(cluster_done_valid&&cluster_done_ready)begin
            if(cluster_done_epoch!=epoch||cluster_done_group!=cg||cluster_done_error)begin
              halted<=1;error_sticky<=1;cluster_errors<=cluster_errors+1;
              protocol_errors<=protocol_errors+1;
            end else begin groups_compute_done<=groups_compute_done+1;cs<=CDO;end
          end
          if(dma_desc_valid&&dma_desc_ready&&dma_desc_write)begin
            write_pending<=1;write_desc_count<=write_desc_count+1;
            write_byte_count<=write_byte_count+dma_desc_byte_count;cs<=CDW;
          end
          if(dma_cpl_valid&&dma_cpl_ready)begin
            if(dma_cpl_error||!(read_cpl_match||write_cpl_match))begin
              halted<=1;error_sticky<=1;protocol_errors<=protocol_errors+1;
              if(dma_cpl_error)dma_errors<=dma_errors+1;
            end else if(read_cpl_match)begin
              completed[dma_cpl_tag[1:0]]<=1;
              read_completion_count<=read_completion_count+1;
            end else begin
              write_pending<=0;write_completion_count<=write_completion_count+1;
              groups_written<=groups_written+1;
              if(cg==GROUPS-1)begin transaction_done<=1;running<=0;cs<=CI;end
              else begin next_cg<=next_cg+1;cs<=CI;end
            end
          end
        end
        if(counter_clear)begin
          read_desc_count<=0;write_desc_count<=0;read_completion_count<=0;
          write_completion_count<=0;read_byte_count<=0;write_byte_count<=0;
          groups_loaded<=0;groups_started<=0;groups_compute_done<=0;
          groups_written<=0;buffer_reuse_stall_cycles<=0;protocol_errors<=0;
          dma_errors<=0;cluster_errors<=0;error_sticky<=0;
        end
      end
    end
    initial begin
      if(ADDR_W<20)$error("ADDR_W must be >=20");
      if(GROUPS!=8)$error("CATS-R4 requires 8 groups");
    end
endmodule
