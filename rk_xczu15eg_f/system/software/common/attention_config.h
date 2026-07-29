#ifndef RK_ATTENTION_CONFIG_H
#define RK_ATTENTION_CONFIG_H

#include <stddef.h>
#include <stdint.h>

#define RK_ATTN_SEQ_LEN             128u
#define RK_ATTN_HEAD_DIM            128u
#define RK_ATTN_Q_HEADS             4u
#define RK_ATTN_KV_HEADS            1u
#define RK_ATTN_AXIS_BYTES          16u
#define RK_ATTN_CACHELINE_BYTES     64u

#define RK_ATTN_Q_WORDS \
    (RK_ATTN_Q_HEADS * RK_ATTN_SEQ_LEN * RK_ATTN_HEAD_DIM)
#define RK_ATTN_K_WORDS \
    (RK_ATTN_KV_HEADS * RK_ATTN_SEQ_LEN * RK_ATTN_HEAD_DIM)
#define RK_ATTN_V_WORDS \
    (RK_ATTN_KV_HEADS * RK_ATTN_SEQ_LEN * RK_ATTN_HEAD_DIM)
#define RK_ATTN_CONTEXT_WORDS       RK_ATTN_Q_WORDS

#define RK_ATTN_Q_BYTES             (RK_ATTN_Q_WORDS * 2u)
#define RK_ATTN_K_BYTES             (RK_ATTN_K_WORDS * 2u)
#define RK_ATTN_V_BYTES             (RK_ATTN_V_WORDS * 2u)
#define RK_ATTN_INPUT_BYTES \
    (RK_ATTN_Q_BYTES + RK_ATTN_K_BYTES + RK_ATTN_V_BYTES)
#define RK_ATTN_OUTPUT_BYTES \
    (RK_ATTN_CONTEXT_WORDS * 2u)

#define RK_ATTN_INPUT_BEATS \
    (RK_ATTN_INPUT_BYTES / RK_ATTN_AXIS_BYTES)
#define RK_ATTN_OUTPUT_BEATS \
    (RK_ATTN_OUTPUT_BYTES / RK_ATTN_AXIS_BYTES)

#define RK_ATTN_REG_CONTROL         0x00u
#define RK_ATTN_REG_STATUS          0x04u
#define RK_ATTN_REG_KERNEL_LO       0x08u
#define RK_ATTN_REG_KERNEL_HI       0x0Cu
#define RK_ATTN_REG_INPUT_BEATS     0x10u
#define RK_ATTN_REG_OUTPUT_BEATS    0x14u
#define RK_ATTN_REG_STALL_LO        0x18u
#define RK_ATTN_REG_STALL_HI        0x1Cu
#define RK_ATTN_REG_BUILD_ID        0x20u
#define RK_ATTN_REG_ERROR_VECTOR    0x24u

#define RK_ATTN_CONTROL_START       (1u << 0)
#define RK_ATTN_CONTROL_CLEAR       (1u << 1)

#define RK_ATTN_STATUS_READY        (1u << 0)
#define RK_ATTN_STATUS_BUSY         (1u << 1)
#define RK_ATTN_STATUS_FRAME_LOADED (1u << 2)
#define RK_ATTN_STATUS_PROTOCOL_ERR (1u << 3)
#define RK_ATTN_STATUS_DONE         (1u << 4)
#define RK_ATTN_STATUS_ERROR        (1u << 5)

#if (RK_ATTN_INPUT_BYTES % RK_ATTN_AXIS_BYTES) != 0
#error "Q/K/V frame must be an integer number of AXI beats"
#endif

#if (RK_ATTN_OUTPUT_BYTES % RK_ATTN_AXIS_BYTES) != 0
#error "Context frame must be an integer number of AXI beats"
#endif

int rk_attention_pack_qkv(uint8_t *frame, size_t frame_bytes,
                          const uint16_t *q, const uint16_t *k,
                          const uint16_t *v);

size_t rk_attention_compare_bf16(const uint16_t *actual,
                                 const uint16_t *expected,
                                 size_t words,
                                 size_t *first_mismatch);

#endif
