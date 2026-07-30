from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path


MODEL_REFERENCE = {
    "model_name": "Llama-3.1-8B",
    "num_attention_heads": 32,
    "num_key_value_heads": 8,
    "head_dim": 128,
    "gqa_group_size": 4,
    "datatype": "BF16",
    "note": "CPU_Baseline measures only the GQA attention kernel performance, not full Llama inference.",
}


PRESETS = {
    "small": dict(q_heads=4, kv_heads=1, seq_len=16, head_dim=128),
    "medium": dict(q_heads=8, kv_heads=2, seq_len=64, head_dim=128),
    "llama3_like_seq128": dict(q_heads=32, kv_heads=8, seq_len=128, head_dim=128),
    "llama3_like_seq256": dict(q_heads=32, kv_heads=8, seq_len=256, head_dim=128),
    "llama3_like_seq512": dict(q_heads=32, kv_heads=8, seq_len=512, head_dim=128),
}


@dataclass(frozen=True)
class BenchmarkConfig:
    q_heads: int = 32
    kv_heads: int = 8
    seq_len: int = 128
    head_dim: int = 128
    dtype: str = "fp32"
    causal: bool = True
    seed: int = 2026
    warmup: int = 5
    repeat: int = 30

    @property
    def group_size(self) -> int:
        return self.q_heads // self.kv_heads

    @property
    def dtype_bytes(self) -> int:
        return 2 if self.dtype == "bf16_emulated" else 4

    def validate(self) -> None:
        if self.q_heads <= 0 or self.kv_heads <= 0:
            raise ValueError("q_heads and kv_heads must be positive")
        if self.q_heads % self.kv_heads != 0:
            raise ValueError("q_heads must be divisible by kv_heads for GQA")
        if self.seq_len <= 0 or self.head_dim <= 0:
            raise ValueError("seq_len and head_dim must be positive")
        if self.dtype not in {"fp32", "bf16_emulated"}:
            raise ValueError("dtype must be fp32 or bf16_emulated")
        if self.warmup < 0:
            raise ValueError("warmup must be >= 0")
        if self.repeat <= 0:
            raise ValueError("repeat must be > 0")

    def to_dict(self) -> dict:
        data = asdict(self)
        data["group_size"] = self.group_size
        data["dtype_bytes"] = self.dtype_bytes
        data["model_reference"] = MODEL_REFERENCE
        data["matches_llama3_8b_attention_shape"] = (
            self.q_heads == MODEL_REFERENCE["num_attention_heads"]
            and self.kv_heads == MODEL_REFERENCE["num_key_value_heads"]
            and self.head_dim == MODEL_REFERENCE["head_dim"]
        )
        return data

    def save_json(self, path: Path) -> None:
        path.write_text(json.dumps(self.to_dict(), indent=2), encoding="utf-8")

    @classmethod
    def from_preset(
        cls,
        preset: str,
        *,
        dtype: str = "fp32",
        causal: bool = True,
        seed: int = 2026,
        warmup: int = 5,
        repeat: int = 30,
    ) -> "BenchmarkConfig":
        if preset not in PRESETS:
            valid = ", ".join(sorted(PRESETS))
            raise ValueError(f"unknown preset {preset!r}; valid presets: {valid}")
        return cls(**PRESETS[preset], dtype=dtype, causal=causal, seed=seed, warmup=warmup, repeat=repeat)
