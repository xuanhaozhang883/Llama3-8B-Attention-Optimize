`timescale 1ns/1ps

// One-write/one-read, common-clock memory used for wide AXI beat storage.
// Vivado synthesis is pinned to XPM block RAM so inference changes cannot
// silently consume LUTs.  The generic branch exists only for syntax tools;
// no behavioral simulation is launched by the RK system build.
module rk_xpm_sdpram #(
    parameter int DATA_WIDTH = 128,
    parameter int DEPTH = 2048,
    parameter int ADDR_WIDTH = ((DEPTH <= 1) ? 1 : $clog2(DEPTH))
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  write_enable,
    input  logic [ADDR_WIDTH-1:0] write_address,
    input  logic [DATA_WIDTH-1:0] write_data,
    input  logic                  read_enable,
    input  logic [ADDR_WIDTH-1:0] read_address,
    output logic [DATA_WIDTH-1:0] read_data
);
`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .MEMORY_SIZE(DATA_WIDTH * DEPTH),
        .MEMORY_PRIMITIVE("block"),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM(""),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .AUTO_SLEEP_TIME(0),
        .MESSAGE_CONTROL(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .MEMORY_OPTIMIZATION("true"),
        .CASCADE_HEIGHT(0),
        .SIM_ASSERT_CHK(0),
        .WRITE_PROTECT(1),
        .WRITE_DATA_WIDTH_A(DATA_WIDTH),
        .BYTE_WRITE_WIDTH_A(DATA_WIDTH),
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .RST_MODE_A("SYNC"),
        .READ_DATA_WIDTH_B(DATA_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .READ_RESET_VALUE_B("0"),
        .READ_LATENCY_B(1),
        .WRITE_MODE_B("read_first"),
        .RST_MODE_B("SYNC")
    ) u_xpm_memory (
        .sleep(1'b0),
        .clka(clk),
        .ena(write_enable),
        .wea(write_enable),
        .addra(write_address),
        .dina(write_data),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .clkb(clk),
        .rstb(rst),
        .enb(read_enable),
        .regceb(1'b1),
        .addrb(read_address),
        .doutb(read_data),
        .sbiterrb(),
        .dbiterrb()
    );
`else
    logic [DATA_WIDTH-1:0] memory [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (rst)
            read_data <= '0;
        else if (read_enable)
            read_data <= memory[read_address];
    end
`endif
endmodule
