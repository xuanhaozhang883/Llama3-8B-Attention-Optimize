`timescale 1ns/1ps

// Coherent two-stage telemetry snapshot. Cross-cluster reductions operate only
// on captured cluster-local registers, never on live high-fanout counters.
module cats_r4_a4_telemetry #(
    parameter integer CLUSTERS = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic snapshot_req_valid,
    output logic snapshot_req_ready,
    input  logic [3:0] expected_groups,
    input  logic [CLUSTERS-1:0] cluster_quiescent,
    input  logic [CLUSTERS-1:0] cluster_faulted,
    input  logic [CLUSTERS-1:0] cluster_first_issue_valid,
    input  logic [CLUSTERS*64-1:0] cluster_first_issue_cycle,
    input  logic [CLUSTERS-1:0] cluster_last_commit_valid,
    input  logic [CLUSTERS*64-1:0] cluster_last_commit_cycle,
    input  logic [CLUSTERS*64-1:0] cluster_groups_accepted,
    input  logic [CLUSTERS*64-1:0] cluster_groups_completed,
    input  logic [CLUSTERS*64-1:0] cluster_groups_aborted,
    input  logic [CLUSTERS*64-1:0] cluster_group_wait_cycles,
    input  logic [CLUSTERS*64-1:0] cluster_output_stall_cycles,
    input  logic [CLUSTERS*64-1:0] cluster_service_stall_cycles,
    input  logic [CLUSTERS*64-1:0] cluster_active_cycles,
    output logic snapshot_valid,
    input  logic snapshot_ready,
    output logic [CLUSTERS*64-1:0] snapshot_groups_accepted,
    output logic [CLUSTERS*64-1:0] snapshot_groups_completed,
    output logic [CLUSTERS*64-1:0] snapshot_groups_aborted,
    output logic [CLUSTERS*64-1:0] snapshot_group_wait_cycles,
    output logic [CLUSTERS*64-1:0] snapshot_output_stall_cycles,
    output logic [CLUSTERS*64-1:0] snapshot_service_stall_cycles,
    output logic [CLUSTERS*64-1:0] snapshot_active_cycles,
    output logic first_issue_valid,
    output logic [63:0] first_issue_cycle,
    output logic last_commit_valid,
    output logic [63:0] last_commit_cycle,
    output logic [63:0] groups_accepted,
    output logic [63:0] groups_completed,
    output logic [63:0] groups_aborted,
    output logic [63:0] group_wait_cycles,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] service_stall_cycles,
    output logic [63:0] active_cycles,
    output logic all_done
);
    typedef enum logic [1:0] {ST_IDLE,ST_REDUCE,ST_HOLD} state_t;
    state_t state;
    logic [3:0] expected_groups_r;
    logic [CLUSTERS-1:0] quiescent_r,faulted_r;
    logic [CLUSTERS-1:0] first_valid_r,last_valid_r;
    logic [CLUSTERS*64-1:0] first_cycle_r,last_cycle_r;
    logic [63:0] sum_accepted,sum_completed,sum_aborted,sum_wait;
    logic [63:0] sum_output_stall,sum_service_stall,sum_active;
    logic min_valid,max_valid;
    logic [63:0] min_first,max_last;
    integer reduce_i;

    assign snapshot_req_ready=state==ST_IDLE;
    assign snapshot_valid=state==ST_HOLD;

    always_comb begin
        sum_accepted=0;sum_completed=0;sum_aborted=0;sum_wait=0;
        sum_output_stall=0;sum_service_stall=0;sum_active=0;
        min_valid=0;max_valid=0;min_first={64{1'b1}};max_last=0;
        for(reduce_i=0;reduce_i<CLUSTERS;reduce_i=reduce_i+1) begin
            sum_accepted=sum_accepted+snapshot_groups_accepted[reduce_i*64 +:64];
            sum_completed=sum_completed+snapshot_groups_completed[reduce_i*64 +:64];
            sum_aborted=sum_aborted+snapshot_groups_aborted[reduce_i*64 +:64];
            sum_wait=sum_wait+snapshot_group_wait_cycles[reduce_i*64 +:64];
            sum_output_stall=sum_output_stall+
                snapshot_output_stall_cycles[reduce_i*64 +:64];
            sum_service_stall=sum_service_stall+
                snapshot_service_stall_cycles[reduce_i*64 +:64];
            sum_active=sum_active+snapshot_active_cycles[reduce_i*64 +:64];
            if(first_valid_r[reduce_i]&&
               (!min_valid||first_cycle_r[reduce_i*64 +:64]<min_first)) begin
                min_valid=1;min_first=first_cycle_r[reduce_i*64 +:64];
            end
            if(last_valid_r[reduce_i]&&
               (!max_valid||last_cycle_r[reduce_i*64 +:64]>max_last)) begin
                max_valid=1;max_last=last_cycle_r[reduce_i*64 +:64];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=ST_IDLE;expected_groups_r<=0;quiescent_r<=0;faulted_r<=0;
            first_valid_r<=0;last_valid_r<=0;first_cycle_r<=0;last_cycle_r<=0;
            snapshot_groups_accepted<=0;snapshot_groups_completed<=0;
            snapshot_groups_aborted<=0;snapshot_group_wait_cycles<=0;
            snapshot_output_stall_cycles<=0;snapshot_service_stall_cycles<=0;
            snapshot_active_cycles<=0;first_issue_valid<=0;first_issue_cycle<=0;
            last_commit_valid<=0;last_commit_cycle<=0;groups_accepted<=0;
            groups_completed<=0;groups_aborted<=0;group_wait_cycles<=0;
            output_stall_cycles<=0;service_stall_cycles<=0;active_cycles<=0;
            all_done<=0;
        end else if(clear) begin
            state<=ST_IDLE;first_issue_valid<=0;last_commit_valid<=0;all_done<=0;
        end else begin
            case(state)
                ST_IDLE: if(snapshot_req_valid) begin
                    expected_groups_r<=expected_groups;
                    quiescent_r<=cluster_quiescent;faulted_r<=cluster_faulted;
                    first_valid_r<=cluster_first_issue_valid;
                    last_valid_r<=cluster_last_commit_valid;
                    first_cycle_r<=cluster_first_issue_cycle;
                    last_cycle_r<=cluster_last_commit_cycle;
                    snapshot_groups_accepted<=cluster_groups_accepted;
                    snapshot_groups_completed<=cluster_groups_completed;
                    snapshot_groups_aborted<=cluster_groups_aborted;
                    snapshot_group_wait_cycles<=cluster_group_wait_cycles;
                    snapshot_output_stall_cycles<=cluster_output_stall_cycles;
                    snapshot_service_stall_cycles<=cluster_service_stall_cycles;
                    snapshot_active_cycles<=cluster_active_cycles;
                    state<=ST_REDUCE;
                end
                ST_REDUCE: begin
                    first_issue_valid<=min_valid;first_issue_cycle<=min_first;
                    last_commit_valid<=max_valid;last_commit_cycle<=max_last;
                    groups_accepted<=sum_accepted;groups_completed<=sum_completed;
                    groups_aborted<=sum_aborted;group_wait_cycles<=sum_wait;
                    output_stall_cycles<=sum_output_stall;
                    service_stall_cycles<=sum_service_stall;
                    active_cycles<=sum_active;
                    all_done<=(&quiescent_r)&&!(|faulted_r)&&
                        sum_accepted==expected_groups_r&&
                        sum_completed==expected_groups_r&&sum_aborted==0;
                    state<=ST_HOLD;
                end
                ST_HOLD: if(snapshot_ready) state<=ST_IDLE;
                default: state<=ST_IDLE;
            endcase
        end
    end

    initial if(!(CLUSTERS==1||CLUSTERS==2||CLUSTERS==4))
        $error("cats_r4_a4_telemetry: CLUSTERS must be 1, 2, or 4");
endmodule

