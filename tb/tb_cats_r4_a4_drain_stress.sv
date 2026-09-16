`timescale 1ns/1ps

module tb_cats_r4_a4_drain_stress;
    logic clk=0,rst_n=0,clear=0,halt=0; always #5 clk=~clk;
    logic [15:0] active_epoch=16'h7000;
    logic [5:0] req_valid,req_ready,rsp_valid,deliver_valid;
    logic [23:0] req_tag,rsp_tag,deliver_tag;
    logic sidecars_empty,clear_ready;
    logic [63:0] requests_accepted,responses_delivered;
    logic [63:0] responses_dropped,unexpected_responses;
    logic all_normal_groups_done,clusters_quiescent,spools_empty,sink_idle;
    logic axi_outstanding_zero,event_buffers_empty,sticky_error;
    logic normal_drain_complete;
    integer lane;

    tb_cats_r4_a4_untagged_sidecars sidecars(.*);
    tb_cats_r4_a4_drain_gate_model drain_gate(.*);

    initial begin
        req_valid='0;req_tag='0;rsp_valid='0;rsp_tag='0;
        all_normal_groups_done=0;clusters_quiescent=0;spools_empty=0;
        sink_idle=0;axi_outstanding_zero=0;event_buffers_empty=0;sticky_error=0;
        repeat(3)@(posedge clk);rst_n=1;@(negedge clk);

        // One request on every Q/K/V x cluster sidecar.
        for(lane=0;lane<6;lane=lane+1) begin
            req_valid[lane]=1'b1;req_tag[lane*4 +: 4]=lane;
            @(posedge clk);@(negedge clk);req_valid='0;
        end
        if(sidecars_empty||clear_ready||requests_accepted!=6)
            $fatal(1,"sidecars did not capture six accepted requests");

        halt=1;
        req_valid[0]=1;req_tag[3:0]=4'hf;
        @(posedge clk);@(negedge clk);req_valid='0;
        if(req_ready!='0||requests_accepted!=6)
            $fatal(1,"halt accepted a new untagged request");

        // Late responses are consumed as discard drain and never delivered.
        for(lane=0;lane<6;lane=lane+1) begin
            rsp_valid[lane]=1'b1;rsp_tag[lane*4 +: 4]=lane;
            @(posedge clk);@(negedge clk);rsp_valid='0;
        end
        if(!sidecars_empty||!clear_ready||deliver_valid!='0||
           responses_dropped!=6||responses_delivered!=0)
            $fatal(1,"late-response discard drain mismatch");

        clear=1;@(posedge clk);@(negedge clk);clear=0;halt=0;
        active_epoch=16'h7001;
        req_valid[5]=1;req_tag[23:20]=4'ha;
        @(posedge clk);@(negedge clk);req_valid='0;
        rsp_valid[5]=1;rsp_tag[23:20]=4'ha;
        @(posedge clk);@(negedge clk);rsp_valid='0;
        if(!deliver_valid[5]||deliver_tag[23:20]!=4'ha||
           responses_delivered!=1||!sidecars_empty)
            $fatal(1,"new epoch response was not delivered exactly once");

        // Every drain term is mandatory and the result is registered.
        all_normal_groups_done=1;clusters_quiescent=1;spools_empty=1;
        sink_idle=1;axi_outstanding_zero=1;event_buffers_empty=0;
        @(posedge clk);@(negedge clk);
        if(normal_drain_complete)$fatal(1,"drain ignored nonempty event buffer");
        event_buffers_empty=1;sticky_error=1;
        @(posedge clk);@(negedge clk);
        if(normal_drain_complete)$fatal(1,"normal drain ignored sticky error");
        sticky_error=0;
        @(posedge clk);@(negedge clk);
        if(!normal_drain_complete)$fatal(1,"exact normal drain gate did not open");
        spools_empty=0;
        @(posedge clk);@(negedge clk);
        if(normal_drain_complete)$fatal(1,"drain remained high with nonempty spool");

        $display("PASS A4 DRAIN STRESS channels=Q/K/V clusters=2 accepted=7 late_dropped=6 delivered=1 halt_blocks_new=1 exact_drain_gate=1 clear_after_empty=1");
        $finish;
    end
endmodule
