#include <stdint.h>
#include <stddef.h>

#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

#define TEST_WORDS (1024u * 1024u)

static uint32_t ddr_buffer[TEST_WORDS] __attribute__((aligned(64)));

static uint32_t pattern_value(unsigned pattern, size_t index)
{
    switch (pattern) {
    case 0u:
        return 1u << (index & 31u);
    case 1u:
        return ~(1u << (index & 31u));
    case 2u:
        return (uint32_t)index ^ 0xA5A55A5Au;
    case 3u:
        return (index & 1u) ? 0xAAAAAAAAu : 0x55555555u;
    default:
        return (uint32_t)(1664525u * (uint32_t)index + 1013904223u);
    }
}

static int run_pattern(unsigned pattern, int cache_enabled)
{
    size_t index;
    uint32_t expected;

    for (index = 0u; index < TEST_WORDS; ++index)
        ddr_buffer[index] = pattern_value(pattern, index);

    if (cache_enabled) {
        Xil_DCacheFlushRange((UINTPTR)ddr_buffer, sizeof(ddr_buffer));
        Xil_DCacheInvalidateRange((UINTPTR)ddr_buffer, sizeof(ddr_buffer));
    }

    for (index = 0u; index < TEST_WORDS; ++index) {
        expected = pattern_value(pattern, index);
        if (ddr_buffer[index] != expected) {
            xil_printf(
                "PS DDR FAIL cache=%d pattern=%u index=%lu expected=%08lx actual=%08lx\r\n",
                cache_enabled, pattern, (unsigned long)index,
                (unsigned long)expected,
                (unsigned long)ddr_buffer[index]);
            return XST_FAILURE;
        }
    }
    xil_printf("PS DDR PASS cache=%d pattern=%u bytes=%lu\r\n",
               cache_enabled, pattern, (unsigned long)sizeof(ddr_buffer));
    return XST_SUCCESS;
}

int main(void)
{
    unsigned pattern;

    xil_printf("RK PS DDR test buffer=%p bytes=%lu\r\n",
               ddr_buffer, (unsigned long)sizeof(ddr_buffer));

    Xil_DCacheEnable();
    for (pattern = 0u; pattern < 5u; ++pattern) {
        if (run_pattern(pattern, 1) != XST_SUCCESS)
            return XST_FAILURE;
    }

    Xil_DCacheFlush();
    Xil_DCacheDisable();
    for (pattern = 0u; pattern < 5u; ++pattern) {
        if (run_pattern(pattern, 0) != XST_SUCCESS) {
            Xil_DCacheEnable();
            return XST_FAILURE;
        }
    }
    Xil_DCacheEnable();

    xil_printf("PS DDR ALL PASS\r\n");
    return XST_SUCCESS;
}
