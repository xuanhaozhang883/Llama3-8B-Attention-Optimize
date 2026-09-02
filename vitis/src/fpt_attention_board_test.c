#include <stdint.h>
#include <string.h>

#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtime_l.h"

#include "fpt_golden_vectors.h"

#if defined(XPAR_AXI_GPIO_CTRL_BASEADDR)
#define FPT_GPIO_BASE XPAR_AXI_GPIO_CTRL_BASEADDR
#elif defined(XPAR_AXI_GPIO_0_BASEADDR)
#define FPT_GPIO_BASE XPAR_AXI_GPIO_0_BASEADDR
#else
#define FPT_GPIO_BASE 0x80000000U
#endif

#define GPIO_DATA_CH1 0x00U
#define GPIO_TRI_CH1  0x04U
#define GPIO_DATA_CH2 0x08U
#define GPIO_TRI_CH2  0x0CU

#define CTRL_START      (1U << 0)
#define CTRL_CAUSAL_EN  (1U << 1)
#define CTRL_SOFT_RESET (1U << 2)
#define CTRL_PROFILE_SHIFT 3U
#define CTRL_PROFILE_MASK  (0x3FU << CTRL_PROFILE_SHIFT)

enum {
    PROF_STATUS = 0,
    PROF_TOTAL_CYCLES = 1,
    PROF_V_LOAD_CYCLES = 2,
    PROF_CORE_RUN_CYCLES = 3,
    PROF_RAW_WAIT_CYCLES = 4,
    PROF_RAW_BUSY_CYCLES = 5,
    PROF_BC_BUSY_CYCLES = 6,
    PROF_PV_BUSY_CYCLES = 7,
    PROF_CONTEXT_BUSY_CYCLES = 8,
    PROF_CONTEXT_BACKPRESSURE_CYCLES = 9,
    PROF_DDR_READ_BUSY_CYCLES = 10,
    PROF_DDR_WRITE_BUSY_CYCLES = 11,
    PROF_RAW_REQ_COUNT = 12,
    PROF_READ_BEAT_COUNT = 13,
    PROF_WRITE_BEAT_COUNT = 14,
    PROF_CONTEXT_WORD_COUNT = 15,
    PROF_GROUP0_CYCLES = 16,
    PROF_READ_COMMAND_COUNT = 24,
    PROF_WRITE_COMMAND_COUNT = 25,
    PROF_ERROR_DETAIL = 26,
    PROF_ROPE_BUSY_CYCLES = 27,
    PROF_QK_BUSY_CYCLES = 28,
    PROF_MASK_BUSY_CYCLES = 29,
    PROF_SOFTMAX_BUSY_CYCLES = 30,
    PROF_BC_BACKEND_BUSY_CYCLES = 31,
    PROF_CAPTURE_BUSY_CYCLES = 32,
    PROF_CONTEXT_TRANSFER_CYCLES = 33,
    PROF_BC_PV_OVERLAP_CYCLES = 34,
    PROF_CORE_IDLE_CYCLES = 35,
    PROF_REPACK_STALL_CYCLES = 36,
    PROF_PV_FEED_STALL_CYCLES = 37,
    PROF_SOFTMAX_STALL_CYCLES = 38,
    PROF_INTERSTAGE_WAIT_CYCLES = 39,
    PROF_QK_TILES_COMPUTED = 40,
    PROF_QK_TILES_SKIPPED = 41,
    PROF_MASKED_TILES_EMITTED = 42,
    PROF_PV_REDUCTIONS_COMPUTED = 43,
    PROF_PV_REDUCTIONS_SKIPPED = 44,
    PROF_NATIVE_VECTORS_CAPTURED = 45,
    PROF_CAUSAL_ERROR_FLAGS = 46
};

#define ST_BUSY         (1U << 0)
#define ST_DONE         (1U << 1)
#define ST_ERROR        (1U << 2)
#define ST_READY        (1U << 3)
#define ST_V_LOADED     (1U << 4)
#define ST_CORE_DONE    (1U << 5)
#define ST_CONTEXT_DONE (1U << 6)

#define Q_BASE_ADDR       0x10000000U
#define K_BASE_ADDR       0x10100000U
#define V_BASE_ADDR       0x10140000U
#define CONTEXT_BASE_ADDR 0x10180000U

#define CONTEXT_WORDS FPT_CONTEXT_EXPECTED_BF16_WORDS
#define POLL_LIMIT 2000000000U
#define RESET_POLL_LIMIT 10000000U
#define RESET_HOLD_LOOPS 1000000U

#define ABS_TOLERANCE 0.0001f
#define MAX_ALLOWED_ULP 1U
#define MAX_PRINTED_STRICT_FAILURES 32U

#define WARMUP_RUNS 1U
#define MEASURED_RUNS 10U

#ifndef FPT_V31_EXPECT_FLASH
#define FPT_V31_EXPECT_FLASH 1
#endif

#ifndef FPT_V314_CAUSAL_BYPASS
#define FPT_V314_CAUSAL_BYPASS 1
#endif


#define V31_QK_TILES_COMPUTED_EXPECTED \
    (2112U * FPT_RUN_GROUPS)
#define V31_QK_TILES_SKIPPED_EXPECTED \
    (1984U * FPT_RUN_GROUPS)
#define V31_MASKED_TILES_EMITTED_EXPECTED \
    (1984U * FPT_RUN_GROUPS)
/* Profile pages 43/44/45 report Flash context tiles processed, causal consumer
 * tiles bypassed, and eight-lane V-cache vectors read.  v3.1.4 consumes only
 * the lower-triangular tile set; v3.1.3 compatibility mode consumes the dense
 * square. */
#define V31_TILES_PER_AXIS (FPT_SEQ_LEN / 4U)
#if FPT_V314_CAUSAL_BYPASS
#define V31_CONTEXT_TILES_EXPECTED \
    (FPT_Q_HEADS * V31_TILES_PER_AXIS * (V31_TILES_PER_AXIS + 1U) / 2U)
