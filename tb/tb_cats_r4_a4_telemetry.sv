`timescale 1ns/1ps
module tb_cats_r4_a4_telemetry;
    localparam integer CLUSTERS=2;
    logic clk=0;always #1 clk=~clk;
    logic rst_n=0,clear=0,snapshot_req_valid,snapshot_req_ready;
    logic [3:0] expected_groups;
    logic [1:0] cluster_quiescent,cluster_faulted;
    logic [1:0] cluster_first_issue_valid,cluster_last_commit_valid;
    logic [127:0] cluster_first_issue_cycle,cluster_last_commit_cycle;
    logic [127:0] cluster_groups_accepted,cluster_groups_completed;
    logic [127:0] cluster_groups_aborted,cluster_group_wait_cycles;
    logic [127:0] cluster_output_stall_cycles,cluster_service_stall_cycles;
    logic [127:0] cluster_active_cycles;
    logic snapshot_valid,snapshot_ready;
    logic [127:0] snapshot_groups_accepted,snapshot_groups_completed;
    logic [127:0] snapshot_groups_aborted,snapshot_group_wait_cycles;
    logic [127:0] snapshot_output_stall_cycles,snapshot_service_stall_cycles;
    logic [127:0] snapshot_active_cycles;
    logic first_issue_valid,last_commit_valid,all_done;
    logic [63:0] first_issue_cycle,last_commit_cycle,groups_accepted;
    logic [63:0] groups_completed,groups_aborted,group_wait_cycles;
    logic [63:0] output_stall_cycles,service_stall_cycles,active_cycles;
    logic [578:0] held_snapshot;

    cats_r4_a4_telemetry #(.CLUSTERS(CLUSTERS)) dut(.*);

    initial begin
        snapshot_req_valid=0;snapshot_ready=0;expected_groups=8;
        cluster_quiescent=2'b11;cluster_faulted=0;
        cluster_first_issue_valid=2'b11;cluster_last_commit_valid=2'b11;
        cluster_first_issue_cycle={64'd120,64'd100};
        cluster_last_commit_cycle={64'd900,64'd850};
        cluster_groups_accepted={64'd4,64'd4};
        cluster_groups_completed={64'd4,64'd4};
        cluster_groups_aborted=0;
        cluster_group_wait_cycles={64'd20,64'd10};
        cluster_output_stall_cycles={64'd40,64'd30};
        cluster_service_stall_cycles={64'd60,64'd50};
        cluster_active_cycles={64'd800,64'd700};
        repeat(4)@(posedge clk);rst_n=1;@(negedge clk);
        snapshot_req_valid=1;@(posedge clk);@(negedge clk);
        snapshot_req_valid=0;
        cluster_groups_completed=0;cluster_first_issue_cycle=0;
        while(!snapshot_valid)@(posedge clk);
        if(!first_issue_valid||first_issue_cycle!=100||!last_commit_valid||
           last_commit_cycle!=900||groups_accepted!=8||groups_completed!=8||
           groups_aborted!=0||group_wait_cycles!=30||output_stall_cycles!=70||
           service_stall_cycles!=110||active_cycles!=1500||!all_done)
            $fatal(1,"telemetry reduction mismatch");
        held_snapshot={first_issue_valid,first_issue_cycle,last_commit_valid,
            last_commit_cycle,groups_accepted,groups_completed,groups_aborted,
            group_wait_cycles,output_stall_cycles,service_stall_cycles,
            active_cycles,all_done};
        repeat(3) begin
            @(posedge clk);
            if(!snapshot_valid||{first_issue_valid,first_issue_cycle,
               last_commit_valid,last_commit_cycle,groups_accepted,
               groups_completed,groups_aborted,group_wait_cycles,
               output_stall_cycles,service_stall_cycles,active_cycles,
               all_done}!==held_snapshot)
                $fatal(1,"telemetry changed under backpressure");
        end
        @(negedge clk);snapshot_ready=1;@(posedge clk);@(negedge clk);
        snapshot_ready=0;
        if(snapshot_valid||!snapshot_req_ready)
            $fatal(1,"telemetry did not return idle");

        // A coherent but faulted snapshot must never report transaction done.
        cluster_faulted=2'b10;
        cluster_groups_completed={64'd4,64'd3};
        @(negedge clk);snapshot_req_valid=1;@(posedge clk);@(negedge clk);
        snapshot_req_valid=0;
        cluster_faulted=0;cluster_groups_completed={64'd4,64'd4};
        while(!snapshot_valid)@(posedge clk);
        if(all_done||groups_completed!=7)
            $fatal(1,"faulted telemetry incorrectly reported all_done");
        @(negedge clk);clear=1;@(posedge clk);@(negedge clk);clear=0;
        if(snapshot_valid||!snapshot_req_ready||all_done)
            $fatal(1,"clear did not discard held telemetry snapshot");
        $display("PASS A4 TELEMETRY clusters=2 coherent_stall=3 fault_gating=1 clear=1 first=100 last=900 groups=8 active=1500");
        $finish;
    end
endmodule
