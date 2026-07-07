# -*- coding: utf-8 -*-
"""
Llama3-8B Attention Golden Model
用于生成FPGA RTL验证用的标准答案（golden reference）

功能：
1. 只下载/加载第0层 attention 的权重（q_proj, k_proj, v_proj, o_proj），不加载完整16GB模型
2. 构造一段测试输入（默认用随机hidden state，若想更真实可以换成真实tokenizer输出）
3. 完整跑一遍 RoPE -> QK^T -> causal mask -> softmax -> PV 全流程（32个Q head / 8个KV head，完整GQA）
4. 把每一步的中间结果dump成.npy文件，供Verilog testbench比对
5. 额外单独截取"FPGA验证子集"（第1个KV分组，即4个Q head + 1个KV head，前 SEQ_LEN 个token）

使用前准备：
    pip install torch safetensors huggingface_hub numpy

权重来源二选一（任选其一，把 MODEL_REPO 改成对应值）：
    - ModelScope（推荐，国内访问快，通常无需审核）: 需要用 modelscope 库下载，见下方注释
    - HuggingFace 未加锁镜像: "NousResearch/Meta-Llama-3-8B"
    - HuggingFace 官方（需要申请通过）: "meta-llama/Meta-Llama-3-8B"

本脚本默认写法是从 HuggingFace 下载指定权重文件（只下第0层需要的那个分片，不下全部）。
如果你用 ModelScope 下载，把权重下到本地文件夹后，直接把 LOCAL_SAFETENSORS_DIR
指向那个文件夹，脚本会跳过下载直接读本地文件。
"""

import os
import json
import numpy as np
import torch
import torch.nn.functional as F

# ============ 配置区，按需修改 ============

MODEL_REPO = "NousResearch/Meta-Llama-3-8B"   # 未加锁镜像，不需要审核；如已从ModelScope下到本地，可忽略此项
LOCAL_SAFETENSORS_DIR = "../llama3_weights"           # 如果已经手动下载好权重到本地文件夹，把路径填在这里，比如 "./llama3_weights"

LAYER_IDX = 0            # 只取第0层
SEQ_LEN = 256             # 测试序列长度（token数）
HIDDEN_SIZE = 4096
NUM_Q_HEADS = 32
NUM_KV_HEADS = 8
HEAD_DIM = 128
ROPE_THETA = 500000.0

OUTPUT_DIR = "./golden_model_outputs"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# FPGA验证子集配置：第几个KV分组（0-indexed），每组对应4个Q head
FPGA_KV_GROUP_IDX = 0
FPGA_SEQ_LEN = 128        # 硬件先验证的序列长度，可以比golden model的SEQ_LEN小，脚本会自动截取前FPGA_SEQ_LEN个token


# ============ 第一步：定位并下载/加载第0层的权重 ============

def get_layer0_weight_paths():
    """
    找到第0层 q_proj/k_proj/v_proj/o_proj 权重所在的分片文件，
    只下载这一个分片，而不是整个16GB模型。
    """
    from huggingface_hub import hf_hub_download

    if LOCAL_SAFETENSORS_DIR is not None:
        # 已经手动下载好的情况：假设本地目录下有 model.safetensors（单文件）或多个分片+index.json
        local_dir = LOCAL_SAFETENSORS_DIR
        index_path = os.path.join(local_dir, "model.safetensors.index.json")
        if os.path.exists(index_path):
            with open(index_path, "r") as f:
                index = json.load(f)
            weight_map = index["weight_map"]
        else:
            # 单文件情况，直接返回
            single_file = os.path.join(local_dir, "model.safetensors")
            return {name: single_file for name in [
                f"model.layers.{LAYER_IDX}.self_attn.q_proj.weight",
                f"model.layers.{LAYER_IDX}.self_attn.k_proj.weight",
                f"model.layers.{LAYER_IDX}.self_attn.v_proj.weight",
                f"model.layers.{LAYER_IDX}.self_attn.o_proj.weight",
            ]}
        needed_names = [
            f"model.layers.{LAYER_IDX}.self_attn.q_proj.weight",
            f"model.layers.{LAYER_IDX}.self_attn.k_proj.weight",
            f"model.layers.{LAYER_IDX}.self_attn.v_proj.weight",
            f"model.layers.{LAYER_IDX}.self_attn.o_proj.weight",
        ]
        return {name: os.path.join(local_dir, weight_map[name]) for name in needed_names}

    # 从HuggingFace下载：先下索引文件（很小），找到第0层权重在哪个分片
    index_file = hf_hub_download(repo_id=MODEL_REPO, filename="model.safetensors.index.json")
    with open(index_file, "r") as f:
        index = json.load(f)
    weight_map = index["weight_map"]

    needed_names = [
        f"model.layers.{LAYER_IDX}.self_attn.q_proj.weight",
        f"model.layers.{LAYER_IDX}.self_attn.k_proj.weight",
        f"model.layers.{LAYER_IDX}.self_attn.v_proj.weight",
        f"model.layers.{LAYER_IDX}.self_attn.o_proj.weight",
    ]

    result = {}
    shard_cache = {}
    for name in needed_names:
        shard_name = weight_map[name]
        if shard_name not in shard_cache:
            # 只下载包含所需权重的那个分片文件，不是全部分片
            shard_cache[shard_name] = hf_hub_download(repo_id=MODEL_REPO, filename=shard_name)
        result[name] = shard_cache[shard_name]
    return result


