#include "attention_data_provider.h"

#include <string.h>

__attribute__((weak))
int rk_attention_prepare_qkv(uint16_t *q, size_t q_words,
                             uint16_t *k, size_t k_words,
                             uint16_t *v, size_t v_words)
{
    if (q == NULL || k == NULL || v == NULL)
        return -1;
    memset(q, 0, q_words * sizeof(*q));
    memset(k, 0, k_words * sizeof(*k));
    memset(v, 0, v_words * sizeof(*v));
    return RK_ATTN_DATA_PLACEHOLDER;
}

__attribute__((weak))
int rk_attention_prepare_golden(uint16_t *golden, size_t words)
{
    if (golden == NULL)
        return -1;
    memset(golden, 0, words * sizeof(*golden));
    return RK_ATTN_DATA_PLACEHOLDER;
}
