`timescale 1ns/1ps

// Simulation-only AXI-stream FP32 models for the three Xilinx Floating Point IP
// instances used by the QK RTL. Exclude this file from synthesis. The models
// preserve independent A/B handshakes and output backpressure.
module fp32_axis_binary_model #(
    parameter bit IS_ADD = 1'b0,
    parameter int LATENCY = 2
) (
    input  logic        aclk,
    input  logic        aclken,
    input  logic        aresetn,
    input  logic        s_axis_a_tvalid,
    output logic        s_axis_a_tready,
    input  logic [31:0] s_axis_a_tdata,
    input  logic        s_axis_b_tvalid,
    output logic        s_axis_b_tready,
    input  logic [31:0] s_axis_b_tdata,
    output logic        m_axis_result_tvalid,
    input  logic        m_axis_result_tready,
    output logic [31:0] m_axis_result_tdata
);
    localparam int CW = (LATENCY <= 1) ? 1 : $clog2(LATENCY+1);

    logic        a_stored, b_stored;
    logic [31:0] a_bits, b_bits;
    logic        pending;
    logic [CW-1:0] countdown;
    logic        result_valid_reg;
    logic [31:0] result_bits_reg;

    function automatic real pow2_real(input integer exponent);
        real value; integer i;
        begin
            value = 1.0;
            if (exponent >= 0)
                for (i=0; i<exponent; i=i+1) value = value * 2.0;
            else
                for (i=0; i<(-exponent); i=i+1) value = value / 2.0;
            pow2_real = value;
        end
    endfunction

    function automatic real fp32_bits_to_real(input logic [31:0] bits);
        integer exponent; integer fraction; real mantissa; real value;
        begin
            exponent = bits[30:23]; fraction = bits[22:0];
            if (exponent == 0 && fraction == 0) value = 0.0;
            else if (exponent == 0) begin
                mantissa = fraction / 8388608.0;
                value = mantissa * pow2_real(-126);
            end else begin
                mantissa = 1.0 + fraction / 8388608.0;
                value = mantissa * pow2_real(exponent-127);
            end
            fp32_bits_to_real = bits[31] ? -value : value;
        end
    endfunction

    function automatic logic [31:0] real_to_fp32_bits(input real value_in);
        real value; real normalized; real fraction_real; real remainder_real;
        integer sign_bit; integer exponent_unbiased; integer exponent_biased;
        integer fraction_int;
        begin
            sign_bit = (value_in < 0.0);
            value = sign_bit ? -value_in : value_in;
            if (value == 0.0) begin
                real_to_fp32_bits = {sign_bit[0],31'd0};
            end else begin
                exponent_unbiased = 0; normalized = value;
                while (normalized >= 2.0) begin normalized = normalized/2.0; exponent_unbiased=exponent_unbiased+1; end
                while (normalized < 1.0) begin normalized = normalized*2.0; exponent_unbiased=exponent_unbiased-1; end
                exponent_biased = exponent_unbiased + 127;
                if (exponent_biased <= 0) begin
                    // The project data never approaches FP32 subnormal range.
                    real_to_fp32_bits = {sign_bit[0],31'd0};
                end else if (exponent_biased >= 255) begin
                    real_to_fp32_bits = {sign_bit[0],8'hff,23'd0};
                end else begin
                    fraction_real = (normalized-1.0)*8388608.0;
                    fraction_int = $rtoi(fraction_real);
                    remainder_real = fraction_real-fraction_int;
                    if ((remainder_real > 0.5) ||
                        ((remainder_real == 0.5) && (fraction_int & 1)))
                        fraction_int = fraction_int+1;
                    if (fraction_int >= 8388608) begin
                        fraction_int = 0; exponent_biased = exponent_biased+1;
                    end
                    real_to_fp32_bits = {sign_bit[0],exponent_biased[7:0],fraction_int[22:0]};
                end
            end
        end
    endfunction

    function automatic logic [31:0] calculate(
        input logic [31:0] a, input logic [31:0] b
    );
        real ra; real rb; real rr;
        begin
            ra = fp32_bits_to_real(a); rb = fp32_bits_to_real(b);
            rr = IS_ADD ? (ra+rb) : (ra*rb);
            calculate = real_to_fp32_bits(rr);
        end
    endfunction

    assign s_axis_a_tready = aclken && !pending && !result_valid_reg && !a_stored;
    assign s_axis_b_tready = aclken && !pending && !result_valid_reg && !b_stored;
    assign m_axis_result_tvalid = result_valid_reg;
    assign m_axis_result_tdata  = result_bits_reg;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            a_stored        <= 1'b0;
            b_stored        <= 1'b0;
            a_bits          <= '0;
            b_bits          <= '0;
            pending         <= 1'b0;
            countdown       <= '0;
            result_valid_reg <= 1'b0;
            result_bits_reg <= '0;
        end else if (aclken) begin
            if (result_valid_reg && m_axis_result_tready)
                result_valid_reg <= 1'b0;

            if (s_axis_a_tvalid && s_axis_a_tready) begin
                a_bits   <= s_axis_a_tdata;
                a_stored <= 1'b1;
            end
            if (s_axis_b_tvalid && s_axis_b_tready) begin
                b_bits   <= s_axis_b_tdata;
                b_stored <= 1'b1;
            end

            if (!pending && !result_valid_reg && a_stored && b_stored) begin
                result_bits_reg <= calculate(a_bits, b_bits);
                a_stored  <= 1'b0;
                b_stored  <= 1'b0;
                if (LATENCY <= 1) begin
                    result_valid_reg <= 1'b1;
                end else begin
                    pending   <= 1'b1;
                    countdown <= LATENCY-1;
                end
            end else if (pending) begin
                if (countdown <= 1) begin
                    pending          <= 1'b0;
                    countdown        <= '0;
                    result_valid_reg <= 1'b1;
                end else begin
                    countdown <= countdown - 1'b1;
                end
            end
        end
    end
endmodule

module floating_point_0 (
    input logic aclk, input logic aclken, input logic aresetn,
    input logic s_axis_a_tvalid, output logic s_axis_a_tready,
    input logic [31:0] s_axis_a_tdata,
    input logic s_axis_b_tvalid, output logic s_axis_b_tready,
    input logic [31:0] s_axis_b_tdata,
    output logic m_axis_result_tvalid, input logic m_axis_result_tready,
    output logic [31:0] m_axis_result_tdata
);
    fp32_axis_binary_model #(.IS_ADD(1'b0), .LATENCY(2)) u_model (.*);
endmodule

module floating_point_1 (
    input logic aclk, input logic aclken, input logic aresetn,
    input logic s_axis_a_tvalid, output logic s_axis_a_tready,
    input logic [31:0] s_axis_a_tdata,
    input logic s_axis_b_tvalid, output logic s_axis_b_tready,
    input logic [31:0] s_axis_b_tdata,
    output logic m_axis_result_tvalid, input logic m_axis_result_tready,
    output logic [31:0] m_axis_result_tdata
);
    fp32_axis_binary_model #(.IS_ADD(1'b1), .LATENCY(2)) u_model (.*);
endmodule

module floating_point_2 (
    input logic aclk, input logic aclken, input logic aresetn,
    input logic s_axis_a_tvalid, output logic s_axis_a_tready,
    input logic [31:0] s_axis_a_tdata,
    input logic s_axis_b_tvalid, output logic s_axis_b_tready,
    input logic [31:0] s_axis_b_tdata,
    output logic m_axis_result_tvalid, input logic m_axis_result_tready,
    output logic [31:0] m_axis_result_tdata
);
    fp32_axis_binary_model #(.IS_ADD(1'b0), .LATENCY(2)) u_model (.*);
endmodule