#define V31_CONTEXT_TILES_BYPASSED_EXPECTED \
    (FPT_Q_HEADS * V31_TILES_PER_AXIS * (V31_TILES_PER_AXIS - 1U) / 2U)
#else
#define V31_CONTEXT_TILES_EXPECTED \
    (FPT_Q_HEADS * V31_TILES_PER_AXIS * V31_TILES_PER_AXIS)
#define V31_CONTEXT_TILES_BYPASSED_EXPECTED 0U
#endif
#define V31_V_VECTORS_EXPECTED \
    (V31_CONTEXT_TILES_EXPECTED * 4U * (FPT_HEAD_DIM / 8U))

/* QK and PV each perform one BF16 dot-product MAC for every
 * [query_head][row][col][head_dim] entry. Counting a MAC as two FLOPs:
 * total QK+PV FLOPs = 4 * Q_HEADS * S * S * D.
 * RoPE and Softmax operations are deliberately excluded from this derived
 * effective throughput number and are still included in measured latency.
 */
#define QK_PV_FLOPS \
    (4ULL * (uint64_t)FPT_Q_HEADS * (uint64_t)FPT_SEQ_LEN * \
     (uint64_t)FPT_SEQ_LEN * (uint64_t)FPT_HEAD_DIM)

typedef struct {
    uint32_t exact_mismatches;
    uint32_t strict_abs_failures;
    uint32_t strict_rescued_by_1ulp;
    uint32_t combined_failures;
    uint32_t max_ulp_on_strict;
    uint32_t max_abs_error_x1e9;
} compare_stats_t;

typedef struct {
    uint32_t total_cycles;
    uint32_t v_load_cycles;
    uint32_t core_run_cycles;
    uint32_t raw_wait_cycles;
    uint32_t raw_busy_cycles;
    uint32_t bc_busy_cycles;
    uint32_t pv_busy_cycles;
    uint32_t context_busy_cycles;
    uint32_t context_backpressure_cycles;
    uint32_t ddr_read_busy_cycles;
    uint32_t ddr_write_busy_cycles;
    uint32_t raw_req_count;
    uint32_t read_beat_count;
    uint32_t write_beat_count;
    uint32_t context_word_count;
    uint32_t group_cycles[FPT_RUN_GROUPS];
    uint32_t read_command_count;
    uint32_t write_command_count;
    uint32_t error_detail;
    uint32_t rope_busy_cycles;
    uint32_t qk_busy_cycles;
    uint32_t mask_busy_cycles;
    uint32_t softmax_busy_cycles;
    uint32_t bc_backend_busy_cycles;
    uint32_t capture_busy_cycles;
    uint32_t context_transfer_cycles;
    uint32_t bc_pv_overlap_cycles;
    uint32_t core_idle_cycles;
    uint32_t repack_stall_cycles;
    uint32_t pv_feed_stall_cycles;
    uint32_t softmax_stall_cycles;
    uint32_t interstage_wait_cycles;
    uint32_t qk_tiles_computed;
    uint32_t qk_tiles_skipped;
    uint32_t masked_tiles_emitted;
    uint32_t pv_reductions_computed;
    uint32_t pv_reductions_skipped;
    uint32_t native_vectors_captured;
    uint32_t causal_error_flags;
} hw_profile_t;

typedef struct {
    uint64_t timer_ticks;
    uint64_t latency_ns;
    uint32_t status;
    compare_stats_t compare;
    hw_profile_t profile;
    uint32_t passed;
} run_result_t;

static float bf16_to_float(uint16_t value)
{
    union {
        uint32_t u;
        float f;
    } cvt;
    cvt.u = ((uint32_t)value) << 16;
    return cvt.f;
}

static float abs_float(float value)
{
    return value < 0.0f ? -value : value;
}

static uint16_t bf16_order_key(uint16_t bits)
{
    if ((bits & 0x8000U) != 0U)
        return (uint16_t)(~bits);
    return (uint16_t)(bits ^ 0x8000U);
}

static uint32_t bf16_ulp_distance(uint16_t a, uint16_t b)
{
    if ((a & 0x7FFFU) == 0U && (b & 0x7FFFU) == 0U)
        return 0U;

    const uint32_t ka = (uint32_t)bf16_order_key(a);
    const uint32_t kb = (uint32_t)bf16_order_key(b);
    return ka >= kb ? (ka - kb) : (kb - ka);
}

static uint64_t mul_div_u64(uint64_t a, uint64_t b, uint64_t divisor)
{
    if (divisor == 0U)
        return 0U;
    return (uint64_t)(((__uint128_t)a * (__uint128_t)b) /
                      (__uint128_t)divisor);
}

static uint64_t integer_sqrt_u64(uint64_t value)
{
    uint64_t result = 0U;
    uint64_t bit = 1ULL << 62;

    while (bit > value)
        bit >>= 2;

    while (bit != 0U) {
        if (value >= result + bit) {
            value -= result + bit;
            result = (result >> 1) + bit;
        } else {
            result >>= 1;
        }
        bit >>= 2;
    }
    return result;
}

static void print_u64(uint64_t value)
{
    char buffer[32];
    uint32_t pos = (uint32_t)sizeof(buffer);
    buffer[--pos] = '\0';

    do {
        buffer[--pos] = (char)('0' + (value % 10U));
        value /= 10U;
    } while (value != 0U && pos != 0U);

    xil_printf("%s", &buffer[pos]);
}

static void print_ms_3(uint64_t ns)
{
    print_u64(ns / 1000000ULL);
    xil_printf(".%03lu", (unsigned long)((ns % 1000000ULL) / 1000ULL));
}

static void print_rate_3(uint64_t value_x1000)
{
    print_u64(value_x1000 / 1000ULL);
    xil_printf(".%03lu", (unsigned long)(value_x1000 % 1000ULL));
}

static void gpio_write(uint32_t value)
{
    Xil_Out32(FPT_GPIO_BASE + GPIO_DATA_CH1, value);
}

