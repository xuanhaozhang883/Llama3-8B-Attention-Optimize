`timescale 1ns/1ps

// Resource-first RoPE pair engine. One FP multiplier IP and one FP adder IP
// are time-shared across 4 multiplies and 2 add/subtracts. Products are
// rounded to BF16 before addition, preserving the staged-BF16 boundary.
module rope_pair_pipeline (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    output logic in_ready,
    input  logic [15:0] in_x0,
    input  logic [15:0] in_x1,
    input  logic [15:0] in_sin,
    input  logic [15:0] in_cos,
    output logic out_valid,
    input  logic out_ready,
    output logic [15:0] out_y0,
    output logic [15:0] out_y1
);
    typedef enum logic [2:0] {
        S_IDLE, S_MUL_SEND, S_MUL_WAIT, S_ADD_SEND,
        S_ADD_WAIT, S_OUTPUT
    } state_t;
    state_t state;
    logic [15:0] x0_reg, x1_reg, sin_reg, cos_reg;
    logic [15:0] product [0:3];
    logic [1:0] mul_index;
    logic add_index;

    logic mul_a_valid, mul_a_ready, mul_b_valid, mul_b_ready;
    logic [31:0] mul_a_data, mul_b_data, mul_result_data;
    logic mul_result_valid, mul_result_ready;
    logic [15:0] mul_result_bf16;
    logic add_a_valid, add_a_ready, add_b_valid, add_b_ready;
    logic [31:0] add_a_data, add_b_data, add_result_data;
    logic add_result_valid, add_result_ready;
    logic [15:0] add_result_bf16;

    assign in_ready = (state == S_IDLE);
    assign mul_result_ready = (state == S_MUL_WAIT);
    assign add_result_ready = (state == S_ADD_WAIT);

    always_comb begin
        case (mul_index)
            0: begin mul_a_data={x0_reg,16'b0}; mul_b_data={cos_reg,16'b0}; end
            1: begin mul_a_data={x1_reg,16'b0}; mul_b_data={sin_reg,16'b0}; end
            2: begin mul_a_data={x0_reg,16'b0}; mul_b_data={sin_reg,16'b0}; end
            default: begin mul_a_data={x1_reg,16'b0}; mul_b_data={cos_reg,16'b0}; end
        endcase
    end

    fp32_mul_ip #(.IP_ID(0)) u_rope_mul (
        .clk,.rst_n,.a_valid(mul_a_valid),.a_ready(mul_a_ready),.a_data(mul_a_data),
        .b_valid(mul_b_valid),.b_ready(mul_b_ready),.b_data(mul_b_data),
        .result_valid(mul_result_valid),.result_ready(mul_result_ready),
        .result_data(mul_result_data)
    );
    fp32_to_bf16 u_mul_round (.fp32_in(mul_result_data),.bf16_out(mul_result_bf16));

    fp32_add_ip u_rope_add (
        .clk,.rst_n,.a_valid(add_a_valid),.a_ready(add_a_ready),.a_data(add_a_data),
        .b_valid(add_b_valid),.b_ready(add_b_ready),.b_data(add_b_data),
        .result_valid(add_result_valid),.result_ready(add_result_ready),
        .result_data(add_result_data)
    );
    fp32_to_bf16 u_add_round (.fp32_in(add_result_data),.bf16_out(add_result_bf16));

    integer p;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=S_IDLE; x0_reg<='0; x1_reg<='0; sin_reg<='0; cos_reg<='0;
            mul_index<='0; add_index<=1'b0;
            mul_a_valid<=1'b0; mul_b_valid<=1'b0;
            add_a_valid<=1'b0; add_b_valid<=1'b0;
            add_a_data<='0; add_b_data<='0;
            out_valid<=1'b0; out_y0<='0; out_y1<='0;
            for(p=0;p<4;p=p+1) product[p]<='0;
        end else begin
            case (state)
                S_IDLE: begin
                    out_valid<=1'b0;
                    if(in_valid && in_ready) begin
                        x0_reg<=in_x0; x1_reg<=in_x1;
                        sin_reg<=in_sin; cos_reg<=in_cos;
                        mul_index<=0; mul_a_valid<=1'b1; mul_b_valid<=1'b1;
                        state<=S_MUL_SEND;
                    end
                end
                S_MUL_SEND: begin
                    if(mul_a_valid && mul_a_ready) mul_a_valid<=1'b0;
                    if(mul_b_valid && mul_b_ready) mul_b_valid<=1'b0;
                    if((!mul_a_valid || mul_a_ready) &&
                       (!mul_b_valid || mul_b_ready)) state<=S_MUL_WAIT;
                end
                S_MUL_WAIT: if(mul_result_valid && mul_result_ready) begin
                    product[mul_index]<=mul_result_bf16;
                    if(mul_index==3) begin
                        add_index<=1'b0;
                        add_a_data<={product[0],16'b0};
                        add_b_data<={{~product[1][15],product[1][14:0]},16'b0};
                        add_a_valid<=1'b1; add_b_valid<=1'b1;
                        state<=S_ADD_SEND;
                    end else begin
                        mul_index<=mul_index+1'b1;
                        mul_a_valid<=1'b1; mul_b_valid<=1'b1;
                        state<=S_MUL_SEND;
                    end
                end
                S_ADD_SEND: begin
                    if(add_a_valid && add_a_ready) add_a_valid<=1'b0;
                    if(add_b_valid && add_b_ready) add_b_valid<=1'b0;
                    if((!add_a_valid || add_a_ready) &&
                       (!add_b_valid || add_b_ready)) state<=S_ADD_WAIT;
                end
                S_ADD_WAIT: if(add_result_valid && add_result_ready) begin
                    if(!add_index) begin
                        out_y0<=add_result_bf16;
                        add_index<=1'b1;
                        add_a_data<={product[2],16'b0};
                        add_b_data<={product[3],16'b0};
                        add_a_valid<=1'b1; add_b_valid<=1'b1;
                        state<=S_ADD_SEND;
                    end else begin
                        out_y1<=add_result_bf16;
                        out_valid<=1'b1;
                        state<=S_OUTPUT;
                    end
                end
                S_OUTPUT: if(out_valid && out_ready) begin
                    out_valid<=1'b0;
                    state<=S_IDLE;
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
