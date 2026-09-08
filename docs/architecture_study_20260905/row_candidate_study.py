"""Architecture-only study; no RTL edits or board measurements.

Reuse the project's existing arithmetic model to compare full-row alternatives
on actual stored input/golden vectors. Python standard library only.
"""
import argparse
import hashlib
import json
import math
import sys
from dataclasses import asdict
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
ROOT = BASE / 'FPT_WORKSPACE/03_work_v314_causal_bypass'
sys.path.insert(0, str(ROOT / 'python'))
import flash_attention_tile_model as m


def row_unnormalized(scores, masks, values, lut):
    # One full key tile: global row maximum, BF16 unnormalized weights,
    # FP32 sequential accumulation, one final reciprocal normalization.
    return m.flash_rtl_exact(scores, masks, values, lut, len(scores))


def row_fp32_software_exp(scores, masks, values, lut):
    maximum = max(m.bf16_bits_to_f32(s) for s, mask in zip(scores,masks) if not mask)
    weights = [0.0 if mask else m.f32(math.exp(m.bf16_bits_to_f32(s)-maximum))
               for s, mask in zip(scores,masks)]
    denominator = 0.0
    for w in weights:
        denominator = m.fp32_add(denominator, w)
    result = []
    for feature in range(len(values[0])):
        acc = 0.0
        for w, v in zip(weights, values):
            acc = m.fp32_add(acc,m.fp32_mul(w,m.bf16_bits_to_f32(v[feature])))
        result.append(m.f32_to_bf16_bits(m.f32(acc / denominator)))
    return result


def run(full=False):
    data = ROOT / 'vitis/data'
    paths = {name: data / filename for name, filename in {
        'q': 'q_before_rope_bf16.hex', 'k': 'k_before_rope_bf16.hex',
        'v': 'v_bf16.hex', 'golden': 'attn_out_per_head_bf16.hex'}.items()}
    paths.update(sine=ROOT / 'mem/sin_bf16.hex', cosine=ROOT / 'mem/cos_bf16.hex',
                 lut=ROOT / 'mem/exp_lut_q15.mem', model=ROOT / 'python/flash_attention_tile_model.py')
    vectors = {name: m.read_hex_words(path) for name, path in paths.items()
               if name not in ('lut', 'model')}
    lut = m.load_lut(paths['lut'])
    heads = list(range(32))
    rows = list(range(128)) if full else [0, 1, 3, 7, 31, 63, 95, 127]
    methods = {'online_tile4': lambda s, mask, v, lut: m.flash_rtl_exact(s, mask, v, lut, 4),
               'row_normalized_bf16': m.baseline_v30,
               'row_unnormalized_bf16': row_unnormalized,
               'row_fp32_software_exp': row_fp32_software_exp}
    metrics = {name: m.Metrics() for name in methods}
    examples = {name: [] for name in methods}
    def tensor(name, head, row):
        offset = (head * 128 + row) * 128
        return vectors[name][offset:offset + 128]
    keys = {}
    max_updates = 0
    tile_updates = 0
    for head in heads:
        kv = head // 4
        for row in rows:
            qr = m.rope_vector(tensor('q', head, row), row, vectors['sine'], vectors['cosine'])
            scores, values = [], []
            for col in range(row + 1):
                if (kv, col) not in keys:
                    keys[kv, col] = m.rope_vector(tensor('k', kv, col), col, vectors['sine'], vectors['cosine'])
                scores.append(m.qk_score(qr, keys[kv, col]))
                values.append(tensor('v', kv, col))
            masks = [False] * len(scores)
            expected = tensor('golden', head, row)
            fixed = [m.bf16_to_fixed(s) for s in scores]
            maximum = None
            for start in range(0, len(fixed), 4):
                new = max(fixed[start:start+4])
                max_updates += int(maximum is not None and new > maximum)
                tile_updates += int(maximum is not None)
                maximum = new if maximum is None else max(maximum, new)
            for name, method in methods.items():
                actual = method(scores, masks, values, lut)
                metrics[name].update(actual, expected)
                for feature, (got, want) in enumerate(zip(actual, expected)):
                    distance = m.bf16_ulp_distance(got, want)
                    absolute = abs(m.bf16_bits_to_f32(got) - m.bf16_bits_to_f32(want))
                    if absolute > 1e-4 and distance > 1 and len(examples[name]) < 5:
                        examples[name].append(dict(head=head, row=row, feature=feature,
                            got=hex(got), expected=hex(want), absolute=absolute, ulp=distance))
        print(f'Completed head {head + 1}/32', flush=True)
    return dict(scope='Full stored dataset' if full else 'Stratified stored-vector sample',
                heads=heads, rows=rows, output_elements=len(heads)*len(rows)*128,
                contract='abs <= 1e-4 OR BF16 ordered distance <= 1; project contract, not verified official competition rule',
                limitations=['Software arithmetic model only, not RTL or board results',
                             'Uses stored project vectors; not independent hidden tests',
                             'Input RoPE and QK arithmetic preserved from project model',
                             'row_fp32_software_exp uses Python exp, NOT a validated hardware exp approximation'],
                metrics={k: asdict(v) for k,v in metrics.items()}, failure_examples=examples,
                max_changes_after_first_tile=max_updates, tiles_after_first=tile_updates,
                inputs={name:dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for name,path in paths.items()})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--full', action='store_true')
    args = parser.parse_args()
    result = run(args.full)
    out = Path(__file__).with_name('row_candidates_full.json' if args.full else 'row_candidates_sample.json')
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result['metrics'], indent=2))
    print(out)