static uint32_t gpio_status(void)
{
    return Xil_In32(FPT_GPIO_BASE + GPIO_DATA_CH2);
}

static uint32_t profile_control_word(uint32_t page, uint32_t command_bits)
{
    return CTRL_CAUSAL_EN | command_bits |
           ((page & 0x3FU) << CTRL_PROFILE_SHIFT);
}

static uint32_t read_profile_page(uint32_t page)
{
    gpio_write(profile_control_word(page, 0U));
    (void)gpio_status();
    return gpio_status();
}

static void read_hw_profile(hw_profile_t *profile)
{
    memset(profile, 0, sizeof(*profile));
    profile->total_cycles = read_profile_page(PROF_TOTAL_CYCLES);
    profile->v_load_cycles = read_profile_page(PROF_V_LOAD_CYCLES);
    profile->core_run_cycles = read_profile_page(PROF_CORE_RUN_CYCLES);
    profile->raw_wait_cycles = read_profile_page(PROF_RAW_WAIT_CYCLES);
    profile->raw_busy_cycles = read_profile_page(PROF_RAW_BUSY_CYCLES);
    profile->bc_busy_cycles = read_profile_page(PROF_BC_BUSY_CYCLES);
    profile->pv_busy_cycles = read_profile_page(PROF_PV_BUSY_CYCLES);
    profile->context_busy_cycles = read_profile_page(PROF_CONTEXT_BUSY_CYCLES);
    profile->context_backpressure_cycles =
        read_profile_page(PROF_CONTEXT_BACKPRESSURE_CYCLES);
    profile->ddr_read_busy_cycles = read_profile_page(PROF_DDR_READ_BUSY_CYCLES);
    profile->ddr_write_busy_cycles = read_profile_page(PROF_DDR_WRITE_BUSY_CYCLES);
    profile->raw_req_count = read_profile_page(PROF_RAW_REQ_COUNT);
    profile->read_beat_count = read_profile_page(PROF_READ_BEAT_COUNT);
    profile->write_beat_count = read_profile_page(PROF_WRITE_BEAT_COUNT);
    profile->context_word_count = read_profile_page(PROF_CONTEXT_WORD_COUNT);
    for (uint32_t group = 0U; group < FPT_RUN_GROUPS; ++group)
        profile->group_cycles[group] =
            read_profile_page(PROF_GROUP0_CYCLES + group);
    profile->read_command_count = read_profile_page(PROF_READ_COMMAND_COUNT);
    profile->write_command_count = read_profile_page(PROF_WRITE_COMMAND_COUNT);
    profile->error_detail = read_profile_page(PROF_ERROR_DETAIL);
    profile->rope_busy_cycles = read_profile_page(PROF_ROPE_BUSY_CYCLES);
    profile->qk_busy_cycles = read_profile_page(PROF_QK_BUSY_CYCLES);
    profile->mask_busy_cycles = read_profile_page(PROF_MASK_BUSY_CYCLES);
    profile->softmax_busy_cycles = read_profile_page(PROF_SOFTMAX_BUSY_CYCLES);
    profile->bc_backend_busy_cycles =
        read_profile_page(PROF_BC_BACKEND_BUSY_CYCLES);
    profile->capture_busy_cycles = read_profile_page(PROF_CAPTURE_BUSY_CYCLES);
    profile->context_transfer_cycles =
        read_profile_page(PROF_CONTEXT_TRANSFER_CYCLES);
    profile->bc_pv_overlap_cycles =
        read_profile_page(PROF_BC_PV_OVERLAP_CYCLES);
    profile->core_idle_cycles = read_profile_page(PROF_CORE_IDLE_CYCLES);
    profile->repack_stall_cycles = read_profile_page(PROF_REPACK_STALL_CYCLES);
    profile->pv_feed_stall_cycles =
        read_profile_page(PROF_PV_FEED_STALL_CYCLES);
    profile->softmax_stall_cycles =
        read_profile_page(PROF_SOFTMAX_STALL_CYCLES);
    profile->interstage_wait_cycles =
        read_profile_page(PROF_INTERSTAGE_WAIT_CYCLES);
    profile->qk_tiles_computed =
        read_profile_page(PROF_QK_TILES_COMPUTED);
    profile->qk_tiles_skipped =
        read_profile_page(PROF_QK_TILES_SKIPPED);
    profile->masked_tiles_emitted =
        read_profile_page(PROF_MASKED_TILES_EMITTED);
    profile->pv_reductions_computed =
        read_profile_page(PROF_PV_REDUCTIONS_COMPUTED);
    profile->pv_reductions_skipped =
        read_profile_page(PROF_PV_REDUCTIONS_SKIPPED);
    profile->native_vectors_captured =
        read_profile_page(PROF_NATIVE_VECTORS_CAPTURED);
    profile->causal_error_flags =
        read_profile_page(PROF_CAUSAL_ERROR_FLAGS);
    gpio_write(profile_control_word(PROF_STATUS, 0U));
}

static void clear_context(void)
{
    memset((void *)(uintptr_t)CONTEXT_BASE_ADDR, 0,
           CONTEXT_WORDS * sizeof(uint16_t));
    Xil_DCacheFlushRange((INTPTR)CONTEXT_BASE_ADDR,
                         CONTEXT_WORDS * sizeof(uint16_t));
}

static void load_vectors(void)
{
    memcpy((void *)(uintptr_t)Q_BASE_ADDR,
           fpt_q_bf16, sizeof(fpt_q_bf16));
    memcpy((void *)(uintptr_t)K_BASE_ADDR,
           fpt_k_bf16, sizeof(fpt_k_bf16));
    memcpy((void *)(uintptr_t)V_BASE_ADDR,
           fpt_v_bf16, sizeof(fpt_v_bf16));

    Xil_DCacheFlushRange((INTPTR)Q_BASE_ADDR, sizeof(fpt_q_bf16));
    Xil_DCacheFlushRange((INTPTR)K_BASE_ADDR, sizeof(fpt_k_bf16));
    Xil_DCacheFlushRange((INTPTR)V_BASE_ADDR, sizeof(fpt_v_bf16));
    clear_context();
}

