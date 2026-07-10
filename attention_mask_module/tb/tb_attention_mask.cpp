#include "../src/attention_mask.hpp"

#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <vector>


static score_t make_score_word(int qh, int qt, int kt) {
    unsigned int value =
        ((qh & 0x1F) << 11) ^
        ((qt & 0x7F) << 4) ^
        (kt & 0x0F);

   
    value = (value + 1) & 0xFFFF;

    return static_cast<score_t>(value);
}

static int run_case(
    int q_heads,
    int seq_len,
    bool causal,
    score_t mask_value
) {
    const int elements = q_heads * seq_len * seq_len;

    std::vector<score_t> raw(AM_MAX_ELEMENTS);
    std::vector<score_t> masked(AM_MAX_ELEMENTS);

    // Initialize full arrays.
    for (int i = 0; i < AM_MAX_ELEMENTS; ++i) {
        raw[i] = 0;
        masked[i] = 0xDEAD;
    }

    // Fill active region.
    for (int qh = 0; qh < q_heads; ++qh) {
        for (int qt = 0; qt < seq_len; ++qt) {
            for (int kt = 0; kt < seq_len; ++kt) {
                const int idx = score_index(qh, qt, kt, seq_len);
                raw[idx] = make_score_word(qh, qt, kt);
            }
        }
    }

    // Run DUT.
    attention_mask(
        raw.data(),
        masked.data(),
        q_heads,
        seq_len,
        causal,
        mask_value
    );

    // Check active region.
    int errors = 0;

    for (int qh = 0; qh < q_heads; ++qh) {
        for (int qt = 0; qt < seq_len; ++qt) {
            for (int kt = 0; kt < seq_len; ++kt) {
                const int idx = score_index(qh, qt, kt, seq_len);

                const bool future_token = causal && (kt > qt);
                const score_t expected = future_token ? mask_value : raw[idx];

                if (masked[idx] != expected) {
                    if (errors < 8) {
                        std::cerr << "Mismatch"
                                  << " qh=" << qh
                                  << " qt=" << qt
                                  << " kt=" << kt
                                  << " idx=" << idx
                                  << " got=0x" << std::hex << std::setw(4)
                                  << std::setfill('0') << masked[idx].to_uint()
                                  << " expected=0x" << std::hex << std::setw(4)
                                  << std::setfill('0') << expected.to_uint()
                                  << std::dec << "\n";
                    }
                    ++errors;
                }
            }
        }
    }

    if (errors != 0) {
        std::cerr << "FAIL"
                  << " q_heads=" << q_heads
                  << " seq_len=" << seq_len
                  << " causal=" << causal
                  << " elements=" << elements
                  << " errors=" << errors
                  << "\n";
        return 1;
    }

    std::cout << "PASS"
              << " q_heads=" << q_heads
              << " seq_len=" << seq_len
              << " causal=" << causal
              << " elements=" << elements
              << " mask_value=0x" << std::hex << std::setw(4)
              << std::setfill('0') << mask_value.to_uint()
              << std::dec << "\n";

    return 0;
}

int main() {
    int failed = 0;

    // Small sanity case for early HLS simulation.
    failed += run_case(4, 16, true,  AM_MASK_NEG_INF_BF16);

    // No causal mask case:
    // output should exactly equal input in active region.
    failed += run_case(4, 16, false, AM_MASK_NEG_INF_BF16);

    // Llama3-like GQA attention score shape:
    // q_heads=32, seq_len=128.
    // Note:
    // kv_heads=8 and group_size=4 matter in QK score generation,
    // not in this mask module. Mask operates on q_heads score matrices.
    failed += run_case(32, 128, true, AM_MASK_NEG_INF_BF16);

    if (failed != 0) {
        std::cerr << "Attention mask testbench FAILED\n";
        return EXIT_FAILURE;
    }

    std::cout << "Attention mask testbench PASSED\n";
    return EXIT_SUCCESS;
}