def load_layer0_weights():
    from safetensors import safe_open

    paths = get_layer0_weight_paths()
    weights = {}
    # 用safe_open按需读取指定tensor，不需要把整个分片文件全部加载进内存
    opened = {}
    for name, path in paths.items():
        if path not in opened:
            opened[path] = safe_open(path, framework="pt")
        weights[name] = opened[path].get_tensor(name)

    q_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.q_proj.weight"]  # [4096, 4096]
    k_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.k_proj.weight"]  # [1024, 4096]  (8*128)
    v_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.v_proj.weight"]  # [1024, 4096]
    o_proj = weights[f"model.layers.{LAYER_IDX}.self_attn.o_proj.weight"]  # [4096, 4096]

    print(f"q_proj shape: {q_proj.shape}")
    print(f"k_proj shape: {k_proj.shape}")
    print(f"v_proj shape: {v_proj.shape}")
    print(f"o_proj shape: {o_proj.shape}")

    return q_proj.float(), k_proj.float(), v_proj.float(), o_proj.float()


# ============ 第二步：RoPE ============

def build_rope_cache(seq_len, head_dim, theta):
    """预计算sin/cos表，硬件上对应的就是这张表存进ROM"""
    inv_freq = 1.0 / (theta ** (torch.arange(0, head_dim, 2).float() / head_dim))
    positions = torch.arange(seq_len).float()
    freqs = torch.outer(positions, inv_freq)          # [seq_len, head_dim/2]
    emb = torch.cat([freqs, freqs], dim=-1)           # [seq_len, head_dim]
    return emb.cos(), emb.sin()                       # 各自 [seq_len, head_dim]


def rotate_half(x):
    x1, x2 = x.chunk(2, dim=-1)
    return torch.cat([-x2, x1], dim=-1)


def apply_rope(x, cos, sin):
    """x: [num_heads, seq_len, head_dim]"""
    return x * cos.unsqueeze(0) + rotate_half(x) * sin.unsqueeze(0)


# ============ 第三步：完整attention前向计算（32头/8组GQA，一次性算全部） ============

def run_full_attention(hidden_states, q_proj, k_proj, v_proj, o_proj):
    """
    hidden_states: [seq_len, hidden_size]
    返回一个dict，包含每一步的中间结果，全部转成numpy，方便dump
    """
    seq_len = hidden_states.shape[0]
    dump = {}

    # QKV投影
    q = hidden_states @ q_proj.T   # [seq_len, 4096]
    k = hidden_states @ k_proj.T   # [seq_len, 1024]
    v = hidden_states @ v_proj.T   # [seq_len, 1024]

    q = q.view(seq_len, NUM_Q_HEADS, HEAD_DIM).transpose(0, 1)    # [32, seq_len, 128]
    k = k.view(seq_len, NUM_KV_HEADS, HEAD_DIM).transpose(0, 1)   # [8, seq_len, 128]
    v = v.view(seq_len, NUM_KV_HEADS, HEAD_DIM).transpose(0, 1)   # [8, seq_len, 128]

    dump["q_before_rope"] = q.detach().numpy()
    dump["k_before_rope"] = k.detach().numpy()
    dump["v"] = v.detach().numpy()

    # RoPE
    cos, sin = build_rope_cache(seq_len, HEAD_DIM, ROPE_THETA)
    q_rope = apply_rope(q, cos, sin)   # [32, seq_len, 128]
    k_rope = apply_rope(k, cos, sin)   # [8, seq_len, 128]

    dump["q_after_rope"] = q_rope.detach().numpy()
    dump["k_after_rope"] = k_rope.detach().numpy()

    # GQA: 把8个KV head按4:1的比例repeat成32个，跟Q head对齐
    repeat_factor = NUM_Q_HEADS // NUM_KV_HEADS   # 4
    k_expanded = k_rope.repeat_interleave(repeat_factor, dim=0)   # [32, seq_len, 128]
    v_expanded = v.repeat_interleave(repeat_factor, dim=0)        # [32, seq_len, 128]

    # QK^T
    scale = 1.0 / (HEAD_DIM ** 0.5)
    scores = torch.matmul(q_rope, k_expanded.transpose(-1, -2)) * scale   # [32, seq_len, seq_len]
    dump["scores_before_mask"] = scores.detach().numpy()

    # causal mask
    causal_mask = torch.triu(torch.full((seq_len, seq_len), float("-inf")), diagonal=1)
    scores_masked = scores + causal_mask.unsqueeze(0)
    dump["scores_after_mask"] = scores_masked.detach().numpy()

    # softmax
    weights = F.softmax(scores_masked, dim=-1)   # [32, seq_len, seq_len]
    dump["softmax_weights"] = weights.detach().numpy()

    # PV
    attn_out_per_head = torch.matmul(weights, v_expanded)   # [32, seq_len, 128]
    dump["attn_out_per_head"] = attn_out_per_head.detach().numpy()

    # 拼接32个head，乘输出权重矩阵
    attn_out = attn_out_per_head.transpose(0, 1).contiguous().view(seq_len, -1)   # [seq_len, 4096]
    final_out = attn_out @ o_proj.T   # [seq_len, 4096]
    dump["final_output"] = final_out.detach().numpy()

    return dump