static int reset_engine(void)
{
    uint32_t status = 0U;

    gpio_write(profile_control_word(PROF_STATUS, CTRL_SOFT_RESET));
    for (volatile uint32_t delay = 0U;
         delay < RESET_HOLD_LOOPS; ++delay) {
    }
    gpio_write(profile_control_word(PROF_STATUS, 0U));

    for (uint32_t poll = 0U; poll < RESET_POLL_LIMIT; ++poll) {
        status = gpio_status();
        if ((status & ST_READY) != 0U &&
            (status & (ST_BUSY | ST_DONE | ST_ERROR)) == 0U)
            return 0;
    }

    xil_printf("[FAIL] Engine did not return to READY after soft reset; status=0x%08lx\r\n",
               (unsigned long)status);
    return -1;
}

static uint32_t run_engine(uint32_t show_progress,
                           uint64_t *elapsed_ticks)
{
    uint32_t status = 0U;
    uint32_t last_group = 0xFFFFFFFFU;
    XTime start_time;
    XTime end_time;

    XTime_GetTime(&start_time);
    gpio_write(profile_control_word(PROF_STATUS, CTRL_START));
    gpio_write(profile_control_word(PROF_STATUS, 0U));

    for (uint32_t polls = 0U; polls < POLL_LIMIT; ++polls) {
        status = gpio_status();

        if (show_progress != 0U) {
            const uint32_t group = (status >> 8) & 0x7U;
            if ((status & ST_BUSY) != 0U && group != last_group) {
                xil_printf("Warm-up progress: active group %lu / %lu, status=0x%08lx\r\n",
                           (unsigned long)(group + 1U),
                           (unsigned long)FPT_RUN_GROUPS,
                           (unsigned long)status);
                last_group = group;
            }
        }

        if ((status & ST_DONE) != 0U)
            break;
    }
    XTime_GetTime(&end_time);

    *elapsed_ticks = (uint64_t)(end_time - start_time);
    return status;
}

static int compare_context(compare_stats_t *stats,
                           uint32_t print_strict_failures)
{
    const volatile uint16_t *actual =
        (const volatile uint16_t *)(uintptr_t)CONTEXT_BASE_ADDR;
    uint32_t printed = 0U;
    float max_abs_error = 0.0f;

    memset(stats, 0, sizeof(*stats));
    Xil_DCacheInvalidateRange((INTPTR)CONTEXT_BASE_ADDR,
                              CONTEXT_WORDS * sizeof(uint16_t));

    for (uint32_t i = 0U; i < CONTEXT_WORDS; ++i) {
        const uint16_t got = actual[i];
        const uint16_t expected = fpt_context_expected_bf16[i];
        const float diff = abs_float(bf16_to_float(got) -
                                     bf16_to_float(expected));
        const uint32_t ulp = bf16_ulp_distance(got, expected);

        if (got != expected)
            ++stats->exact_mismatches;
        if (diff > max_abs_error)
            max_abs_error = diff;

        if (diff > ABS_TOLERANCE) {
            ++stats->strict_abs_failures;
            if (ulp > stats->max_ulp_on_strict)
                stats->max_ulp_on_strict = ulp;

            if (ulp <= MAX_ALLOWED_ULP) {
                ++stats->strict_rescued_by_1ulp;
            } else {
                ++stats->combined_failures;
            }

            if (print_strict_failures != 0U &&
                printed < MAX_PRINTED_STRICT_FAILURES) {
                const uint32_t head_stride =
                    FPT_SEQ_LEN * FPT_HEAD_DIM;
                const uint32_t head = i / head_stride;
                const uint32_t rem = i % head_stride;
                const uint32_t row = rem / FPT_HEAD_DIM;
                const uint32_t col = rem % FPT_HEAD_DIM;
                const uint32_t abs_x1e9 =
                    (uint32_t)(diff * 1000000000.0f + 0.5f);

                xil_printf("Strict failure %lu: idx=%lu h=%lu row=%lu col=%lu exp=%04x got=%04x abs_x1e9=%lu ulp=%lu\r\n",
                           (unsigned long)(printed + 1U),
                           (unsigned long)i,
                           (unsigned long)head,
                           (unsigned long)row,
                           (unsigned long)col,
                           expected,
                           got,
                           (unsigned long)abs_x1e9,
                           (unsigned long)ulp);
                ++printed;
            }
        }
    }

    stats->max_abs_error_x1e9 =
        (uint32_t)(max_abs_error * 1000000000.0f + 0.5f);
    return stats->combined_failures == 0U ? 0 : -1;
}

static uint32_t status_is_pass(uint32_t status)
{
    const uint32_t required = ST_DONE | ST_V_LOADED |
                              ST_CORE_DONE | ST_CONTEXT_DONE;
    return ((status & required) == required &&
            (status & (ST_BUSY | ST_ERROR)) == 0U) ? 1U : 0U;
}

static uint32_t v31_flash_profile_is_pass(const hw_profile_t *profile)
{
    if (profile->causal_error_flags != 0U)
        return 0U;
#if FPT_V31_EXPECT_FLASH
    return (
        profile->qk_tiles_computed ==
            V31_QK_TILES_COMPUTED_EXPECTED &&
        profile->qk_tiles_skipped ==
            V31_QK_TILES_SKIPPED_EXPECTED &&
        profile->masked_tiles_emitted ==
            V31_MASKED_TILES_EMITTED_EXPECTED &&
        profile->pv_reductions_computed ==
            V31_CONTEXT_TILES_EXPECTED &&
        profile->pv_reductions_skipped ==
            V31_CONTEXT_TILES_BYPASSED_EXPECTED &&
        profile->native_vectors_captured ==
            V31_V_VECTORS_EXPECTED
    ) ? 1U : 0U;
#else
    return 1U;
#endif
}

