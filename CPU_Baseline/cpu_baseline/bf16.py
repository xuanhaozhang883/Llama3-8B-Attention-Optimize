from __future__ import annotations

import numpy as np


def round_to_bf16(x: np.ndarray) -> np.ndarray:
    """Round float32 values to BF16 precision and return them as float32."""
    arr = np.ascontiguousarray(x, dtype=np.float32)
    bits = arr.view(np.uint32)
    lsb = (bits >> 16) & 1
    rounding_bias = np.uint32(0x7FFF) + lsb.astype(np.uint32)
    rounded = bits + rounding_bias
    bf16_bits = rounded & np.uint32(0xFFFF0000)
    return bf16_bits.view(np.float32)
