// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2025.2 (64-bit)
// Tool Version Limit: 2025.11
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
#ifndef XATTENTION_MASK_H
#define XATTENTION_MASK_H

#ifdef __cplusplus
extern "C" {
#endif

/***************************** Include Files *********************************/
#ifndef __linux__
#include "xil_types.h"
#include "xil_assert.h"
#include "xstatus.h"
#include "xil_io.h"
#else
#include <stdint.h>
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stddef.h>
#endif
#include "xattention_mask_hw.h"

/**************************** Type Definitions ******************************/
#ifdef __linux__
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#else
typedef struct {
#ifdef SDT
    char *Name;
#else
    u16 DeviceId;
#endif
    u64 Control_BaseAddress;
} XAttention_mask_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XAttention_mask;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XAttention_mask_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XAttention_mask_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XAttention_mask_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XAttention_mask_ReadReg(BaseAddress, RegOffset) \
    *(volatile u32*)((BaseAddress) + (RegOffset))

#define Xil_AssertVoid(expr)    assert(expr)
#define Xil_AssertNonvoid(expr) assert(expr)

#define XST_SUCCESS             0
#define XST_DEVICE_NOT_FOUND    2
#define XST_OPEN_DEVICE_FAILED  3
#define XIL_COMPONENT_IS_READY  1
#endif

/************************** Function Prototypes *****************************/
#ifndef __linux__
#ifdef SDT
int XAttention_mask_Initialize(XAttention_mask *InstancePtr, UINTPTR BaseAddress);
XAttention_mask_Config* XAttention_mask_LookupConfig(UINTPTR BaseAddress);
#else
int XAttention_mask_Initialize(XAttention_mask *InstancePtr, u16 DeviceId);
XAttention_mask_Config* XAttention_mask_LookupConfig(u16 DeviceId);
#endif
int XAttention_mask_CfgInitialize(XAttention_mask *InstancePtr, XAttention_mask_Config *ConfigPtr);
#else
int XAttention_mask_Initialize(XAttention_mask *InstancePtr, const char* InstanceName);
int XAttention_mask_Release(XAttention_mask *InstancePtr);
#endif

void XAttention_mask_Start(XAttention_mask *InstancePtr);
u32 XAttention_mask_IsDone(XAttention_mask *InstancePtr);
u32 XAttention_mask_IsIdle(XAttention_mask *InstancePtr);
u32 XAttention_mask_IsReady(XAttention_mask *InstancePtr);
void XAttention_mask_EnableAutoRestart(XAttention_mask *InstancePtr);
void XAttention_mask_DisableAutoRestart(XAttention_mask *InstancePtr);

void XAttention_mask_Set_raw_scores(XAttention_mask *InstancePtr, u64 Data);
u64 XAttention_mask_Get_raw_scores(XAttention_mask *InstancePtr);
void XAttention_mask_Set_masked_scores(XAttention_mask *InstancePtr, u64 Data);
u64 XAttention_mask_Get_masked_scores(XAttention_mask *InstancePtr);
void XAttention_mask_Set_q_heads(XAttention_mask *InstancePtr, u32 Data);
u32 XAttention_mask_Get_q_heads(XAttention_mask *InstancePtr);
void XAttention_mask_Set_seq_len(XAttention_mask *InstancePtr, u32 Data);
u32 XAttention_mask_Get_seq_len(XAttention_mask *InstancePtr);
void XAttention_mask_Set_causal(XAttention_mask *InstancePtr, u32 Data);
u32 XAttention_mask_Get_causal(XAttention_mask *InstancePtr);
void XAttention_mask_Set_mask_value(XAttention_mask *InstancePtr, u32 Data);
u32 XAttention_mask_Get_mask_value(XAttention_mask *InstancePtr);

void XAttention_mask_InterruptGlobalEnable(XAttention_mask *InstancePtr);
void XAttention_mask_InterruptGlobalDisable(XAttention_mask *InstancePtr);
void XAttention_mask_InterruptEnable(XAttention_mask *InstancePtr, u32 Mask);
void XAttention_mask_InterruptDisable(XAttention_mask *InstancePtr, u32 Mask);
void XAttention_mask_InterruptClear(XAttention_mask *InstancePtr, u32 Mask);
u32 XAttention_mask_InterruptGetEnabled(XAttention_mask *InstancePtr);
u32 XAttention_mask_InterruptGetStatus(XAttention_mask *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif
