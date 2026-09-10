#!/usr/bin/env python3
"""Generate candidate full-workload CATS-R4 A2 causal score golden data."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Iterable, Sequence

from flash_attention_tile_model import qk_score, read_hex_words, rope_vector


def tensor_row(words: Sequence[int], seq_len: int, head_dim: int,
               head: int, row: int) -> list[int]:
    base = (head * seq_len + row) * head_dim
    return list(words[base:base + head_dim])


def generate_score_words(*, q_words: Sequence[int], k_words: Sequence[int],
                         sine: Sequence[int], cosine: Sequence[int],
                         q_heads: int, kv_heads: int, seq_len: int,
                         head_dim: int) -> Iterable[int]:
    """Yield BF16 scores in global_q_head, row, causal-key order."""

    if q_heads <= 0 or kv_heads <= 0 or q_heads % kv_heads:
        raise ValueError("q_heads must be a positive multiple of kv_heads")
    expected_q = q_heads * seq_len * head_dim
    expected_k = kv_heads * seq_len * head_dim
    expected_trig = seq_len * (head_dim // 2)
    if len(q_words) != expected_q:
        raise ValueError(f"Q words: expected {expected_q}, got {len(q_words)}")
    if len(k_words) != expected_k:
        raise ValueError(f"K words: expected {expected_k}, got {len(k_words)}")
    if len(sine) != expected_trig or len(cosine) != expected_trig:
        raise ValueError("RoPE sine/cosine dimensions do not match")

    q_per_kv = q_heads // kv_heads
    k_cache: dict[tuple[int, int], list[int]] = {}
    for global_q_head in range(q_heads):
        kv_head = global_q_head // q_per_kv
        for row in range(seq_len):
            q_rotated = rope_vector(
                tensor_row(q_words, seq_len, head_dim, global_q_head, row),
                row, sine, cosine)
            for key in range(row + 1):
                cache_key = (kv_head, key)
                if cache_key not in k_cache:
                    k_cache[cache_key] = rope_vector(
                        tensor_row(k_words, seq_len, head_dim, kv_head, key),
                        key, sine, cosine)
                yield qk_score(q_rotated, k_cache[cache_key])


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def current_commit(root: Path) -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


def generate(root: Path, output_dir: Path) -> dict[str, object]:
    cfg = json.loads((root / "project_config.json").read_text(encoding="utf-8"))
    q_heads = int(cfg["q_heads"])
    kv_heads = int(cfg["kv_heads"])
    seq_len = int(cfg["seq_len"])
    head_dim = int(cfg["head_dim"])
    sources = {
        "q_before_rope": root / "vitis/data/q_before_rope_bf16.hex",
        "k_before_rope": root / "vitis/data/k_before_rope_bf16.hex",
        "sine": root / "mem/sin_bf16.hex",
        "cosine": root / "mem/cos_bf16.hex",
    }
    inputs = {name: read_hex_words(path) for name, path in sources.items()}
    expected_count = q_heads * seq_len * (seq_len + 1) // 2

    output_dir.mkdir(parents=True, exist_ok=True)
    score_path = output_dir / "scores_bf16.hex"
    with score_path.open("w", encoding="ascii", newline="\n") as stream:
        count = 0
        for score in generate_score_words(
                q_words=inputs["q_before_rope"],
                k_words=inputs["k_before_rope"],
                sine=inputs["sine"], cosine=inputs["cosine"],
                q_heads=q_heads, kv_heads=kv_heads,
                seq_len=seq_len, head_dim=head_dim):
            stream.write(f"{score:04X}\n")
            count += 1
    if count != expected_count:
        raise RuntimeError(f"score count: expected {expected_count}, got {count}")

    manifest = {
        "artifact": "CATS-R4 A2 candidate causal score golden",
        "status": "CANDIDATE_NOT_FROZEN",
        "input_model_commit": current_commit(root),
        "numeric_mode": 1,
        "dimensions": {
            "groups": int(cfg["run_groups"]),
            "q_heads": q_heads,
            "kv_heads": kv_heads,
            "seq_len": seq_len,
            "head_dim": head_dim,
            "causal_scores": count,
        },
        "ordering": ["global_q_head", "row", "key_0_through_row"],
        "arithmetic": "staged BF16 RoPE, FP32 RNE MAC, FP32 scale 0x3DB504F3, BF16 RNE",
        "sources": {
            name: {"path": path.relative_to(root).as_posix(),
                   "sha256": sha256(path)}
            for name, path in sources.items()
        },
        "output": {
            "path": score_path.name,
            "bytes": score_path.stat().st_size,
            "sha256": sha256(score_path),
        },
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n",
                             encoding="utf-8")
    return manifest


def main() -> int:
    default_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root)
    parser.add_argument("--output-dir", type=Path,
                        default=default_root / "artifacts" /
                        "cats_r4_a2_score_golden_2026-09-10")
    args = parser.parse_args()
    manifest = generate(args.root.resolve(), args.output_dir.resolve())
    print("[PASS] CATS-R4 A2 candidate score golden generated")
    print(f"causal_scores={manifest['dimensions']['causal_scores']}")
    print(f"sha256={manifest['output']['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
