module exp_lut #(
    parameter INIT_FILE = "exp_lut_q15.mem"
) (
    input  logic [9:0]  addr,   // 0..512, corresponding to x = -addr/64
    output logic [15:0] data    // unsigned Q1.15, exp(x)
);

    (* rom_style = "distributed" *) logic [15:0] rom [0:512];

    initial begin
        $readmemh(INIT_FILE, rom);
    end

    always_comb begin
        if (addr <= 10'd512)
            data = rom[addr];
        else
            data = 16'd0;
    end

endmodule
