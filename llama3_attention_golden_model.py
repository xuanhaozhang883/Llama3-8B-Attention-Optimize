# -*- coding: utf-8 -*-
"""
Llama3-8B Attention Golden Model (bf16版)
所有模块之间传递的数据，在存成文件之前都强制转换成bf16精度，
模拟硬件里每个模块输入输出端口都是16位bf16的真实情况。

内部矩阵乘法本身仍用fp32做累加（这是合理的硬件设计做法——乘加器内部用更高精度累加，
最后再round回bf16输出，我们之前讨论过这一点），但每一个"模块边界"
（也就是你们几个人分工的模块之间的交接点）都强制round成bf16再往下传，
这样存下来的每一个中间结果.npy文件，数值上已经是bf16精度，
和你们RTL模块的输入输出直接对应，不会有精度不一致的问题。

使用方法和之前版本完全一样，只是内部多了bf16 round的步骤。
"""

import os
import json
import numpy as np
import torch
import torch.nn.functional as F

# ============ 配置区 ============

MODEL_REPO = "NousResearch/Meta-Llama-3-8B"
LOCAL_SAFETENSORS_DIR = "../llama3_weights"   # 按你实际路径改，绝对路径最保险

LAYER_IDX = 0
SEQ_LEN = 256
HIDDEN_SIZE = 4096
NUM_Q_HEADS = 32
NUM_KV_HEADS = 8
HEAD_DIM = 128
ROPE_THETA = 500000.0   # 原版Llama3-8B，不带Llama3.1的频率缩放

OUTPUT_DIR = "./golden_model_outputs"
os.makedirs(OUTPUT_DIR, exist_ok=True)

FPGA_KV_GROUP_IDX = 0
FPGA_SEQ_LEN = 128


# ============ bf16 round辅助函数 ============

def to_bf16(x: torch.Tensor) -> torch.Tensor:
    """把tensor强制round成bf16精度，再转回fp32方便后续numpy运算，
    但数值上已经是bf16能精确表示的那个值，等价于经过一次硬件的16位端口。"""
    return x.to(torch.bfloat16).to(torch.float32)


def save_bf16_npy(path, tensor: torch.Tensor):
    """存文件前统一走一次bf16 round，确保存下来的npy就是bf16精度的数值"""
    arr = to_bf16(tensor).detach().numpy()
    np.save(path, arr)
    return arr


# ============ 第一步：加载第0层权重 ============

def get_layer0_weight_paths():
    from huggingface_hub import hf_hub_download

    needed_names = [
        f"model.layers.{LAYER_IDX}.self_attn.q_proj.weight",
        f"model.layers.{LAYER_IDX}.self_attn.k_proj.weight",
        f"model.layers.{LAYER_IDX}.self_attn.v_proj.weight",
        f"model.layers.{LAYER_IDX}.self_attn.o_proj.weight",
    ]

    if LOCAL_SAFETENSORS_DIR is not None:
        local_dir = LOCAL_SAFETENSORS_DIR
        index_path = os.path.join(local_dir, "model.safetensors.index.json")
        if os.path.exists(index_path):
            with open(index_path, "r") as f:
                index = json.load(f)
            weight_map = index["weight_map"]
            return {name: os.path.join(local_dir, weight_map[name]) for name in needed_names}
        else:
            single_file = os.path.join(local_dir, "model.safetensors")
            return {name: single_file for name in needed_names}

    index_file = hf_hub_download(repo_id=MODEL_REPO, filename="model.safetensors.index.json")
    with open(index_file, "r") as f:
        index = json.load(f)
    weight_map = index["weight_map"]

    result = {}
    shard_cache = {}
    for name in needed_names:
        shard_name = weight_map[name]
        if shard_name not in shard_cache:
            shard_cache[shard_name] = hf_hub_download(repo_id=MODEL_REPO, filename=shard_name)
        result[name] = shard_cache[shard_name]
    return result


