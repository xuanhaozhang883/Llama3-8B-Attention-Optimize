#include "../src/attention_mask.hpp"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>


static bool try_open(
    const std::vector<std::string>& candidates,
    std::ifstream& stream,
    std::string& opened_path
) {
    for (std::vector<std::string>::const_iterator it = candidates.begin();
         it != candidates.end();
         ++it) {
        stream.open(it->c_str());
        if (stream.is_open()) {
            opened_path = *it;
            return true;
        }
        stream.clear();
    }
    return false;
}


static int read_hex_words(
    const std::vector<std::string>& candidates,
    std::vector<score_t>& data,
    int elements
) {
    std::ifstream f;
    std::string opened_path;
    if (!try_open(candidates, f, opened_path)) {
        std::cerr << "Cannot open file. Tried:\n";
        for (std::vector<std::string>::const_iterator it = candidates.begin();
             it != candidates.end();
             ++it) {
            std::cerr << "  " << *it << "\n";
        }
        std::cerr
            << "If Vitis C Simulation cannot find the file, use an absolute\n"
            << "Windows path such as:\n"
            << "  D:/00game/FPT/Attention_Mask/Attention_Mask_HLS_IP_release/"
            << "mask_test_vectors/raw_scores.hex\n";
        return 1;
    }

    std::string line;
    int count = 0;
    while (count < elements && std::getline(f, line)) {
        if (line.empty()) {
            continue;
        }
        unsigned int word = 0;
        std::stringstream ss(line);
        ss >> std::hex >> word;
        if (ss.fail() || word > 0xFFFFU) {
            std::cerr << "Bad hex word in " << opened_path
                      << " at element " << count
                      << ": " << line << "\n";
            return 1;
        }
        data[count] = static_cast<score_t>(word & 0xFFFFU);
        ++count;
    }

    if (count != elements) {
        std::cerr << "Wrong element count in " << opened_path
                  << ": expected=" << elements
                  << " got=" << count << "\n";
        return 1;
    }

    std::cout << "Loaded " << count << " words from " << opened_path << "\n";
    return 0;
}


int main() {
    const int q_heads = 4;
    const int seq_len = 128;
    const int elements = q_heads * seq_len * seq_len;
    const score_t mask_value = AM_MASK_NEG_INF_BF16;

    std::vector<score_t> raw(AM_MAX_ELEMENTS);
    std::vector<score_t> out(AM_MAX_ELEMENTS);
    std::vector<score_t> golden(AM_MAX_ELEMENTS);

    // Default relative paths are for running from the release directory.
    // If Vitis runs C Simulation from solution/csim/build and cannot find
    // these files, use absolute paths with forward slashes, for example:
    // D:/00game/FPT/Attention_Mask/Attention_Mask_HLS_IP_release/mask_test_vectors/raw_scores.hex
    const std::vector<std::string> raw_candidates = {
        "mask_test_vectors/raw_scores.hex",
        "../mask_test_vectors/raw_scores.hex",
        "../../mask_test_vectors/raw_scores.hex"
    };
    const std::vector<std::string> golden_candidates = {
        "mask_test_vectors/golden_masked_scores.hex",
        "../mask_test_vectors/golden_masked_scores.hex",
        "../../mask_test_vectors/golden_masked_scores.hex"
    };

    if (read_hex_words(raw_candidates, raw, elements) != 0) {
        return EXIT_FAILURE;
    }
    if (read_hex_words(golden_candidates, golden, elements) != 0) {
        return EXIT_FAILURE;
    }

    attention_mask(
        raw.data(),
        out.data(),
        q_heads,
        seq_len,
        true,
        mask_value
    );

    int errors = 0;
    for (int idx = 0; idx < elements; ++idx) {
        if (out[idx] != golden[idx]) {
            if (errors < 16) {
                std::cerr << "Mismatch idx=" << idx
                          << " got=0x" << std::hex << std::uppercase
                          << std::setw(4) << std::setfill('0')
                          << out[idx].to_uint()
                          << " expected=0x" << std::setw(4)
                          << golden[idx].to_uint()
                          << std::dec << std::nouppercase << "\n";
            }
            ++errors;
        }
    }

    if (errors != 0) {
        std::cerr << "FAIL: HLS attention_mask mismatches golden. errors="
                  << errors << "\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS: HLS attention_mask matches scores_after_mask golden.\n";
    return EXIT_SUCCESS;
}
