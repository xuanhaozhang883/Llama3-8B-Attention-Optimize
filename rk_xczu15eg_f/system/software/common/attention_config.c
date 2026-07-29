#include "attention_config.h"

#include <string.h>

int rk_attention_pack_qkv(uint8_t *frame, size_t frame_bytes,
                          const uint16_t *q, const uint16_t *k,
                          const uint16_t *v)
{
    uint8_t *cursor;

    if (frame == NULL || q == NULL || k == NULL || v == NULL)
        return -1;
    if (frame_bytes < RK_ATTN_INPUT_BYTES)
        return -2;
    if (((uintptr_t)frame % RK_ATTN_CACHELINE_BYTES) != 0u)
        return -3;

    cursor = frame;
    memcpy(cursor, q, RK_ATTN_Q_BYTES);
    cursor += RK_ATTN_Q_BYTES;
    memcpy(cursor, k, RK_ATTN_K_BYTES);
    cursor += RK_ATTN_K_BYTES;
    memcpy(cursor, v, RK_ATTN_V_BYTES);
    return 0;
}

size_t rk_attention_compare_bf16(const uint16_t *actual,
                                 const uint16_t *expected,
                                 size_t words,
                                 size_t *first_mismatch)
{
    size_t mismatches = 0u;
    size_t first = (size_t)-1;
    size_t index;

    if (actual == NULL || expected == NULL) {
        if (first_mismatch != NULL)
            *first_mismatch = 0u;
        return words;
    }

    for (index = 0u; index < words; ++index) {
        if (actual[index] != expected[index]) {
            if (mismatches == 0u)
                first = index;
            ++mismatches;
        }
    }
    if (first_mismatch != NULL)
        *first_mismatch = first;
    return mismatches;
}
