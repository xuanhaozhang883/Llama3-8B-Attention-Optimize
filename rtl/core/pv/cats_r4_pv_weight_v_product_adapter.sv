`timescale 1ns/1ps

// CATS-R4 PV weight x 32-lane V feature adapter.
// It consumes one ordered FP32 weight, requests one aligned 32-lane BF16 V
// feature block, and emits 32 FP32 products to the ordered accumulator.
// The V request/response channel is compatible with bf16_v_cache and the
// cluster V service. Verification/integration candidate only.
module cats_r4_pv_weight_v_product_adapter #(
    parameter int LANES = 32
) (
    input logic clk,input logic rst_n,input logic clear,
    input logic weight_valid,output logic weight_ready,input logic [6:0] weight_key,
    input logic [1:0] weight_feature_block,input logic [31:0] weight_fp32,
    input logic weight_last,
    output logic v_req_valid,input logic v_req_ready,output logic [6:0] v_req_key,
    output logic [1:0] v_req_feature_block,
    input logic v_rsp_valid,input logic [511:0] v_rsp_vec,
    output logic product_valid,input logic product_ready,output logic [6:0] product_key,
    output logic [1:0] product_feature_block,output logic [LANES*32-1:0] product_fp32,
    output logic product_last,output logic [63:0] weight_accept_count,v_request_count,
    output logic [63:0] product_emit_count,output logic [63:0] protocol_error_count
);
    typedef enum logic [2:0] {IDLE,V_REQ,V_WAIT,MUL_SEND,MUL_WAIT,OUT} state_t;
    state_t state; logic [6:0] key_reg; logic [1:0] block_reg; logic last_reg; logic [31:0] weight_reg;
    logic [511:0] v_reg; logic [31:0] products[0:LANES-1];
    logic [LANES-1:0] mul_a_valid,mul_b_valid,mul_a_ready,mul_b_ready,mul_result_valid,mul_result_ready;
    logic [31:0] mul_result_data[0:LANES-1]; integer i;
    genvar g;
    generate for(g=0;g<LANES;g=g+1) begin:gen_mul
        pv_fp32_mul_ip u_mul(.clk,.rst_n,.a_valid(mul_a_valid[g]),.a_ready(mul_a_ready[g]),.a_data(weight_reg),.b_valid(mul_b_valid[g]),.b_ready(mul_b_ready[g]),.b_data({v_reg[g*16 +:16],16'd0}),.result_valid(mul_result_valid[g]),.result_ready(mul_result_ready[g]),.result_data(mul_result_data[g]));
    end endgenerate
    always_comb begin
        weight_ready=(state==IDLE); v_req_valid=(state==V_REQ); v_req_key=key_reg; v_req_feature_block=block_reg;
        product_valid=(state==OUT); product_key=key_reg; product_feature_block=block_reg; product_last=last_reg; product_fp32='0;
        for(i=0;i<LANES;i=i+1) begin
            mul_a_valid[i]=(state==MUL_SEND); mul_b_valid[i]=(state==MUL_SEND);
            mul_result_ready[i]=(state==MUL_WAIT); product_fp32[i*32 +:32]=products[i];
        end
    end
    always_ff @(posedge clk) begin
      if(!rst_n||clear) begin state<=IDLE;key_reg<='0;block_reg<='0;last_reg<=0;weight_reg<='0;v_reg<='0;for(i=0;i<LANES;i=i+1)products[i]<='0;weight_accept_count<='0;v_request_count<='0;product_emit_count<='0;protocol_error_count<='0;end
      else case(state)
       IDLE:if(weight_valid&&weight_ready)begin key_reg<=weight_key;block_reg<=weight_feature_block;last_reg<=weight_last;weight_reg<=weight_fp32;weight_accept_count<=weight_accept_count+1'b1;state<=V_REQ;end
       V_REQ:if(v_req_valid&&v_req_ready)begin v_request_count<=v_request_count+1'b1;state<=V_WAIT;end
       V_WAIT:if(v_rsp_valid)begin v_reg<=v_rsp_vec;state<=MUL_SEND;end
       MUL_SEND:begin if ((&mul_a_ready) && (&mul_b_ready))state<=MUL_WAIT;end
       MUL_WAIT:begin for(i=0;i<LANES;i=i+1)if(mul_result_valid[i])products[i]<=mul_result_data[i]; if(&mul_result_valid)state<=OUT;end
       OUT:if(product_valid&&product_ready)begin product_emit_count<=product_emit_count+1'b1;state<=IDLE;end
       default:state<=IDLE;
      endcase
    end
    initial if(LANES!=32)$error("cats_r4_pv_weight_v_product_adapter requires LANES=32");
endmodule