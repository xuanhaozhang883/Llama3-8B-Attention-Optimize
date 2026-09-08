"""Synthetic operator diagnostic; no claim of full-system/official validation."""
import json
import math
import random
from dataclasses import asdict
from pathlib import Path
from row_candidate_study import m, ROOT, row_unnormalized

lut = m.load_lut(ROOT / 'mem/exp_lut_q15.mem')
rng = random.Random(20260905)
metrics = {name: m.Metrics() for name in ('online_q15', 'row_q15', 'row_fp32_exp_software')}
for case in range(32):
    scores, masks, values = m.make_case(rng, 128, 128, None if case % 2 else (case * 7) % 128)
    reference = m.mathematical_reference(scores, masks, values)
    metrics['online_q15'].update(m.flash_rtl_exact(scores, masks, values, lut, 4), reference)
    metrics['row_q15'].update(row_unnormalized(scores, masks, values, lut), reference)
    # Diagnostic arithmetic ceiling: Python exp rounded to FP32, not a proposed
    # LUT/poly hardware implementation and not measured hardware throughput.
    max_score = max(m.bf16_bits_to_f32(s) for s,mask in zip(scores,masks) if not mask)
    weights = [0.0 if mask else m.f32(math.exp(m.bf16_bits_to_f32(s)-max_score)) for s,mask in zip(scores,masks)]
    denominator = 0.0
    for w in weights:
        denominator = m.fp32_add(denominator,w)
    result=[]
    for feature in range(128):
        acc=0.0
        for w,v in zip(weights,values):
            acc=m.fp32_add(acc,m.fp32_mul(w,m.bf16_bits_to_f32(v[feature])))
        result.append(m.f32_to_bf16_bits(m.f32(acc/denominator)))
    metrics['row_fp32_exp_software'].update(result, reference)
out = dict(seed=20260905,cases=32,elements=4096,scope='Softmax/PV synthetic only; same BF16 score inputs for all methods',
           reference='FP64 mathematical softmax and math.fsum accumulation, final BF16 rounding',
           limitations='FP32 exp uses Python math.exp; hardware exp approximation, RoPE and QK excluded; NOT an official test suite',
           metrics={k:asdict(v) for k,v in metrics.items()})
path=Path(__file__).with_name('row_candidates_stress.json')
path.write_text(json.dumps(out,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(out,indent=2))
