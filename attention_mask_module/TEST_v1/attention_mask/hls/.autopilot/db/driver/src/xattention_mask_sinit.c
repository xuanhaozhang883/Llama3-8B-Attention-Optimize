// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2025.2 (64-bit)
// Tool Version Limit: 2025.11
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#ifdef SDT
#include "xparameters.h"
#endif
#include "xattention_mask.h"

extern XAttention_mask_Config XAttention_mask_ConfigTable[];

#ifdef SDT
XAttention_mask_Config *XAttention_mask_LookupConfig(UINTPTR BaseAddress) {
	XAttention_mask_Config *ConfigPtr = NULL;

	int Index;

	for (Index = (u32)0x0; XAttention_mask_ConfigTable[Index].Name != NULL; Index++) {
		if (!BaseAddress || XAttention_mask_ConfigTable[Index].Control_BaseAddress == BaseAddress) {
			ConfigPtr = &XAttention_mask_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XAttention_mask_Initialize(XAttention_mask *InstancePtr, UINTPTR BaseAddress) {
	XAttention_mask_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XAttention_mask_LookupConfig(BaseAddress);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XAttention_mask_CfgInitialize(InstancePtr, ConfigPtr);
}
#else
XAttention_mask_Config *XAttention_mask_LookupConfig(u16 DeviceId) {
	XAttention_mask_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XATTENTION_MASK_NUM_INSTANCES; Index++) {
		if (XAttention_mask_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XAttention_mask_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XAttention_mask_Initialize(XAttention_mask *InstancePtr, u16 DeviceId) {
	XAttention_mask_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XAttention_mask_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XAttention_mask_CfgInitialize(InstancePtr, ConfigPtr);
}
#endif

#endif

