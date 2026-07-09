// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2025.2 (64-bit)
// Tool Version Limit: 2025.11
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
/***************************** Include Files *********************************/
#include "xattention_mask.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XAttention_mask_CfgInitialize(XAttention_mask *InstancePtr, XAttention_mask_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XAttention_mask_Start(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL) & 0x80;
    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XAttention_mask_IsDone(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XAttention_mask_IsIdle(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XAttention_mask_IsReady(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XAttention_mask_EnableAutoRestart(XAttention_mask *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XAttention_mask_DisableAutoRestart(XAttention_mask *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_AP_CTRL, 0);
}

void XAttention_mask_Set_raw_scores(XAttention_mask *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_RAW_SCORES_DATA, (u32)(Data));
    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_RAW_SCORES_DATA + 4, (u32)(Data >> 32));
}

u64 XAttention_mask_Get_raw_scores(XAttention_mask *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_RAW_SCORES_DATA);
    Data += (u64)XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_RAW_SCORES_DATA + 4) << 32;
    return Data;
}

void XAttention_mask_Set_masked_scores(XAttention_mask *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_MASKED_SCORES_DATA, (u32)(Data));
    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_MASKED_SCORES_DATA + 4, (u32)(Data >> 32));
}

u64 XAttention_mask_Get_masked_scores(XAttention_mask *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_MASKED_SCORES_DATA);
    Data += (u64)XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_MASKED_SCORES_DATA + 4) << 32;
    return Data;
}

void XAttention_mask_Set_q_heads(XAttention_mask *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_Q_HEADS_DATA, Data);
}

u32 XAttention_mask_Get_q_heads(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_Q_HEADS_DATA);
    return Data;
}

void XAttention_mask_Set_seq_len(XAttention_mask *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_SEQ_LEN_DATA, Data);
}

u32 XAttention_mask_Get_seq_len(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_SEQ_LEN_DATA);
    return Data;
}

void XAttention_mask_Set_causal(XAttention_mask *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_CAUSAL_DATA, Data);
}

u32 XAttention_mask_Get_causal(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_CAUSAL_DATA);
    return Data;
}

void XAttention_mask_Set_mask_value(XAttention_mask *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_MASK_VALUE_DATA, Data);
}

u32 XAttention_mask_Get_mask_value(XAttention_mask *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_MASK_VALUE_DATA);
    return Data;
}

void XAttention_mask_InterruptGlobalEnable(XAttention_mask *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_GIE, 1);
}

void XAttention_mask_InterruptGlobalDisable(XAttention_mask *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_GIE, 0);
}

void XAttention_mask_InterruptEnable(XAttention_mask *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_IER);
    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_IER, Register | Mask);
}

void XAttention_mask_InterruptDisable(XAttention_mask *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_IER);
    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_IER, Register & (~Mask));
}

void XAttention_mask_InterruptClear(XAttention_mask *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XAttention_mask_WriteReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_ISR, Mask);
}

u32 XAttention_mask_InterruptGetEnabled(XAttention_mask *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_IER);
}

u32 XAttention_mask_InterruptGetStatus(XAttention_mask *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XAttention_mask_ReadReg(InstancePtr->Control_BaseAddress, XATTENTION_MASK_CONTROL_ADDR_ISR);
}

