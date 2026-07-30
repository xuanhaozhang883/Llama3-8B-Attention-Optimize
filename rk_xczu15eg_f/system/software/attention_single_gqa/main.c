#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "attention_config.h"
#include "attention_data_provider.h"
#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xiltimer.h"

#define HW_TIMEOUT_TICKS ((u64)COUNTS_PER_SECOND * 10u)

#if defined(SDT) && defined(XPAR_XAXIDMA_0_BASEADDR)
#define RK_DMA_CONFIG_KEY XPAR_XAXIDMA_0_BASEADDR
#elif defined(XPAR_AXIDMA_0_DEVICE_ID)
#define RK_DMA_CONFIG_KEY XPAR_AXIDMA_0_DEVICE_ID
#else
#error "xparameters.h must define AXI DMA device ID or SDT base address"
#endif

#ifndef RK_ATTENTION_BASEADDR
#if defined(XPAR_ATTENTION_0_BASEADDR)
#define RK_ATTENTION_BASEADDR XPAR_ATTENTION_0_BASEADDR
#elif defined(XPAR_ATTENTION_AXIS_ACCELERATOR_0_BASEADDR)
#define RK_ATTENTION_BASEADDR XPAR_ATTENTION_AXIS_ACCELERATOR_0_BASEADDR
#else
#error "Define RK_ATTENTION_BASEADDR from the generated xparameters.h"
#endif
#endif

static uint16_t q_data[RK_ATTN_Q_WORDS] __attribute__((aligned(64)));
static uint16_t k_data[RK_ATTN_K_WORDS] __attribute__((aligned(64)));
static uint16_t v_data[RK_ATTN_V_WORDS] __attribute__((aligned(64)));
static uint8_t qkv_frame[RK_ATTN_INPUT_BYTES] __attribute__((aligned(64)));
static uint16_t context_data[RK_ATTN_CONTEXT_WORDS]
    __attribute__((aligned(64)));
static uint16_t golden_data[RK_ATTN_CONTEXT_WORDS]
    __attribute__((aligned(64)));

static uint32_t reg_read(uint32_t offset)
{
    return Xil_In32((UINTPTR)RK_ATTENTION_BASEADDR + offset);
}

static void reg_write(uint32_t offset, uint32_t value)
{
    Xil_Out32((UINTPTR)RK_ATTENTION_BASEADDR + offset, value);
}

static int wait_status(uint32_t mask, uint32_t expected)
{
    XTime start;
    XTime now;

    XTime_GetTime(&start);
    while ((reg_read(RK_ATTN_REG_STATUS) & mask) != expected) {
        XTime_GetTime(&now);
        if ((now - start) > HW_TIMEOUT_TICKS)
            return XST_FAILURE;
    }
    return XST_SUCCESS;
}

static int wait_dma_idle(XAxiDma *dma, int direction)
{
    XTime start;
    XTime now;

    XTime_GetTime(&start);
    while (XAxiDma_Busy(dma, direction)) {
        XTime_GetTime(&now);
        if ((now - start) > HW_TIMEOUT_TICKS)
            return XST_FAILURE;
    }
    return XST_SUCCESS;
}

