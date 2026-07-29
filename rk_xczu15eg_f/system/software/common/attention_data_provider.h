#ifndef RK_ATTENTION_DATA_PROVIDER_H
#define RK_ATTENTION_DATA_PROVIDER_H

#include <stddef.h>
#include <stdint.h>

enum {
    RK_ATTN_DATA_REAL = 0,
    RK_ATTN_DATA_PLACEHOLDER = 1
};

// Weak defaults are supplied by attention_data_provider.c.  A competition
// data component can provide strong definitions with the same signatures to
// fill model-exported BF16 Q/K/V and Context Golden arrays.
int rk_attention_prepare_qkv(uint16_t *q, size_t q_words,
                             uint16_t *k, size_t k_words,
                             uint16_t *v, size_t v_words);

int rk_attention_prepare_golden(uint16_t *golden, size_t words);

#endif
