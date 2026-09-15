`timescale 1ns/1ps
module tb_cats_r4_a4_event_join;
    localparam integer CLUSTERS=4;
    localparam integer PAYLOAD_WIDTH=16;
    logic clk=0; always #1 clk=~clk;
    logic rst_n=0,clear=0,counter_clear=0;
    logic [CLUSTERS-1:0] source_valid,source_ready;
    logic [CLUSTERS*PAYLOAD_WIDTH-1:0] source_payload;
    logic event_valid,event_ready;
    logic [1:0] event_source;
    logic [PAYLOAD_WIDTH-1:0] event_payload;
    logic [CLUSTERS*64-1:0] source_events_accepted;
    logic [63:0] events_emitted,event_stall_cycles,simultaneous_accept_cycles;
    logic [17:0] held_event;
    integer received,stalls_before_clear;

    cats_r4_a4_event_join #(.CLUSTERS(CLUSTERS),.PAYLOAD_WIDTH(PAYLOAD_WIDTH)) dut (.*);

    task automatic set_payload(input integer source,input logic [15:0] value);
        source_payload[source*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]=value;
    endtask
    task automatic expect_event(input integer source,input logic [15:0] value);
        begin
            while(!event_valid) @(posedge clk);
            if(event_source!==source||event_payload!==value)
                $fatal(1,"event mismatch source=%0d/%0d payload=%h/%h",
                       event_source,source,event_payload,value);
            @(posedge clk); @(negedge clk); received=received+1;
        end
    endtask

    initial begin
        source_valid=0;source_payload=0;event_ready=0;received=0;
        repeat(4) @(posedge clk);rst_n=1;@(negedge clk);
        set_payload(1,16'h1101);set_payload(3,16'h3303);
        source_valid[1]=1;source_valid[3]=1;
        @(posedge clk);@(negedge clk);source_valid=0;
        while(!event_valid) @(posedge clk);
        if(event_source!==1||event_payload!==16'h1101)
            $fatal(1,"initial arbitration mismatch source=%0d payload=%h pending=%b flat=%h p1=%h p3=%h",
                   event_source,event_payload,dut.pending,source_payload,
                   dut.pending_payload[1],dut.pending_payload[3]);
        held_event={event_source,event_payload};
        set_payload(0,16'h000a);source_valid[0]=1;
        repeat(3) begin
            @(posedge clk);
            if(!event_valid||{event_source,event_payload}!==held_event)
                $fatal(1,"locked event changed under backpressure");
        end
        @(negedge clk);source_valid=0;event_ready=1;
        expect_event(1,16'h1101);
        expect_event(3,16'h3303);
        expect_event(0,16'h000a);
        @(negedge clk);event_ready=0;
        repeat(2) @(posedge clk);
        if(event_valid||received!=3||events_emitted!=3||
           source_events_accepted[0*64 +:64]!=1||
           source_events_accepted[1*64 +:64]!=1||
           source_events_accepted[2*64 +:64]!=0||
           source_events_accepted[3*64 +:64]!=1||
           simultaneous_accept_cycles!=1||event_stall_cycles<3)
            $fatal(1,"event join counter/closure mismatch");
        stalls_before_clear=event_stall_cycles;

        @(negedge clk);counter_clear=1;@(posedge clk);@(negedge clk);counter_clear=0;
        @(posedge clk);#0;
        if(source_events_accepted||events_emitted||event_stall_cycles||
           simultaneous_accept_cycles)
            $fatal(1,"counter_clear failed while idle");

        // clear discards buffered state without silently clearing telemetry.
        @(negedge clk);set_payload(2,16'h2202);source_valid[2]=1;
        @(posedge clk);@(negedge clk);source_valid=0;
        if(!event_valid||source_events_accepted[2*64 +:64]!=1)
            $fatal(1,"clear setup event was not buffered");
        clear=1;@(posedge clk);@(negedge clk);clear=0;
        if(event_valid||source_events_accepted[2*64 +:64]!=1)
            $fatal(1,"clear did not discard only buffered state");
        $display("PASS A4 EVENT JOIN clusters=4 emitted=3 locked_stalls=%0d simultaneous=1",
                 stalls_before_clear);
        $finish;
    end
endmodule
