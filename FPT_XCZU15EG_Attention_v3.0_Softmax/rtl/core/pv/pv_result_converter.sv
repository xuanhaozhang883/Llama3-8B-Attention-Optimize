`timescale 1ns/1ps

// ============================================================================
// pv_result_converter
// ----------------------------------------------------------------------------
// Shared tile output unit for PV.
// Unlike QK, PV does NOT multiply by 1/sqrt(head_dim). It only converts the
// completed raw FP32 accumulation to BF16 RNE and holds the output until ready.
// ============================================================================
module pv_result_converter (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] raw_sum_fp32,

    output logic        out_valid,
    input  logic        out_ready,
    output logic [15:0] context_bf16,
    output logic [31:0] context_fp32_debug
);

    typedef enum logic {
        S_IDLE = 1'b0,
        S_OUT  = 1'b1
    } state_t;

    state_t state;
    logic [31:0] raw_sum_reg;

    assign in_ready           = (state == S_IDLE);
    assign context_fp32_debug = raw_sum_reg;

    pv_fp32_to_bf16 u_fp32_to_bf16 (
        .fp32_in  (raw_sum_reg),
        .bf16_out (context_bf16)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            raw_sum_reg <= 32'h00000000;
            out_valid   <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    out_valid <= 1'b0;

                    if (in_valid && in_ready) begin
                        raw_sum_reg <= raw_sum_fp32;
                        out_valid   <= 1'b1;
                        state       <= S_OUT;
                    end
                end

                S_OUT: begin
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
