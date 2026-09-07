`timescale 1ns/1ps

// Small behavioral XPM replacement used only by the Icarus contract test.
// It models the mixed-width 64-bit-write/16-bit-read and 16-bit-write/read
// configurations instantiated by cats_r4_qkv_axi_bank_bridge.  Vivado runs
// continue to use the vendor xpm library.
module xpm_memory_sdpram #(
    parameter integer ADDR_WIDTH_A = 9,
    parameter integer ADDR_WIDTH_B = 9,
    parameter integer BYTE_WRITE_WIDTH_A = 8,
    parameter string CLOCKING_MODE = "independent_clock",
    parameter string ECC_MODE = "no_ecc",
    parameter integer MEMORY_SIZE = 8192,
    parameter string MEMORY_PRIMITIVE = "block",
    parameter integer READ_DATA_WIDTH_B = 16,
    parameter integer READ_LATENCY_B = 2,
    parameter string WRITE_MODE_B = "read_first",
    parameter integer WRITE_DATA_WIDTH_A = 16,
    parameter integer AUTO_SLEEP_TIME = 0
) (
    input logic clka,
    input logic ena,
    input logic [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea,
    input logic [ADDR_WIDTH_A-1:0] addra,
    input logic [WRITE_DATA_WIDTH_A-1:0] dina,
    input logic injectsbiterra,
    input logic injectdbiterra,
    input logic sleep,
    input logic clkb,
    input logic enb,
    input logic [ADDR_WIDTH_B-1:0] addrb,
    output logic [READ_DATA_WIDTH_B-1:0] doutb,
    input logic regceb,
    output logic sbiterrb,
    output logic dbiterrb
);
    localparam integer WORDS16 = MEMORY_SIZE / 16;
    localparam integer LANES16 = WRITE_DATA_WIDTH_A / 16;
    logic [15:0] mem16 [0:WORDS16-1];
    logic [ADDR_WIDTH_B-1:0] addr_pipe [0:READ_LATENCY_B-1];
    logic valid_pipe [0:READ_LATENCY_B-1];
    integer i;
    integer base_word;

    initial begin
        doutb = '0;
        sbiterrb = 1'b0;
        dbiterrb = 1'b0;
        for (i = 0; i < READ_LATENCY_B; i = i + 1) begin
            addr_pipe[i] = '0;
            valid_pipe[i] = 1'b0;
        end
    end

    always_ff @(posedge clka) begin
        if (!sleep && ena) begin
            base_word = addra * LANES16;
            for (i = 0; i < LANES16; i = i + 1) begin
                if (wea[i*2 +: 2] != 2'b00)
                    mem16[base_word+i] <= dina[i*16 +: 16];
            end
        end
    end

    always_ff @(posedge clkb) begin
        if (!sleep) begin
            for (i = READ_LATENCY_B-1; i > 0; i = i - 1) begin
                valid_pipe[i] <= valid_pipe[i-1];
                addr_pipe[i] <= addr_pipe[i-1];
            end
            valid_pipe[0] <= enb && regceb;
            addr_pipe[0] <= addrb;
            if (valid_pipe[READ_LATENCY_B-1])
                doutb <= mem16[addr_pipe[READ_LATENCY_B-1]];
        end
    end
endmodule