static void print_compare_summary(const compare_stats_t *stats)
{
    xil_printf("Context exact mismatches       : %lu / %lu\r\n",
               (unsigned long)stats->exact_mismatches,
               (unsigned long)CONTEXT_WORDS);
    xil_printf("Strict abs failures (1e-4)    : %lu\r\n",
               (unsigned long)stats->strict_abs_failures);
    xil_printf("Strict failures rescued by 1ULP: %lu\r\n",
               (unsigned long)stats->strict_rescued_by_1ulp);
    xil_printf("Combined failures             : %lu\r\n",
               (unsigned long)stats->combined_failures);
    xil_printf("Max ULP on strict failures    : %lu\r\n",
               (unsigned long)stats->max_ulp_on_strict);
    xil_printf("Context max abs error x1e9    : %lu\r\n",
               (unsigned long)stats->max_abs_error_x1e9);
}

static uint64_t percent_x1000(uint64_t part, uint64_t total)
{
    return total == 0U ? 0U : mul_div_u64(part, 100000ULL, total);
}

static void print_percent_3(uint64_t part, uint64_t total)
{
    print_rate_3(percent_x1000(part, total));
    xil_printf("%%");
}

static void print_hw_profile(const hw_profile_t *p, uint64_t latency_ns)
{
    const uint64_t total = p->total_cycles;
    const uint64_t inferred_clock_hz = latency_ns == 0U ? 0U :
        mul_div_u64(total, 1000000000ULL, latency_ns);

    xil_printf("\r\nHARDWARE PROFILE (stage counters may overlap)\r\n");
    xil_printf("Total PL cycles             : %lu\r\n", (unsigned long)p->total_cycles);
    xil_printf("Inferred PL clock           : ");
    print_rate_3(inferred_clock_hz / 1000ULL);
    xil_printf(" MHz\r\n");

#define PRINT_STAGE(label, field) do { \
    xil_printf(label " : %lu (", (unsigned long)p->field); \
    print_percent_3(p->field, total); \
    xil_printf(")\r\n"); \
} while (0)

    PRINT_STAGE("V preload cycles            ", v_load_cycles);
    PRINT_STAGE("Core run cycles             ", core_run_cycles);
    PRINT_STAGE("RoPE-QK-Flash pipeline busy ", bc_busy_cycles);
    PRINT_STAGE("Legacy real-PV busy (unused)", pv_busy_cycles);
    PRINT_STAGE("RoPE busy                   ", rope_busy_cycles);
    PRINT_STAGE("QK busy                     ", qk_busy_cycles);
    PRINT_STAGE("Mask/reorder busy           ", mask_busy_cycles);
    PRINT_STAGE("Flash consumer busy         ", softmax_busy_cycles);
    PRINT_STAGE("Flash fusion backend busy   ", bc_backend_busy_cycles);
    PRINT_STAGE("Legacy TILE4 capture (unused)", capture_busy_cycles);
    PRINT_STAGE("Context transfer            ", context_transfer_cycles);
    PRINT_STAGE("Legacy B+C/PV overlap       ", bc_pv_overlap_cycles);
    PRINT_STAGE("Core stage idle             ", core_idle_cycles);
    PRINT_STAGE("Legacy repack stall         ", repack_stall_cycles);
    PRINT_STAGE("Legacy real-PV feed stall   ", pv_feed_stall_cycles);
    PRINT_STAGE("Flash output stall          ", softmax_stall_cycles);
    PRINT_STAGE("Inter-stage wait            ", interstage_wait_cycles);
    PRINT_STAGE("Raw Q/K request wait        ", raw_wait_cycles);
    PRINT_STAGE("Raw Q/K reader busy         ", raw_busy_cycles);
    PRINT_STAGE("DDR read master busy        ", ddr_read_busy_cycles);
    PRINT_STAGE("Context writer busy         ", context_busy_cycles);
    PRINT_STAGE("Context backpressure        ", context_backpressure_cycles);
    PRINT_STAGE("DDR write master busy       ", ddr_write_busy_cycles);
#undef PRINT_STAGE

    xil_printf("Raw pair requests accepted  : %lu\r\n", (unsigned long)p->raw_req_count);
    xil_printf("DDR read commands / beats   : %lu / %lu (%lu bytes)\r\n",
               (unsigned long)p->read_command_count,
               (unsigned long)p->read_beat_count,
               (unsigned long)(p->read_beat_count * 8U));
    xil_printf("DDR write commands / beats  : %lu / %lu (%lu bytes)\r\n",
               (unsigned long)p->write_command_count,
               (unsigned long)p->write_beat_count,
               (unsigned long)(p->write_beat_count * 8U));
    xil_printf("Context words accepted      : %lu\r\n",
               (unsigned long)p->context_word_count);
    xil_printf("Error detail bitmap         : 0x%08lx\r\n",
               (unsigned long)p->error_detail);
    xil_printf("QK tiles computed / skipped : %lu / %lu\r\n",
               (unsigned long)p->qk_tiles_computed,
               (unsigned long)p->qk_tiles_skipped);
    xil_printf("Masked QK tiles emitted     : %lu\r\n",
               (unsigned long)p->masked_tiles_emitted);
    xil_printf("Flash context tiles / reserve: %lu / %lu\r\n",
               (unsigned long)p->pv_reductions_computed,
               (unsigned long)p->pv_reductions_skipped);
    xil_printf("Eight-lane V-cache vectors  : %lu\r\n",
               (unsigned long)p->native_vectors_captured);
    xil_printf("Causal error flags          : 0x%08lx\r\n",
               (unsigned long)p->causal_error_flags);
    for (uint32_t group = 0U; group < FPT_RUN_GROUPS; ++group)
        xil_printf("Group %lu cycles             : %lu\r\n",
                   (unsigned long)group,
                   (unsigned long)p->group_cycles[group]);
}

