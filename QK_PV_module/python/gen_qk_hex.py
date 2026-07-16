import numpy as np
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / 'sim_data'
SIM.mkdir(exist_ok=True)

q = np.load(SIM / 'q_after_rope.npy').astype(np.float32)
k = np.load(SIM / 'k_after_rope.npy').astype(np.float32)
s = np.load(SIM / 'scores_before_mask.npy').astype(np.float32)

assert q.shape == (4,128,128), q.shape
assert k.shape == (1,128,128), k.shape
assert s.shape == (4,128,128), s.shape

def fp32_to_bf16_rne(x: np.ndarray) -> np.ndarray:
    x = x.astype(np.float32, copy=False)
    u = x.view(np.uint32)
    lsb = (u >> 16) & 1
    round_bit = (u >> 15) & 1
    sticky = (u & 0x7fff) != 0
    round_up = round_bit & (sticky | lsb)
    return ((u >> 16) + round_up).astype(np.uint16)

def save_hex(path: Path, arr: np.ndarray):
    arr = arr.reshape(-1).astype(np.uint16)
    with open(path, 'w', encoding='ascii') as f:
        for v in arr:
            f.write(f'{int(v):04x}\n')

# 全量数据：q/k/gold 都是 BF16 hex
save_hex(SIM / 'q_after_rope.hex', fp32_to_bf16_rne(q))
save_hex(SIM / 'k_after_rope.hex', fp32_to_bf16_rne(k))
save_hex(SIM / 'scores_before_mask.hex', fp32_to_bf16_rne(s))

# 单点测试：h=0,row=0,col=0
save_hex(SIM / 'q_vec.hex', fp32_to_bf16_rne(q[0,0,:]))
save_hex(SIM / 'k_vec.hex', fp32_to_bf16_rne(k[0,0,:]))
save_hex(SIM / 'gold_one.hex', fp32_to_bf16_rne(s[0,0,0:1]))

print('Generated:')
for name in ['q_after_rope.hex','k_after_rope.hex','scores_before_mask.hex','q_vec.hex','k_vec.hex','gold_one.hex']:
    print(' ', SIM / name)
