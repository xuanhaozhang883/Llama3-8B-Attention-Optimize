#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xiltimer.h"

#define DMA_TIMEOUT_TICKS ((u64)COUNTS_PER_SECOND * 5u)
#define DMA_BUFFER_BYTES  (1024u * 1024u)

#if defined(SDT) && defined(XPAR_XAXIDMA_0_BASEADDR)
#define RK_DMA_CONFIG_KEY XPAR_XAXIDMA_0_BASEADDR
#elif defined(XPAR_AXIDMA_0_DEVICE_ID)
#define RK_DMA_CONFIG_KEY XPAR_AXIDMA_0_DEVICE_ID
#else
#error "xparameters.h must define AXI DMA device ID or SDT base address"
#endif

static uint8_t tx_buffer[DMA_BUFFER_BYTES]
    __attribute__((aligned(64)));
static uint8_t rx_buffer[DMA_BUFFER_BYTES]
    __attribute__((aligned(64)));

static int wait_dma_idle(XAxiDma *dma, int direction)
{
    XTime start;
    XTime now;

    XTime_GetTime(&start);
    while (XAxiDma_Busy(dma, direction)) {
        XTime_GetTime(&now);
        if ((now - start) > DMA_TIMEOUT_TICKS)
            return XST_FAILURE;
    }
    return XST_SUCCESS;
}

static void fill_pattern(size_t length, uint32_t seed)
{
    size_t index;
    uint32_t value = seed;

    for (index = 0u; index < length; ++index) {
        value = value * 1664525u + 1013904223u;
        tx_buffer[index] = (uint8_t)(value >> 24);
        rx_buffer[index] = 0xA5u;
    }
}

static int run_length(XAxiDma *dma, size_t length, uint32_t seed)
{
    int status;
    XTime start;
    XTime stop;
    size_t index;

    fill_pattern(length, seed);
    Xil_DCacheFlushRange((UINTPTR)tx_buffer, length);
    Xil_DCacheFlushRange((UINTPTR)rx_buffer, length);

    XTime_GetTime(&start);
    status = XAxiDma_SimpleTransfer(
        dma, (UINTPTR)rx_buffer, length, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS)
        return status;
    status = XAxiDma_SimpleTransfer(
        dma, (UINTPTR)tx_buffer, length, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS)
        return status;

    if (wait_dma_idle(dma, XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS)
        return XST_FAILURE;
    if (wait_dma_idle(dma, XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS)
        return XST_FAILURE;
    XTime_GetTime(&stop);

    Xil_DCacheInvalidateRange((UINTPTR)rx_buffer, length);
    for (index = 0u; index < length; ++index) {
        if (rx_buffer[index] != tx_buffer[index]) {
            xil_printf("DMA mismatch length=%lu index=%lu tx=%02x rx=%02x\r\n",
                       (unsigned long)length, (unsigned long)index,
                       tx_buffer[index], rx_buffer[index]);
            return XST_FAILURE;
        }
    }

    xil_printf("DMA PASS bytes=%lu ticks=%llu\r\n",
               (unsigned long)length,
               (unsigned long long)(stop - start));
    return XST_SUCCESS;
}

int main(void)
{
    static const size_t lengths[] = {
        1u, 15u, 16u, 63u, 64u, 4096u, 65536u, DMA_BUFFER_BYTES
    };
    XAxiDma dma;
    XAxiDma_Config *config;
    size_t test_index;

    xil_printf("RK PS-DDR AXI DMA loopback\r\n");
    config = XAxiDma_LookupConfig(RK_DMA_CONFIG_KEY);
    if (config == NULL)
        return XST_FAILURE;
    if (XAxiDma_CfgInitialize(&dma, config) != XST_SUCCESS)
        return XST_FAILURE;
    if (XAxiDma_HasSg(&dma)) {
        xil_printf("ERROR: simple mode required\r\n");
        return XST_FAILURE;
    }
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);

    for (test_index = 0u;
         test_index < sizeof(lengths)/sizeof(lengths[0]);
         ++test_index) {
        if (run_length(&dma, lengths[test_index],
                       0x12340000u + (uint32_t)test_index) != XST_SUCCESS) {
            xil_printf("DMA LOOPBACK FAILED\r\n");
            return XST_FAILURE;
        }
    }
    xil_printf("DMA LOOPBACK ALL PASS\r\n");
    return XST_SUCCESS;
}