static void print_run_result(uint32_t run_index,
                             const run_result_t *result)
{
    xil_printf("Run %02lu: latency_ms=", (unsigned long)(run_index + 1U));
    print_ms_3(result->latency_ns);
    xil_printf(" ticks=");
    print_u64(result->timer_ticks);
    xil_printf(" status=0x%08lx pl_cycles=%lu strict=%lu combined=%lu %s\r\n",
               (unsigned long)result->status,
               (unsigned long)result->profile.total_cycles,
               (unsigned long)result->compare.strict_abs_failures,
               (unsigned long)result->compare.combined_failures,
               result->passed != 0U ? "PASS" : "FAIL");

    /* Machine-readable line for python/parse_performance_log.py. */
    xil_printf("PERF_CSV,%lu,", (unsigned long)(run_index + 1U));
    print_u64(result->timer_ticks);
    xil_printf(",");
    print_u64(result->latency_ns);
    xil_printf(",0x%08lx,%lu,%lu,%lu\r\n",
               (unsigned long)result->status,
               (unsigned long)result->compare.exact_mismatches,
               (unsigned long)result->compare.strict_abs_failures,
               (unsigned long)result->compare.combined_failures);

    xil_printf("HWPROF_CSV,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\r\n",
               (unsigned long)(run_index + 1U),
               (unsigned long)result->profile.total_cycles,
               (unsigned long)result->profile.v_load_cycles,
               (unsigned long)result->profile.core_run_cycles,
               (unsigned long)result->profile.raw_wait_cycles,
               (unsigned long)result->profile.raw_busy_cycles,
               (unsigned long)result->profile.bc_busy_cycles,
               (unsigned long)result->profile.pv_busy_cycles,
               (unsigned long)result->profile.context_busy_cycles,
               (unsigned long)result->profile.context_backpressure_cycles,
               (unsigned long)result->profile.ddr_read_busy_cycles,
               (unsigned long)result->profile.ddr_write_busy_cycles,
               (unsigned long)result->profile.raw_req_count,
               (unsigned long)result->profile.read_beat_count,
               (unsigned long)result->profile.write_beat_count,
               (unsigned long)result->profile.context_word_count,
               (unsigned long)result->profile.group_cycles[0],
               (unsigned long)result->profile.group_cycles[1],
               (unsigned long)result->profile.group_cycles[2],
               (unsigned long)result->profile.group_cycles[3],
               (unsigned long)result->profile.group_cycles[4],
               (unsigned long)result->profile.group_cycles[5],
               (unsigned long)result->profile.group_cycles[6],
               (unsigned long)result->profile.group_cycles[7],
               (unsigned long)result->profile.read_command_count,
               (unsigned long)result->profile.write_command_count,
               (unsigned long)result->profile.error_detail);

    xil_printf("HWPROF_FINE_CSV,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\r\n",
               (unsigned long)(run_index + 1U),
               (unsigned long)result->profile.rope_busy_cycles,
               (unsigned long)result->profile.qk_busy_cycles,
               (unsigned long)result->profile.mask_busy_cycles,
               (unsigned long)result->profile.softmax_busy_cycles,
               (unsigned long)result->profile.bc_backend_busy_cycles,
               (unsigned long)result->profile.capture_busy_cycles,
               (unsigned long)result->profile.context_transfer_cycles,
               (unsigned long)result->profile.bc_pv_overlap_cycles,
               (unsigned long)result->profile.core_idle_cycles,
               (unsigned long)result->profile.repack_stall_cycles,
               (unsigned long)result->profile.pv_feed_stall_cycles,
               (unsigned long)result->profile.softmax_stall_cycles,
               (unsigned long)result->profile.interstage_wait_cycles);
    xil_printf("V26_CAUSAL_CSV,%lu,%lu,%lu,%lu,%lu,%lu,%lu,0x%08lx\r\n",
               (unsigned long)(run_index + 1U),
               (unsigned long)result->profile.qk_tiles_computed,
               (unsigned long)result->profile.qk_tiles_skipped,
               (unsigned long)result->profile.masked_tiles_emitted,
               (unsigned long)result->profile.pv_reductions_computed,
               (unsigned long)result->profile.pv_reductions_skipped,
               (unsigned long)result->profile.native_vectors_captured,
               (unsigned long)result->profile.causal_error_flags);
    xil_printf("V31_FLASH_CSV,%lu,%lu,%lu,%lu,0x%08lx\r\n",
               (unsigned long)(run_index + 1U),
               (unsigned long)result->profile.pv_reductions_computed,
               (unsigned long)result->profile.pv_reductions_skipped,
               (unsigned long)result->profile.native_vectors_captured,
               (unsigned long)result->profile.causal_error_flags);
}