def load_layer0_weights():
    from safetensors import safe_open

    paths = get_layer0_weight_paths()
    weights = {}
    opened = {}
    for name, path in paths.items():
        if path not in opened:
            opened[path] = safe_open(path, framework="pt")
        weights[name] = opened[path].get_tensor(name)

    q_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.q_proj.weight"]
    k_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.k_proj.weight"]
    v_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.v_proj.weight"]
    o_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.o_proj.weight"]

    print(f"q_proj shape: {q_proj.shape}")
    print(f"k_proj shape: {k_proj.shape}")
    print(f"v_proj shape: {v_proj.shape}")
    print(f"o_proj shape: {o_proj.shape}")

    # 权重本身在checkpoint里已经是bf16存的，转fp32不会引入精度损失，
    # 但为了保险，这里也强制round一次，确保和硬件里存的权重完全一致
    return to_bf16(q_proj.float()), to_bf16(k_proj.float()), to_bf16(v_proj.float()), to_bf16(o_proj.float())


# ============ 第二步：RoPE ============

def build_rope_cache(seq_len, head_dim, theta):
    inv_freq = 1.0 / (theta ** (torch.arange(0, head_dim, 2).float() / head_dim))
    positions = torch.arange(seq_len).float()
    freqs = torch.outer(positions, inv_freq)
    emb = torch.cat([freqs, freqs], dim=-1)
    # sin/cos表本身也会存进硬件ROM，同样按bf16 round，保证和硬件ROM里的数值一致
    return to_bf16(emb.cos()), to_bf16(emb.sin())


def rotate_half(x):
    x1, x2 = x.chunk(2, dim=-1)
    return torch.cat([-x2, x1], dim=-1)


def apply_rope(x, cos, sin):
    return x * cos.unsqueeze(0) + rotate_half(x) * sin.unsqueeze(0)


# ============ 第三步：完整attention前向计算，每一步边界强制bf16 round ============

def run_full_attention(hidden_states, q_proj, k_proj, v_proj, o_proj):
    seq_len = hidden_states.shape[0]
    dump = {}

    # QKV投影：矩阵乘内部用fp32累加，输出边界round成bf16
    q = to_bf16(hidden_states @ q_proj.T)
    k = to_bf16(hidden_states @ k_proj.T)
    v = to_bf16(hidden_states @ v_proj.T)

    q = q.view(seq_len, NUM_Q_HEADS, HEAD_DIM).transpose(0, 1)
    k = k.view(seq_len, NUM_KV_HEADS, HEAD_DIM).transpose(0, 1)
    v = v.view(seq_len, NUM_KV_HEADS, HEAD_DIM).transpose(0, 1)

    dump["q_before_rope"] = q
    dump["k_before_rope"] = k
    dump["v"] = v

    # RoPE：输出round成bf16
    cos, sin = build_rope_cache(seq_len, HEAD_DIM, ROPE_THETA)
    q_rope = to_bf16(apply_rope(q, cos, sin))
    k_rope = to_bf16(apply_rope(k, cos, sin))

    dump["q_after_rope"] = q_rope
    dump["k_after_rope"] = k_rope

    # GQA复用
    repeat_factor = NUM_Q_HEADS // NUM_KV_HEADS
    k_expanded = k_rope.repeat_interleave(repeat_factor, dim=0)
    v_expanded = v.repeat_interleave(repeat_factor, dim=0)

    # QK^T：内部fp32累加，输出round成bf16
    scale = 1.0 / (HEAD_DIM ** 0.5)
    scores = to_bf16(torch.matmul(q_rope, k_expanded.transpose(-1, -2)) * scale)
    dump["scores_before_mask"] = scores

    # causal mask：加mask之后round（-inf在bf16下仍是-inf，不影响）
    causal_mask = torch.triu(torch.full((seq_len, seq_len), float("-inf")), diagonal=1)
    scores_masked = to_bf16(scores + causal_mask.unsqueeze(0))
    dump["scores_after_mask"] = scores_masked

    # softmax：输出round成bf16
    weights = to_bf16(F.softmax(scores_masked, dim=-1))
    dump["softmax_weights"] = weights

    # PV：内部fp32累加，输出round成bf16
    attn_out_per_head = to_bf16(torch.matmul(weights, v_expanded))
    dump["attn_out_per_head"] = attn_out_per_head

    # 输出投影
    attn_out = attn_out_per_head.transpose(0, 1).contiguous().view(seq_len, -1)
    final_out = to_bf16(attn_out @ o_proj.T)
    dump["final_output"] = final_out

    return dump