# ============ 第四步：主流程 ============

def main():
    print("加载第0层attention权重...")
    q_proj, k_proj, v_proj, o_proj = load_layer0_weights()

    print(f"构造测试输入，长度={SEQ_LEN}...")
    # 用随机正态分布模拟embedding之后的hidden state（数值范围和真实embedding接近即可）
    # 如果想更真实，可以额外加载 model.embed_tokens.weight，用真实token id去查embedding
    torch.manual_seed(42)
    hidden_states = torch.randn(SEQ_LEN, HIDDEN_SIZE) * 0.02

    print("跑完整32头/8组GQA attention前向计算...")
    dump = run_full_attention(hidden_states, q_proj, k_proj, v_proj, o_proj)

    # bf16量化误差参考：把关键中间结果转bf16再转回fp32，看误差多大
    print("\n=== bf16量化误差参考 ===")
    for key in ["scores_before_mask", "softmax_weights", "final_output"]:
        fp32_val = torch.from_numpy(dump[key])
        bf16_val = fp32_val.to(torch.bfloat16).to(torch.float32)
        max_err = (fp32_val - bf16_val).abs().max().item()
        mean_err = (fp32_val - bf16_val).abs().mean().item()
        print(f"{key}: max_abs_err={max_err:.6f}, mean_abs_err={mean_err:.6f}")

    # 保存完整结果（32头/8组，全部SEQ_LEN）
    print(f"\n保存完整golden model结果到 {OUTPUT_DIR}/full/ ...")
    full_dir = os.path.join(OUTPUT_DIR, "full")
    os.makedirs(full_dir, exist_ok=True)
    for key, val in dump.items():
        np.save(os.path.join(full_dir, f"{key}.npy"), val)
    np.save(os.path.join(full_dir, "hidden_states_input.npy"), hidden_states.numpy())

    # 保存输入权重本身（RTL那边如果要做量化/复现，需要这几个矩阵）
    np.save(os.path.join(full_dir, "q_proj.npy"), q_proj.numpy())
    np.save(os.path.join(full_dir, "k_proj.npy"), k_proj.numpy())
    np.save(os.path.join(full_dir, "v_proj.npy"), v_proj.numpy())
    np.save(os.path.join(full_dir, "o_proj.npy"), o_proj.numpy())

    # ============ 截取FPGA验证子集 ============
    print(f"\n截取FPGA验证子集：KV分组{FPGA_KV_GROUP_IDX}（对应4个Q head），前{FPGA_SEQ_LEN}个token...")
    repeat_factor = NUM_Q_HEADS // NUM_KV_HEADS  # 4
    q_head_start = FPGA_KV_GROUP_IDX * repeat_factor
    q_head_end = q_head_start + repeat_factor

    fpga_dir = os.path.join(OUTPUT_DIR, "fpga_slice")
    os.makedirs(fpga_dir, exist_ok=True)

    slice_map = {
        "q_after_rope": dump["q_after_rope"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :],
        "k_after_rope": dump["k_after_rope"][FPGA_KV_GROUP_IDX:FPGA_KV_GROUP_IDX+1, :FPGA_SEQ_LEN, :],
        "v": dump["v"][FPGA_KV_GROUP_IDX:FPGA_KV_GROUP_IDX+1, :FPGA_SEQ_LEN, :],
        "scores_after_mask": dump["scores_after_mask"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :FPGA_SEQ_LEN],
        "softmax_weights": dump["softmax_weights"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :FPGA_SEQ_LEN],
        "attn_out_per_head": dump["attn_out_per_head"][q_head_start:q_head_end, :FPGA_SEQ_LEN, :],
    }
    for key, val in slice_map.items():
        np.save(os.path.join(fpga_dir, f"{key}.npy"), val)

    print(f"完成。完整结果在 {full_dir}/，FPGA验证子集在 {fpga_dir}/")
    print("这些.npy文件后续用Python的np.load()读取，转成Verilog testbench能读的格式（比如.hex或.mem文件）即可。")


if __name__ == "__main__":
    main()
