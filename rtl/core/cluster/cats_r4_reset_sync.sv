`timescale 1ns/1ps

// Asynchronous assertion, synchronous deassertion reset synchronizer.
// Instantiate once in every CATS-R4 clock domain (core/AXI/GPIO).
module cats_r4_reset_sync #(
    parameter int STAGES = 3,
    parameter int HOLD_CYCLES = 16
) (
    input  logic clk,
    input  logic arst_n,
    output logic srst_n
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [STAGES-1:0] sync_pipe;
    localparam int HOLD_WIDTH = (HOLD_CYCLES <= 1) ? 1 :
                                $clog2(HOLD_CYCLES + 1);
    logic [HOLD_WIDTH-1:0] hold_count;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n)
        begin
            sync_pipe  <= '0;
            hold_count <= '0;
            srst_n     <= 1'b0;
        end else begin
            sync_pipe <= {sync_pipe[STAGES-2:0], 1'b1};
            if (!sync_pipe[STAGES-1]) begin
                hold_count <= '0;
                srst_n <= 1'b0;
            end else if (!srst_n) begin
                if (hold_count == HOLD_CYCLES-1)
                    srst_n <= 1'b1;
                else
                    hold_count <= hold_count + 1'b1;
            end
        end
    end

    initial begin
        if (STAGES < 2)
            $error("cats_r4_reset_sync: STAGES must be at least 2");
        if (HOLD_CYCLES < 16)
            $error("cats_r4_reset_sync: CATS_R4_IF_V1 requires at least 16 hold cycles");
    end
endmodule
