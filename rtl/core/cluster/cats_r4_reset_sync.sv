`timescale 1ns/1ps

// Asynchronous assertion, synchronous deassertion reset synchronizer.
// Instantiate once in every CATS-R4 clock domain (core/AXI/GPIO).
module cats_r4_reset_sync #(
    parameter int STAGES = 3
) (
    input  logic clk,
    input  logic arst_n,
    output logic srst_n
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [STAGES-1:0] sync_pipe;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync_pipe <= '0;
        else
            sync_pipe <= {sync_pipe[STAGES-2:0], 1'b1};
    end

    assign srst_n = sync_pipe[STAGES-1];

    initial begin
        if (STAGES < 2)
            $error("cats_r4_reset_sync: STAGES must be at least 2");
    end
endmodule