int main(void)
{
    run_result_t results[MEASURED_RUNS];
    uint32_t pass_runs = 0U;
    uint32_t deterministic_runs = 0U;
    uint32_t baseline_exact = 0U;
    uint32_t baseline_strict = 0U;
    uint64_t load_ticks = 0U;
    XTime load_start;
    XTime load_end;

    xil_printf("\r\n================================================\r\n");
    xil_printf("FPT XCZU15EG FlashAttention v3.1.4 QK4/V8 causal-bypass benchmark\r\n");
    xil_printf("%lu GQA groups, %luQ/%luKV, S=%lu, D=%lu, BF16\r\n",
               (unsigned long)FPT_RUN_GROUPS,
               (unsigned long)FPT_Q_HEADS,
               (unsigned long)FPT_KV_HEADS,
               (unsigned long)FPT_SEQ_LEN,
               (unsigned long)FPT_HEAD_DIM);
    xil_printf("Measured scope: START MMIO pulse -> ST_DONE observed\r\n");
    xil_printf("Warm-up runs=%lu, measured runs=%lu\r\n",
               (unsigned long)WARMUP_RUNS,
               (unsigned long)MEASURED_RUNS);
    xil_printf("Pass policy: abs<=1e-4 OR BF16 distance<=1 ULP\r\n");
    xil_printf("A53 timer frequency: ");
    print_u64((uint64_t)COUNTS_PER_SECOND);
    xil_printf(" Hz\r\n");
    xil_printf("GPIO base   : 0x%08lx\r\n", (unsigned long)FPT_GPIO_BASE);
    xil_printf("Q/K/V/C base: %08x/%08x/%08x/%08x\r\n",
               Q_BASE_ADDR, K_BASE_ADDR, V_BASE_ADDR,
               CONTEXT_BASE_ADDR);
    xil_printf("================================================\r\n");

    Xil_Out32(FPT_GPIO_BASE + GPIO_TRI_CH1, 0x00000000U);
    Xil_Out32(FPT_GPIO_BASE + GPIO_TRI_CH2, 0xFFFFFFFFU);

    if (reset_engine() != 0)
        return 1;

    xil_printf("Loading full golden Q/K/V into PS DDR...\r\n");
    XTime_GetTime(&load_start);
    load_vectors();
    XTime_GetTime(&load_end);
    load_ticks = (uint64_t)(load_end - load_start);
    xil_printf("Host vector load+flush time: ");
    print_ms_3(mul_div_u64(load_ticks, 1000000000ULL,
                           (uint64_t)COUNTS_PER_SECOND));
    xil_printf(" ms (excluded from accelerator latency)\r\n");

    xil_printf("\r\n--- Warm-up and correctness gate ---\r\n");
    for (uint32_t warmup = 0U; warmup < WARMUP_RUNS; ++warmup) {
        compare_stats_t warmup_compare;
        uint64_t warmup_ticks = 0U;

        clear_context();
        if (reset_engine() != 0)
            return 2;

        const uint32_t status = run_engine(1U, &warmup_ticks);
        hw_profile_t warmup_profile;
        read_hw_profile(&warmup_profile);
        const int compare_rc = compare_context(&warmup_compare, 1U);

        xil_printf("Warm-up status: 0x%08lx, latency_ms=",
                   (unsigned long)status);
        print_ms_3(mul_div_u64(warmup_ticks, 1000000000ULL,
                               (uint64_t)COUNTS_PER_SECOND));
        xil_printf("\r\n");
        print_compare_summary(&warmup_compare);
        print_hw_profile(&warmup_profile,
                         mul_div_u64(warmup_ticks, 1000000000ULL,
                                     (uint64_t)COUNTS_PER_SECOND));

        if (status_is_pass(status) == 0U ||
            v31_flash_profile_is_pass(&warmup_profile) == 0U ||
            compare_rc != 0) {
            xil_printf("[FAIL] Warm-up correctness gate failed; benchmark aborted.\r\n");
            return 3;
        }
    }

    xil_printf("[PASS] Warm-up correctness gate passed\r\n");
    xil_printf("\r\n--- Ten measured runs (no UART output inside timed region) ---\r\n");

    for (uint32_t run = 0U; run < MEASURED_RUNS; ++run) {
        uint64_t ticks = 0U;

        clear_context();
        if (reset_engine() != 0)
            return 4;

        results[run].status = run_engine(0U, &ticks);
        results[run].timer_ticks = ticks;
        results[run].latency_ns =
            mul_div_u64(ticks, 1000000000ULL,
                        (uint64_t)COUNTS_PER_SECOND);
        read_hw_profile(&results[run].profile);

        const int compare_rc = compare_context(&results[run].compare, 0U);
        results[run].passed =
            (status_is_pass(results[run].status) != 0U &&
             v31_flash_profile_is_pass(&results[run].profile) != 0U &&
             compare_rc == 0) ? 1U : 0U;

        if (results[run].passed != 0U)
            ++pass_runs;

        if (run == 0U) {
            baseline_exact = results[run].compare.exact_mismatches;
            baseline_strict = results[run].compare.strict_abs_failures;
            deterministic_runs = 1U;
        } else if (results[run].compare.exact_mismatches == baseline_exact &&
                   results[run].compare.strict_abs_failures == baseline_strict) {
            ++deterministic_runs;
        }

        print_run_result(run, &results[run]);
    }

    uint64_t min_ns = results[0].latency_ns;
    uint64_t max_ns = results[0].latency_ns;
    uint64_t sum_ns = 0U;
    uint64_t sum_ticks = 0U;

    for (uint32_t run = 0U; run < MEASURED_RUNS; ++run) {
        if (results[run].latency_ns < min_ns)
            min_ns = results[run].latency_ns;
        if (results[run].latency_ns > max_ns)
            max_ns = results[run].latency_ns;
        sum_ns += results[run].latency_ns;
        sum_ticks += results[run].timer_ticks;
    }

    const uint64_t avg_ns = sum_ns / MEASURED_RUNS;
    const uint64_t avg_ticks = sum_ticks / MEASURED_RUNS;
    __uint128_t squared_diff_sum = 0U;

    for (uint32_t run = 0U; run < MEASURED_RUNS; ++run) {
        const uint64_t diff = results[run].latency_ns >= avg_ns
            ? results[run].latency_ns - avg_ns
            : avg_ns - results[run].latency_ns;
        squared_diff_sum += (__uint128_t)diff * (__uint128_t)diff;
    }

    uint64_t variance_ns2 =
        (uint64_t)(squared_diff_sum / MEASURED_RUNS);
    const uint64_t stddev_ns = integer_sqrt_u64(variance_ns2);
    const uint64_t elements_per_second =
        mul_div_u64((uint64_t)CONTEXT_WORDS,
                    (uint64_t)COUNTS_PER_SECOND,
                    avg_ticks);
    const uint64_t groups_per_second_x1000 =
        mul_div_u64((uint64_t)FPT_RUN_GROUPS * 1000ULL,
                    (uint64_t)COUNTS_PER_SECOND,
                    avg_ticks);
    const uint64_t effective_gflops_x1000 =
        mul_div_u64(QK_PV_FLOPS,
                    (uint64_t)COUNTS_PER_SECOND,
                    avg_ticks) / 1000000ULL;

    hw_profile_t avg_profile;
    memset(&avg_profile, 0, sizeof(avg_profile));
#define AVG_FIELD(field) do { \
    uint64_t sum = 0U; \
    for (uint32_t r = 0U; r < MEASURED_RUNS; ++r) sum += results[r].profile.field; \
    avg_profile.field = (uint32_t)(sum / MEASURED_RUNS); \
} while (0)
    AVG_FIELD(total_cycles);
    AVG_FIELD(v_load_cycles);
    AVG_FIELD(core_run_cycles);
    AVG_FIELD(raw_wait_cycles);
    AVG_FIELD(raw_busy_cycles);
    AVG_FIELD(bc_busy_cycles);
    AVG_FIELD(pv_busy_cycles);
    AVG_FIELD(context_busy_cycles);
    AVG_FIELD(context_backpressure_cycles);
    AVG_FIELD(ddr_read_busy_cycles);
    AVG_FIELD(ddr_write_busy_cycles);
    AVG_FIELD(raw_req_count);
    AVG_FIELD(read_beat_count);
    AVG_FIELD(write_beat_count);
    AVG_FIELD(context_word_count);
    AVG_FIELD(read_command_count);
    AVG_FIELD(write_command_count);
    AVG_FIELD(error_detail);
    AVG_FIELD(rope_busy_cycles);
    AVG_FIELD(qk_busy_cycles);
    AVG_FIELD(mask_busy_cycles);
    AVG_FIELD(softmax_busy_cycles);
    AVG_FIELD(bc_backend_busy_cycles);
    AVG_FIELD(capture_busy_cycles);
    AVG_FIELD(context_transfer_cycles);
    AVG_FIELD(bc_pv_overlap_cycles);
    AVG_FIELD(core_idle_cycles);
    AVG_FIELD(repack_stall_cycles);
    AVG_FIELD(pv_feed_stall_cycles);
    AVG_FIELD(softmax_stall_cycles);
    AVG_FIELD(interstage_wait_cycles);
    AVG_FIELD(qk_tiles_computed);
    AVG_FIELD(qk_tiles_skipped);
    AVG_FIELD(masked_tiles_emitted);
    AVG_FIELD(pv_reductions_computed);
    AVG_FIELD(pv_reductions_skipped);
    AVG_FIELD(native_vectors_captured);
    AVG_FIELD(causal_error_flags);
