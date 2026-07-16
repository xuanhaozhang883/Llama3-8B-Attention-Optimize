#ifndef ATTENTION_MASK_HPP
#define ATTENTION_MASK_HPP

#include <ap_int.h>


static const int AM_MAX_Q_HEADS = 32;
static const int AM_MAX_SEQ_LEN = 128;
static const int AM_MAX_ELEMENTS = AM_MAX_Q_HEADS * AM_MAX_SEQ_LEN * AM_MAX_SEQ_LEN;

// BF16 raw word. The mask kernel copies 16-bit words; it does not do
// floating-point arithmetic.
typedef ap_uint<16> score_t;


static const score_t AM_MASK_NEG_INF_BF16 = 0xFF80;


static const score_t AM_MASK_NEG_LARGE_BF16 = 0xCE6E;


static inline int score_index(
    int q_head,
    int q_token,
    int k_token,
    int seq_len
) {
    return (q_head * seq_len + q_token) * seq_len + k_token;
}

extern "C" {
void attention_mask(
    const score_t raw_scores[AM_MAX_ELEMENTS],
    score_t masked_scores[AM_MAX_ELEMENTS],
    int q_heads,
    int seq_len,
    bool causal,
    score_t mask_value
);
}

#endif