int main(void)
{
    XAxiDma dma;
    XAxiDma_Config *config;
    uint32_t status;
    uint32_t error_vector;
    uint64_t kernel_cycles;
    size_t mismatches;
    size_t first_mismatch;
    XTime application_start;
    XTime application_stop;
    XTime dma_start;
    XTime dma_stop;
    int data_mode;
    int golden_mode;
    int result;

    xil_printf("RK single-GQA PS-DDR/DMA/Attention\r\n");
    xil_printf("input=%lu output=%lu bytes\r\n",
               (unsigned long)RK_ATTN_INPUT_BYTES,
               (unsigned long)RK_ATTN_OUTPUT_BYTES);
    XTime_GetTime(&application_start);

    config = XAxiDma_LookupConfig(RK_DMA_CONFIG_KEY);
    if (config == NULL)
        return XST_FAILURE;
    if (XAxiDma_CfgInitialize(&dma, config) != XST_SUCCESS)
        return XST_FAILURE;
    if (XAxiDma_HasSg(&dma))
        return XST_FAILURE;
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);

    data_mode = rk_attention_prepare_qkv(
        q_data, RK_ATTN_Q_WORDS,
        k_data, RK_ATTN_K_WORDS,
        v_data, RK_ATTN_V_WORDS);
    if (data_mode < 0) {
        xil_printf("QKV provider failed: %d\r\n", data_mode);
        return XST_FAILURE;
    }
    xil_printf("qkv_mode=%s\r\n",
               data_mode == RK_ATTN_DATA_REAL ? "real" : "placeholder");
    result = rk_attention_pack_qkv(
        qkv_frame, sizeof(qkv_frame), q_data, k_data, v_data);
    if (result != 0) {
        xil_printf("QKV pack failed: %d\r\n", result);
        return XST_FAILURE;
    }
    memset(context_data, 0xA5, sizeof(context_data));
    reg_write(RK_ATTN_REG_CONTROL, RK_ATTN_CONTROL_CLEAR);

    Xil_DCacheFlushRange((UINTPTR)qkv_frame, sizeof(qkv_frame));
    Xil_DCacheFlushRange((UINTPTR)context_data, sizeof(context_data));

    XTime_GetTime(&dma_start);
    result = XAxiDma_SimpleTransfer(
        &dma, (UINTPTR)context_data, RK_ATTN_OUTPUT_BYTES,
        XAXIDMA_DEVICE_TO_DMA);
    if (result != XST_SUCCESS)
        return XST_FAILURE;
    result = XAxiDma_SimpleTransfer(
        &dma, (UINTPTR)qkv_frame, RK_ATTN_INPUT_BYTES,
        XAXIDMA_DMA_TO_DEVICE);
    if (result != XST_SUCCESS)
        return XST_FAILURE;

    if (wait_dma_idle(&dma, XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return XST_FAILURE;
    if (wait_status(RK_ATTN_STATUS_FRAME_LOADED,
                    RK_ATTN_STATUS_FRAME_LOADED) != XST_SUCCESS)
        return XST_FAILURE;
    if (wait_status(RK_ATTN_STATUS_READY,
                    RK_ATTN_STATUS_READY) != XST_SUCCESS)
        return XST_FAILURE;

    reg_write(RK_ATTN_REG_CONTROL, RK_ATTN_CONTROL_START);
    if (wait_status(RK_ATTN_STATUS_DONE,
                    RK_ATTN_STATUS_DONE) != XST_SUCCESS)
        return XST_FAILURE;
    if (wait_dma_idle(&dma, XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS)
        return XST_FAILURE;
    XTime_GetTime(&dma_stop);
    Xil_DCacheInvalidateRange(
        (UINTPTR)context_data, sizeof(context_data));

    status = reg_read(RK_ATTN_REG_STATUS);
    error_vector = reg_read(RK_ATTN_REG_ERROR_VECTOR);
    kernel_cycles =
        ((uint64_t)reg_read(RK_ATTN_REG_KERNEL_HI) << 32) |
        reg_read(RK_ATTN_REG_KERNEL_LO);

    xil_printf("status=0x%08lx errors=0x%02lx kernel_cycles=%llu\r\n",
               (unsigned long)status, (unsigned long)error_vector,
               (unsigned long long)kernel_cycles);
    xil_printf("input_beats=%lu output_beats=%lu\r\n",
               (unsigned long)reg_read(RK_ATTN_REG_INPUT_BEATS),
               (unsigned long)reg_read(RK_ATTN_REG_OUTPUT_BEATS));

    if ((status & RK_ATTN_STATUS_ERROR) != 0u || error_vector != 0u)
        return XST_FAILURE;

    golden_mode = rk_attention_prepare_golden(
        golden_data, RK_ATTN_CONTEXT_WORDS);
    if (golden_mode < 0) {
        xil_printf("Golden provider failed: %d\r\n", golden_mode);
        return XST_FAILURE;
    }
    if (golden_mode == RK_ATTN_DATA_REAL) {
        mismatches = rk_attention_compare_bf16(
            context_data, golden_data, RK_ATTN_CONTEXT_WORDS,
            &first_mismatch);
        xil_printf("golden_mismatches=%lu first=%lu\r\n",
                   (unsigned long)mismatches,
                   (unsigned long)first_mismatch);
        if (mismatches != 0u)
            return XST_FAILURE;
    } else {
        xil_printf("golden_mode=placeholder correctness=HARDWARE_PENDING\r\n");
    }

    XTime_GetTime(&application_stop);
    xil_printf("timer_hz=%llu dma_ticks=%llu application_ticks=%llu\r\n",
               (unsigned long long)COUNTS_PER_SECOND,
               (unsigned long long)(dma_stop - dma_start),
               (unsigned long long)(application_stop - application_start));
    xil_printf("ATTENTION TRANSACTION COMPLETE\r\n");
    if (data_mode != RK_ATTN_DATA_REAL ||
        golden_mode != RK_ATTN_DATA_REAL)
        xil_printf("Correctness requires strong real-data providers\r\n");
    return XST_SUCCESS;
}
