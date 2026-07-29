#include <stddef.h>
#include <stdint.h>

#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

/*
 * These values must come from the vendor-verified PL-DDR address map.
 * The deliberate compile-time errors prevent an arbitrary DDR address from
 * being used on hardware.
 */
#ifndef RK_PL_DDR_BASEADDR
#error "Define RK_PL_DDR_BASEADDR from the generated XSA address map"
#endif

#ifndef RK_PL_DDR_TEST_BYTES
#define RK_PL_DDR_TEST_BYTES (4u * 1024u * 1024u)
#endif

#if (RK_PL_DDR_TEST_BYTES % 4u) != 0
#error "RK_PL_DDR_TEST_BYTES must be a multiple of four"
#endif

#define TEST_WORDS (RK_PL_DDR_TEST_BYTES / 4u)

static volatile uint32_t *const pl_ddr =
    (volatile uint32_t *)(UINTPTR)RK_PL_DDR_BASEADDR;

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
        pl_ddr[index] = pattern_value(pattern, index);

    if (cache_enabled) {
        Xil_DCacheFlushRange((UINTPTR)pl_ddr, RK_PL_DDR_TEST_BYTES);
        Xil_DCacheInvalidateRange((UINTPTR)pl_ddr, RK_PL_DDR_TEST_BYTES);
    }

    for (index = 0u; index < TEST_WORDS; ++index) {
        expected = pattern_value(pattern, index);
        if (pl_ddr[index] != expected) {
            xil_printf(
                "PL DDR FAIL cache=%d pattern=%u index=%lu expected=%08lx actual=%08lx\r\n",
                cache_enabled, pattern, (unsigned long)index,
                (unsigned long)expected,
                (unsigned long)pl_ddr[index]);
            return XST_FAILURE;
        }
    }
    xil_printf("PL DDR PASS cache=%d pattern=%u bytes=%lu\r\n",
               cache_enabled, pattern,
               (unsigned long)RK_PL_DDR_TEST_BYTES);
    return XST_SUCCESS;
}

int main(void)
{
    unsigned pattern;

    xil_printf("RK PL DDR base=%p bytes=%lu\r\n", pl_ddr,
               (unsigned long)RK_PL_DDR_TEST_BYTES);

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

    xil_printf("PL DDR ALL PASS\r\n");
    return XST_SUCCESS;
}
