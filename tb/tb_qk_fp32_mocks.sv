`timescale 1ns/1ps

// Exact eighth-unit FP32 model for QK controller simulation.  This file
// replaces only the vendor FP wrappers; the QK scheduler, tile, PE and scaler
// are the production RTL.
module fp32_mul_ip #(
    parameter IP_ID = 0
)(
    input  logic clk, input logic rst_n,
    input  logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input  logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    function automatic integer decode_e8(input logic [31:0] bits);
        begin
            case (bits)
                32'h00000000: decode_e8 = 0;
                32'h3E000000: decode_e8 = 1;
                32'h3F800000: decode_e8 = 8;
                32'h40000000: decode_e8 = 16;
                32'h40400000: decode_e8 = 24;
                32'h40800000: decode_e8 = 32;
                32'h40A00000: decode_e8 = 40;
                32'h40C00000: decode_e8 = 48;
                32'h40E00000: decode_e8 = 56;
                32'h41000000: decode_e8 = 64;
                default: begin
                    $fatal(1, "QK mock mul decode unsupported %08x", bits);
                    decode_e8 = 0;
                end
            endcase
        end
    endfunction

    function automatic logic [31:0] encode_e8(input integer value);
        begin
            case (value)
                0:  encode_e8 = 32'h00000000;
                1:  encode_e8 = 32'h3E000000;
                8:  encode_e8 = 32'h3F800000;
                16: encode_e8 = 32'h40000000;
                24: encode_e8 = 32'h40400000;
                32: encode_e8 = 32'h40800000;
                40: encode_e8 = 32'h40A00000;
                48: encode_e8 = 32'h40C00000;
                56: encode_e8 = 32'h40E00000;
                64: encode_e8 = 32'h41000000;
                default: begin
                    $fatal(1, "QK mock mul encode unsupported e8=%0d", value);
                    encode_e8 = 32'h00000000;
                end
            endcase
        end
    endfunction

    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result_data <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                result_data <= encode_e8(
                    (decode_e8(a_data) * decode_e8(b_data)) / 8
                );
                result_valid <= 1'b1;
            end
        end
    end

    logic unused_ip_id;
    assign unused_ip_id = IP_ID[0];
endmodule

module fp32_add_ip (
    input  logic clk, input logic rst_n,
    input  logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input  logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    function automatic integer decode_e8(input logic [31:0] bits);
        begin
            case (bits)
                32'h00000000: decode_e8 = 0;
                32'h3F800000: decode_e8 = 8;
                32'h40000000: decode_e8 = 16;
                32'h40400000: decode_e8 = 24;
                32'h40800000: decode_e8 = 32;
                32'h40A00000: decode_e8 = 40;
                32'h40C00000: decode_e8 = 48;
                32'h40E00000: decode_e8 = 56;
                32'h41000000: decode_e8 = 64;
                default: begin
                    $fatal(1, "QK mock add decode unsupported %08x", bits);
                    decode_e8 = 0;
                end
            endcase
        end
    endfunction

    function automatic logic [31:0] encode_e8(input integer value);
        begin
            case (value)
                0:  encode_e8 = 32'h00000000;
                8:  encode_e8 = 32'h3F800000;
                16: encode_e8 = 32'h40000000;
                24: encode_e8 = 32'h40400000;
                32: encode_e8 = 32'h40800000;
                40: encode_e8 = 32'h40A00000;
                48: encode_e8 = 32'h40C00000;
                56: encode_e8 = 32'h40E00000;
                64: encode_e8 = 32'h41000000;
                default: begin
                    $fatal(1, "QK mock add encode unsupported e8=%0d", value);
                    encode_e8 = 32'h00000000;
                end
            endcase
        end
    endfunction

    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result_data <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                result_data <= encode_e8(decode_e8(a_data)+decode_e8(b_data));
                result_valid <= 1'b1;
            end
        end
    end
endmodule