# ============ 第四步：主流程 ============

def main():
    print("加载第0层attention权重...")
    q_proj, k_proj, v_proj, o_proj = load_layer0_weights()

    print(f"构造测试输入，长度={SEQ_LEN}...")
    torch.manual_seed(42)
    # 输入本身也round成bf16，模拟这是从embedding模块传过来的bf16数据
    hidden_states = to_bf16(torch.randn(SEQ_LEN, HIDDEN_SIZE) * 0.02)

    print("跑完整32头/8组GQA attention前向计算（每步边界强制bf16 round）...")
    dump = run_full_attention(hidden_states, q_proj, k_proj, v_proj, o_proj)

    print(f"\n保存完整golden model结果到 {OUTPUT_DIR}/full/ （全部为bf16精度数值）...")
    full_dir = os.path.join(OUTPUT_DIR, "full")
    os.makedirs(full_dir, exist_ok=True)
    for key, tensor in dump.items():
        save_bf16_npy(os.path.join(full_dir, f"{key}.npy"), tensor)
    save_bf16_npy(os.path.join(full_dir, "hidden_states_input.npy"), hidden_states)
    save_bf16_npy(os.path.join(full_dir, "q_proj.npy"), q_proj)
    save_bf16_npy(os.path.join(full_dir, "k_proj.npy"), k_proj)
    save_bf16_npy(os.path.join(full_dir, "v_proj.npy"), v_proj)
    save_bf16_npy(os.path.join(full_dir, "o_proj.npy"), o_proj)

    print(f"截取FPGA验证子集：KV分组{FPGA_KV_GROUP_IDX}（对应4个Q head），前{FPGA_SEQ_LEN}个token...")
    repeat_factor = NUM_Q_HEADS // NUM_KV_HEADS
    q_head_start = FPGA_KV_GROUP_IDX * repeat_factor
    q_head_end = q_head_start + repeat_factor

    fpga_dir = os.path.join(OUTPUT_DIR, "fpga_slice")
    os.makedirs(fpga_dir, exist_ok=True)

    slice_map = {
        "q_before_rope": dump["q_before_rope"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :],
        "k_before_rope": dump["k_before_rope"][FPGA_KV_GROUP_IDX:FPGA_KV_GROUP_IDX+1, :FPGA_SEQ_LEN, :],
        "q_after_rope": dump["q_after_rope"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :],
        "k_after_rope": dump["k_after_rope"][FPGA_KV_GROUP_IDX:FPGA_KV_GROUP_IDX+1, :FPGA_SEQ_LEN, :],
        "v": dump["v"][FPGA_KV_GROUP_IDX:FPGA_KV_GROUP_IDX+1, :FPGA_SEQ_LEN, :],
        "scores_before_mask": dump["scores_before_mask"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :FPGA_SEQ_LEN],
        "scores_after_mask": dump["scores_after_mask"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :FPGA_SEQ_LEN],
        "softmax_weights": dump["softmax_weights"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :FPGA_SEQ_LEN],
        "attn_out_per_head": dump["attn_out_per_head"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :],
    }
    # 这些已经是bf16精度的tensor切片，直接存，不用再round一次
    for key, tensor in slice_map.items():
        np.save(os.path.join(fpga_dir, f"{key}.npy"), tensor.detach().numpy())

    print(f"\n完成。完整结果在 {full_dir}/，FPGA验证子集在 {fpga_dir}/")
    print("所有.npy文件里的数值现在都已经是bf16精度（fp32格式存储，但数值等价于16位bf16截断后的结果）。")
    print("下一步：用 convert_to_hex.py 把 fpga_slice 里的文件转成 .hex，供 Verilog testbench 使用。")


if __name__ == "__main__":
    main()