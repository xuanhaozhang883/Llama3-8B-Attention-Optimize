`timescale 1ns/1ps

// Protocol model for C-owned Q/K/V services whose responses do not carry a
// complete epoch.  Every accepted request records its epoch until exactly one
// response arrives.  Halt blocks new requests and turns late responses into a
// discard drain; clear is legal only after all sidecars are empty.
module tb_cats_r4_a4_untagged_sidecars #(
    parameter integer LANES=6,
    parameter integer TAGS=16
) (
    input logic clk,input logic rst_n,input logic clear,input logic halt,
    input logic [15:0] active_epoch,
    input logic [LANES-1:0] req_valid,
    output logic [LANES-1:0] req_ready,
    input logic [LANES*4-1:0] req_tag,
    input logic [LANES-1:0] rsp_valid,
    input logic [LANES*4-1:0] rsp_tag,
    output logic [LANES-1:0] deliver_valid,
    output logic [LANES*4-1:0] deliver_tag,
    output logic sidecars_empty,output logic clear_ready,
    output logic [63:0] requests_accepted,
    output logic [63:0] responses_delivered,
    output logic [63:0] responses_dropped,
    output logic [63:0] unexpected_responses
);
    logic [LANES*TAGS-1:0] pending;
    logic [15:0] pending_epoch [0:LANES*TAGS-1];
    integer lane,tag;

    always_comb begin
        for(lane=0;lane<LANES;lane=lane+1)
            req_ready[lane]=!halt&&
                !pending[lane*TAGS+req_tag[lane*4 +: 4]];
    end
    assign sidecars_empty=(pending=='0);
    assign clear_ready=sidecars_empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending<='0;deliver_valid<='0;deliver_tag<='0;
            requests_accepted<='0;responses_delivered<='0;
            responses_dropped<='0;unexpected_responses<='0;
            for(lane=0;lane<LANES;lane=lane+1)
                for(tag=0;tag<TAGS;tag=tag+1)
                    pending_epoch[lane*TAGS+tag]<='0;
        end else begin
            deliver_valid<='0;
            if(clear) begin
                pending<='0;deliver_tag<='0;
            end else begin
                for(lane=0;lane<LANES;lane=lane+1) begin
                        if(req_valid[lane]&&req_ready[lane]) begin
                            pending[lane*TAGS+req_tag[lane*4 +: 4]]<=1'b1;
                            pending_epoch[lane*TAGS+req_tag[lane*4 +: 4]]<=active_epoch;
                            requests_accepted<=requests_accepted+1'b1;
                        end
                        if(rsp_valid[lane]) begin
                            if(pending[lane*TAGS+rsp_tag[lane*4 +: 4]]) begin
                                pending[lane*TAGS+rsp_tag[lane*4 +: 4]]<=1'b0;
                                if(!halt&&pending_epoch[lane*TAGS+rsp_tag[lane*4 +: 4]]==active_epoch) begin
                                    deliver_valid[lane]<=1'b1;
                                    deliver_tag[lane*4 +: 4]<=rsp_tag[lane*4 +: 4];
                                    responses_delivered<=responses_delivered+1'b1;
                                end else begin
                                    responses_dropped<=responses_dropped+1'b1;
                                end
                            end else begin
                                unexpected_responses<=unexpected_responses+1'b1;
                            end
                        end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) if(rst_n) begin
        assert(!(clear&&!clear_ready));
        for(lane=0;lane<LANES;lane=lane+1)
            assert(!(req_valid[lane]&&req_ready[lane]&&rsp_valid[lane]&&
                     req_tag[lane*4 +: 4]==rsp_tag[lane*4 +: 4]));
    end
`endif
endmodule

module tb_cats_r4_a4_drain_gate_model(
    input logic clk,input logic rst_n,input logic clear,
    input logic all_normal_groups_done,input logic clusters_quiescent,
    input logic sidecars_empty,input logic spools_empty,input logic sink_idle,
    input logic axi_outstanding_zero,input logic event_buffers_empty,
    input logic sticky_error,output logic normal_drain_complete
);
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n||clear) normal_drain_complete<=1'b0;
        else normal_drain_complete<=all_normal_groups_done&&clusters_quiescent&&
            sidecars_empty&&spools_empty&&sink_idle&&axi_outstanding_zero&&
            event_buffers_empty&&!sticky_error;
    end
endmodule
