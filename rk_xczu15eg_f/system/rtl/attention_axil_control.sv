`timescale 1ns/1ps

// AXI4-Lite control/status register bank for the production Attention engine.
module attention_axil_control #(
    parameter int ADDR_W = 8,
    parameter logic [31:0] BUILD_ID = 32'h524B0100
) (
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [ADDR_W-1:0]     s_axi_awaddr,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [31:0]           s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,
    input  logic [ADDR_W-1:0]     s_axi_araddr,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [31:0]           s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    output logic                  command_start_pulse,
    input  logic                  command_ready,
    input  logic                  engine_busy,
    input  logic                  engine_done_pulse,
    input  logic                  frame_loaded,
    input  logic                  protocol_error,
    input  logic [7:0]            error_vector,
    input  logic [63:0]           kernel_cycles,
    input  logic [63:0]           fifo_stall_cycles,
    input  logic [31:0]           input_beats,
    input  logic [31:0]           output_beats
);
    logic aw_pending;
    logic [ADDR_W-1:0] awaddr_reg;
    logic w_pending;
    logic [31:0] wdata_reg;
    logic [3:0] wstrb_reg;
    logic done_sticky;
    logic error_sticky;

    assign s_axi_awready = !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = !w_pending && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            aw_pending <= 1'b0;
            awaddr_reg <= '0;
            w_pending <= 1'b0;
            wdata_reg <= '0;
            wstrb_reg <= '0;
            s_axi_bvalid <= 1'b0;
            command_start_pulse <= 1'b0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
        end else begin
            command_start_pulse <= 1'b0;
            if (engine_done_pulse)
                done_sticky <= 1'b1;
            if (protocol_error)
                error_sticky <= 1'b1;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1'b1;
                awaddr_reg <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1'b1;
                wdata_reg <= s_axi_wdata;
                wstrb_reg <= s_axi_wstrb;
            end

            if (aw_pending && w_pending && !s_axi_bvalid) begin
                if ((awaddr_reg[7:2] == 6'h00) && wstrb_reg[0]) begin
                    if (wdata_reg[0])
                        command_start_pulse <= 1'b1;
                    if (wdata_reg[1]) begin
                        done_sticky <= 1'b0;
                        error_sticky <= 1'b0;
                    end
                end
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
        end else begin
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
            if (s_axi_arvalid && s_axi_arready) begin
                case (s_axi_araddr[7:2])
                    6'h00: s_axi_rdata <= 32'h00000000;
                    6'h01: s_axi_rdata <= {
                        26'd0,
                        error_sticky,
                        done_sticky,
                        protocol_error,
                        frame_loaded,
                        engine_busy,
                        command_ready
                    };
                    6'h02: s_axi_rdata <= kernel_cycles[31:0];
                    6'h03: s_axi_rdata <= kernel_cycles[63:32];
                    6'h04: s_axi_rdata <= input_beats;
                    6'h05: s_axi_rdata <= output_beats;
                    6'h06: s_axi_rdata <= fifo_stall_cycles[31:0];
                    6'h07: s_axi_rdata <= fifo_stall_cycles[63:32];
                    6'h08: s_axi_rdata <= BUILD_ID;
                    6'h09: s_axi_rdata <= {24'd0, error_vector};
                    default: s_axi_rdata <= 32'h00000000;
                endcase
                s_axi_rvalid <= 1'b1;
            end
        end
    end
endmodule
