`timescale 1ns/1ps

// Deterministic eighth-unit binary32 models for B3 controller/service tests.
// They intentionally support only the directed finite values used by the TB.
module fp32_mul_ip #(
    parameter IP_ID = 0
) (
    input logic clk, input logic rst_n,
    input logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    function automatic integer decode_e8(input logic [31:0] bits);
        begin
            case (bits)
                32'h00000000: decode_e8 = 0;
                32'h3E000000: decode_e8 = 1;
                32'h3E800000: decode_e8 = 2;
                32'h3F000000: decode_e8 = 4;
                32'h3F800000: decode_e8 = 8;
                32'h40000000: decode_e8 = 16;
                32'h40400000: decode_e8 = 24;
                32'h40800000: decode_e8 = 32;
                32'h40A00000: decode_e8 = 40;
                32'h40C00000: decode_e8 = 48;
                32'h40E00000: decode_e8 = 56;
                32'h41000000: decode_e8 = 64;
                default: begin
                    $fatal(1, "B3 mock mul decode unsupported %08x", bits);
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
                2:  encode_e8 = 32'h3E800000;
                4:  encode_e8 = 32'h3F000000;
                8:  encode_e8 = 32'h3F800000;
                16: encode_e8 = 32'h40000000;
                24: encode_e8 = 32'h40400000;
                32: encode_e8 = 32'h40800000;
                40: encode_e8 = 32'h40A00000;
                48: encode_e8 = 32'h40C00000;
                56: encode_e8 = 32'h40E00000;
                64: encode_e8 = 32'h41000000;
                default: begin
                    $fatal(1, "B3 mock mul encode unsupported e8=%0d", value);
                    encode_e8 = 0;
                end
            endcase
        end
    endfunction

    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 0;
            result_data <= 0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                result_valid <= 1;
                result_data <= encode_e8(
                    (decode_e8(a_data) * decode_e8(b_data)) / 8);
            end
        end
    end
    logic unused;
    assign unused = IP_ID[0];
endmodule

module fp32_add_ip (
    input logic clk, input logic rst_n,
    input logic a_valid, output logic a_ready, input logic [31:0] a_data,
    input logic b_valid, output logic b_ready, input logic [31:0] b_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data
);
    function automatic integer decode_e8(input logic [31:0] bits);
        begin
            case (bits)
                32'h00000000: decode_e8 = 0;
                32'h3E000000: decode_e8 = 1;
                32'h3E800000: decode_e8 = 2;
                32'h3F000000: decode_e8 = 4;
                32'h3F800000: decode_e8 = 8;
                32'h40000000: decode_e8 = 16;
                32'h40400000: decode_e8 = 24;
                32'h40800000: decode_e8 = 32;
                32'h40A00000: decode_e8 = 40;
                32'h40C00000: decode_e8 = 48;
                32'h40E00000: decode_e8 = 56;
                32'h41000000: decode_e8 = 64;
                default: begin
                    $fatal(1, "B3 mock add decode unsupported %08x", bits);
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
                2:  encode_e8 = 32'h3E800000;
                4:  encode_e8 = 32'h3F000000;
                8:  encode_e8 = 32'h3F800000;
                16: encode_e8 = 32'h40000000;
                24: encode_e8 = 32'h40400000;
                32: encode_e8 = 32'h40800000;
                40: encode_e8 = 32'h40A00000;
                48: encode_e8 = 32'h40C00000;
                56: encode_e8 = 32'h40E00000;
                64: encode_e8 = 32'h41000000;
                default: begin
                    $fatal(1, "B3 mock add encode unsupported e8=%0d", value);
                    encode_e8 = 0;
                end
            endcase
        end
    endfunction

    assign a_ready = !result_valid || result_ready;
    assign b_ready = a_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_valid <= 0;
            result_data <= 0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 0;
            if (a_valid && b_valid && a_ready && b_ready) begin
                result_valid <= 1;
                result_data <= encode_e8(decode_e8(a_data)+decode_e8(b_data));
            end
        end
    end
endmodule
