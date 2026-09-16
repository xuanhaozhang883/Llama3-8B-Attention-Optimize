`timescale 1ns/1ps

module tb_cats_r4_a4_finite_output;
    localparam integer DEPTH = 512*4;
    logic clk=0,rst_n=0,clear=0,global_halt=0,sink_ready=0;
    logic [1:0] context_valid,context_ready;
    logic sink_valid,sink_source;
    logic [2:0] sink_beat;
    logic [1:0][11:0] occupancy;
    logic [1:0][63:0] chunks_accepted,chunks_drained;
    logic [63:0] sink_beats_accepted;
    logic sink_idle;

    always #5 clk=~clk;

    tb_cats_r4_a4_finite_output_model dut(
        .clk,.rst_n,.clear,.global_halt,.context_valid,.context_ready,
        .sink_ready,.sink_valid,.sink_source,.sink_beat,.occupancy,
        .chunks_accepted,.chunks_drained,.sink_beats_accepted,.sink_idle
    );

    task automatic push_cluster(input integer cluster, input integer count);
        integer n;
        begin
            context_valid = '0;
            context_valid[cluster] = 1'b1;
            for(n=0;n<count;n=n+1) begin
                do @(posedge clk); while(!context_ready[cluster]);
            end
            @(negedge clk); context_valid = '0;
        end
    endtask

    initial begin
        context_valid='0;
        repeat(3) @(posedge clk);
        rst_n=1;
        @(negedge clk);

        // A full cluster-0 spool must not block the independent cluster-1 ingress.
        push_cluster(0,DEPTH);
        if(occupancy[0] != DEPTH || context_ready[0] || !context_ready[1])
            $fatal(1,"local full-spool isolation failed occ0=%0d ready=%b",occupancy[0],context_ready);
        push_cluster(1,1);
        if(occupancy[1] != 1 || chunks_accepted[0] != DEPTH || chunks_accepted[1] != 1)
            $fatal(1,"independent cluster ingress accounting failed");

        // Global halt blocks both ingresses but preserves already accepted work.
        global_halt=1;
        @(posedge clk); @(negedge clk);
        if(context_ready != 0 || occupancy[0] != DEPTH || occupancy[1] != 1)
            $fatal(1,"global halt ingress gate failed");
        global_halt=0;

        // One shared 64-bit sink beat is accepted per cycle; every chunk is 8 beats.
        sink_ready=1;
        wait(sink_idle);
        @(negedge clk);
        if(chunks_drained[0] != DEPTH || chunks_drained[1] != 1)
            $fatal(1,"drained chunk totals mismatch");
        if(sink_beats_accepted != (DEPTH+1)*8)
            $fatal(1,"shared sink beat total mismatch got=%0d",sink_beats_accepted);
        if(occupancy != 0)
            $fatal(1,"spools not empty after drain");

        clear=1; @(posedge clk); @(negedge clk); clear=0;
        if(!sink_idle || chunks_accepted != 0 || chunks_drained != 0 ||
           sink_beats_accepted != 0)
            $fatal(1,"clear did not reset finite output model");

        $display("PASS A4 FINITE OUTPUT clusters=2 rows_per_cluster=512 chunks_per_spool=2048 shared_sink_bits=64 beats_per_chunk=8 local_full_isolation=1 halt=1 clear=1");
        $finish;
    end

    initial begin
        repeat(25000) @(posedge clk);
        $fatal(1,"finite output model timeout");
    end
endmodule
