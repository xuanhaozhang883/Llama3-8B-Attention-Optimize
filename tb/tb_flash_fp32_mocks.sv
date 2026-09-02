`timescale 1ns/1ps

// Small exact mock used only by the controller regression.  Values are from a
// deliberately restricted quarter-unit set; production RTL binds the Xilinx
// single-precision Floating-Point IP through the real wrappers.
module pv_fp32_mul_ip (
    input logic clk, input logic rst_n,
    input logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    function automatic integer decode_q4(input logic [31:0] bits);
        begin
            case (bits)
                32'h00000000: decode_q4 = 0;
                32'h3E800000: decode_q4 = 1;
                32'h3F000000: decode_q4 = 2;
                32'h3F800000: decode_q4 = 4;
                32'h40000000: decode_q4 = 8;
                32'h40200000: decode_q4 = 10;
                32'h40400000: decode_q4 = 12;
                32'h40800000: decode_q4 = 16;
                32'h40A00000: decode_q4 = 20;
                32'h40C00000: decode_q4 = 24;
                32'h40E00000: decode_q4 = 28;
                32'h41000000: decode_q4 = 32;
                32'h41200000: decode_q4 = 40;
                default: begin
                    $fatal(1, "mock decode unsupported %08x", bits);
                    decode_q4 = 0;
                end
            endcase
        end
    endfunction
    function automatic logic [31:0] encode_q4(input integer value);
        begin
            case (value)
                0: encode_q4 = 32'h00000000;
                1: encode_q4 = 32'h3E800000;
                2: encode_q4 = 32'h3F000000;
                4: encode_q4 = 32'h3F800000;
                8: encode_q4 = 32'h40000000;
                10: encode_q4 = 32'h40200000;
                12: encode_q4 = 32'h40400000;
                16: encode_q4 = 32'h40800000;
                20: encode_q4 = 32'h40A00000;
                24: encode_q4 = 32'h40C00000;
                28: encode_q4 = 32'h40E00000;
                32: encode_q4 = 32'h41000000;
                40: encode_q4 = 32'h41200000;
                default: begin
                    $fatal(1, "mock encode unsupported q4=%0d", value);
                    encode_q4 = 0;
                end
            endcase
        end
    endfunction
    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin result_valid <= 0; result_data <= 0; end
        else begin
            if (result_valid && result_ready) result_valid <= 0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                // The real-QK integration case normalizes an accumulated 8.0
                // numerator by the exact 1/8 reciprocal.  Keep that one
                // eighth-unit case exact without widening the original q4
                // controller model used by the other regressions.
                if (((a_data == 32'h3E000000) &&
                     (b_data == 32'h41000000)) ||
                    ((b_data == 32'h3E000000) &&
                     (a_data == 32'h41000000)))
                    result_data <= 32'h3F800000;
                else
                    result_data <= encode_q4(
                        (decode_q4(a_data)*decode_q4(b_data))/4
                    );
                result_valid <= 1;
            end
        end
    end
endmodule

module pv_fp32_add_ip (
    input logic clk, input logic rst_n,
    input logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    function automatic integer decode_q4(input logic [31:0] bits);
        begin
            case (bits)
                32'h00000000: decode_q4 = 0;
                32'h3E800000: decode_q4 = 1;
                32'h3F000000: decode_q4 = 2;
                32'h3F800000: decode_q4 = 4;
                32'h40000000: decode_q4 = 8;
                32'h40200000: decode_q4 = 10;
                32'h40400000: decode_q4 = 12;
                32'h40800000: decode_q4 = 16;
                32'h40A00000: decode_q4 = 20;
                32'h40C00000: decode_q4 = 24;
                32'h40E00000: decode_q4 = 28;
                32'h41000000: decode_q4 = 32;
                32'h41200000: decode_q4 = 40;
                default: begin
                    $fatal(1, "mock add decode unsupported %08x", bits);
                    decode_q4 = 0;
                end
            endcase
        end
    endfunction
    function automatic logic [31:0] encode_q4(input integer value);
        begin
            case (value)
                0: encode_q4 = 32'h00000000;
                4: encode_q4 = 32'h3F800000;
                8: encode_q4 = 32'h40000000;
                12: encode_q4 = 32'h40400000;
                16: encode_q4 = 32'h40800000;
                20: encode_q4 = 32'h40A00000;
                24: encode_q4 = 32'h40C00000;
                28: encode_q4 = 32'h40E00000;
                32: encode_q4 = 32'h41000000;
                40: encode_q4 = 32'h41200000;
                default: begin
                    $fatal(1, "mock add encode unsupported q4=%0d", value);
                    encode_q4 = 0;
                end
            endcase
        end
    endfunction
    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin result_valid <= 0; result_data <= 0; end
        else begin
            if (result_valid && result_ready) result_valid <= 0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                result_data <= encode_q4(decode_q4(a_data)+decode_q4(b_data));
                result_valid <= 1;
            end
        end
    end
endmodule
