#include "attention_mask.hpp"

extern "C" {
void attention_mask(
    const score_t raw_scores[AM_MAX_ELEMENTS],
    score_t masked_scores[AM_MAX_ELEMENTS],
    int q_heads,
    int seq_len,
    bool causal,
    score_t mask_value
) {
#pragma HLS INTERFACE m_axi     port=raw_scores    offset=slave bundle=gmem0 depth=AM_MAX_ELEMENTS
#pragma HLS INTERFACE m_axi     port=masked_scores offset=slave bundle=gmem1 depth=AM_MAX_ELEMENTS

#pragma HLS INTERFACE s_axilite port=raw_scores    bundle=control
#pragma HLS INTERFACE s_axilite port=masked_scores bundle=control
#pragma HLS INTERFACE s_axilite port=q_heads       bundle=control
#pragma HLS INTERFACE s_axilite port=seq_len       bundle=control
#pragma HLS INTERFACE s_axilite port=causal        bundle=control
#pragma HLS INTERFACE s_axilite port=mask_value    bundle=control
#pragma HLS INTERFACE s_axilite port=return        bundle=control


    if (q_heads <= 0 || q_heads > AM_MAX_Q_HEADS ||
        seq_len <= 0 || seq_len > AM_MAX_SEQ_LEN) {
        return;
    }

    int idx = 0;

QH_LOOP:
    for (int qh = 0; qh < q_heads; ++qh) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=32

QT_LOOP:
        for (int qt = 0; qt < seq_len; ++qt) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=128

KT_LOOP:
            for (int kt = 0; kt < seq_len; ++kt) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=128
#pragma HLS PIPELINE II=1

                const bool future_token = causal && (kt > qt);

                // Mask rule:
                //   if future token, write mask_value;
                //   otherwise, keep original BF16 raw score word.
                // idx is incremented instead of recomputed with dynamic
                // multiplication to keep the pipelined loop DSP-free.
                masked_scores[idx] = future_token ? mask_value : raw_scores[idx];

                ++idx;
            }
        }
    }
}
}
