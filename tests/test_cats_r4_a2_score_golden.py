from __future__ import annotations

import sys
import unittest
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from generate_cats_r4_a2_score_golden import generate_score_words
from flash_attention_tile_model import qk_score


class A2ScoreGoldenTest(unittest.TestCase):
    def test_causal_head_row_key_order_uses_gqa_mapping(self) -> None:
        one = 0x3F80
        two = 0x4000
        zero = 0x0000
        q_words = [one] * 4 + [two] * 4
        k_words = [one] * 4
        sine = [zero] * 2
        cosine = [one] * 2

        actual = list(generate_score_words(
            q_words=q_words,
            k_words=k_words,
            sine=sine,
            cosine=cosine,
            q_heads=2,
            kv_heads=1,
            seq_len=2,
            head_dim=2,
        ))

        head0 = qk_score([one, one], [one, one])
        head1 = qk_score([two, two], [one, one])
        self.assertEqual(actual, [head0, head0, head0,
                                  head1, head1, head1])

    def test_full_candidate_matches_manifest(self) -> None:
        artifact = ROOT / "artifacts/cats_r4_a2_score_golden_2026-09-10"
        manifest = json.loads((artifact / "manifest.json").read_text(
            encoding="utf-8"))
        score_path = artifact / manifest["output"]["path"]
        digest = hashlib.sha256(score_path.read_bytes()).hexdigest().upper()

        self.assertEqual(manifest["status"], "CANDIDATE_NOT_FROZEN")
        self.assertEqual(manifest["numeric_mode"], 1)
        self.assertEqual(manifest["dimensions"]["causal_scores"], 264192)
        with score_path.open(encoding="ascii") as stream:
            self.assertEqual(sum(1 for _ in stream), 264192)
        self.assertEqual(digest, manifest["output"]["sha256"])


if __name__ == "__main__":
    unittest.main()