#undef AVG_FIELD
    for (uint32_t g = 0U; g < FPT_RUN_GROUPS; ++g) {
        uint64_t sum = 0U;
        for (uint32_t r = 0U; r < MEASURED_RUNS; ++r)
            sum += results[r].profile.group_cycles[g];
        avg_profile.group_cycles[g] = (uint32_t)(sum / MEASURED_RUNS);
    }

    xil_printf("\r\n================================================\r\n");
    xil_printf("PERFORMANCE SUMMARY\r\n");
    xil_printf("Timing scope             : START pulse -> DONE observed\r\n");
    xil_printf("Measured runs            : %lu\r\n",
               (unsigned long)MEASURED_RUNS);
    xil_printf("Correct runs             : %lu / %lu\r\n",
               (unsigned long)pass_runs,
               (unsigned long)MEASURED_RUNS);
    xil_printf("Deterministic result runs: %lu / %lu\r\n",
               (unsigned long)deterministic_runs,
               (unsigned long)MEASURED_RUNS);
    xil_printf("Minimum latency          : ");
    print_ms_3(min_ns);
    xil_printf(" ms\r\n");
    xil_printf("Average latency          : ");
    print_ms_3(avg_ns);
    xil_printf(" ms\r\n");
    xil_printf("Maximum latency          : ");
    print_ms_3(max_ns);
    xil_printf(" ms\r\n");
    xil_printf("Latency stddev           : ");
    print_ms_3(stddev_ns);
    xil_printf(" ms\r\n");
    xil_printf("Peak-to-peak jitter      : ");
    print_ms_3(max_ns - min_ns);
    xil_printf(" ms\r\n");
    xil_printf("Average A53 timer ticks  : ");
    print_u64(avg_ticks);
    xil_printf("\r\n");
    xil_printf("Context throughput       : ");
    print_u64(elements_per_second);
    xil_printf(" elements/s\r\n");
    xil_printf("GQA group rate           : ");
    print_rate_3(groups_per_second_x1000);
    xil_printf(" groups/s\r\n");
    xil_printf("Effective QK+PV rate     : ");
    print_rate_3(effective_gflops_x1000);
    xil_printf(" GFLOP/s\r\n");
    xil_printf("QK+PV operation count    : ");
    print_u64(QK_PV_FLOPS);
    xil_printf(" FLOPs/run\r\n");
    xil_printf("Note: RoPE/Softmax are included in latency but excluded from the FLOP numerator.\r\n");
    print_hw_profile(&avg_profile, avg_ns);
    xil_printf("Note: busy/wait counters overlap and must not be summed as exclusive phases.\r\n");
    xil_printf("================================================\r\n");

    xil_printf("PERF_SUMMARY_CSV,%lu,%lu,",
               (unsigned long)pass_runs,
               (unsigned long)deterministic_runs);
    print_u64(min_ns);
    xil_printf(",");
    print_u64(avg_ns);
    xil_printf(",");
    print_u64(max_ns);
    xil_printf(",");
    print_u64(stddev_ns);
    xil_printf(",");
    print_u64(elements_per_second);
    xil_printf(",");
    print_u64(groups_per_second_x1000);
    xil_printf(",");
    print_u64(effective_gflops_x1000);
    xil_printf("\r\n");

    if (pass_runs != MEASURED_RUNS) {
        xil_printf("[FAIL] One or more measured runs failed status or BF16 numerical verification.\r\n");
        return 5;
    }

    if (deterministic_runs != MEASURED_RUNS) {
        xil_printf("[FAIL] Numerical mismatch counts changed between repeated runs.\r\n");
        return 6;
    }

    xil_printf("[PASS] v3.1 FlashAttention ten-run correctness and profiling passed\r\n");
    
    return 0;
}
