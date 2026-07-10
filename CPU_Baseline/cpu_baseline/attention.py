from __future__ import annotations

import math

import numpy as np

from .bf16 import round_to_bf16
from .config import BenchmarkConfig


def generate_qkv(config: BenchmarkConfig) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Generate deterministic synthetic Q/K/V tensors for repeatable CPU timing."""
    rng = np.random.default_rng(config.seed)
    scale = 0.02
    q = (rng.standard_normal((config.q_heads, config.seq_len, config.head_dim)) * scale).astype(np.float32)
    k = (rng.standard_normal((config.kv_heads, config.seq_len, config.head_dim)) * scale).astype(np.float32)
    v = (rng.standard_normal((config.kv_heads, config.seq_len, config.head_dim)) * scale).astype(np.float32)
    return prepare_operands(q, k, v, config)


def prepare_operands(
    q: np.ndarray,
    k: np.ndarray,
    v: np.ndarray,
    config: BenchmarkConfig,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    q = np.ascontiguousarray(q, dtype=np.float32)
    k = np.ascontiguousarray(k, dtype=np.float32)
    v = np.ascontiguousarray(v, dtype=np.float32)

    if q.shape != (config.q_heads, config.seq_len, config.head_dim):
        raise ValueError(f"q shape mismatch: expected {(config.q_heads, config.seq_len, config.head_dim)}, got {q.shape}")
    if k.shape != (config.kv_heads, config.seq_len, config.head_dim):
        raise ValueError(f"k shape mismatch: expected {(config.kv_heads, config.seq_len, config.head_dim)}, got {k.shape}")
    if v.shape != (config.kv_heads, config.seq_len, config.head_dim):
        raise ValueError(f"v shape mismatch: expected {(config.kv_heads, config.seq_len, config.head_dim)}, got {v.shape}")

    if config.dtype == "bf16_emulated":
        q = round_to_bf16(q)
        k = round_to_bf16(k)
        v = round_to_bf16(v)

    return q, k, v


def stable_softmax(scores: np.ndarray) -> np.ndarray:
    max_score = np.max(scores, axis=-1, keepdims=True)
    exp_score = np.exp(scores - max_score)
    denom = np.sum(exp_score, axis=-1, keepdims=True)
    return exp_score / denom


def apply_causal_mask_inplace(scores: np.ndarray) -> np.ndarray:
    seq_len = scores.shape[-1]
    mask = np.triu(np.ones((seq_len, seq_len), dtype=bool), k=1)
    scores[mask] = -np.inf
    return scores


def gqa_attention_cpu(
    q: np.ndarray,
    k: np.ndarray,
    v: np.ndarray,
    config: BenchmarkConfig,
) -> np.ndarray:
    """CPU GQA attention kernel used only for performance measurement."""
    config.validate()
    scale = 1.0 / math.sqrt(config.head_dim)
    out = np.empty((config.q_heads, config.seq_len, config.head_dim), dtype=np.float32)

    for qh in range(config.q_heads):
        kvh = qh // config.group_size
        with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
            scores = (q[qh] @ k[kvh].T) * scale
        if config.causal:
            scores = apply_causal_mask_inplace(scores)
        probs = stable_softmax(scores).astype(np.float32, copy=False)
        with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
            head_out = probs @ v[kvh]
        if config.dtype == "bf16_emulated":
            head_out = round_to_bf16(head_out)
        out[qh] = head_out

    return out
