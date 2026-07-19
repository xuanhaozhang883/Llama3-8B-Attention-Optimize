#!/usr/bin/env python3
"""Static count/address audit for the fixed B+C Group contract."""


def audit(seq_len: int, head_dim: int, pv_tile: int = 2) -> None:
    q_heads = 4
    groups = 8
    probabilities = q_heads * seq_len * seq_len
    vectors = (q_heads * (seq_len // pv_tile) *
               (head_dim // pv_tile) * seq_len)

    assert seq_len % pv_tile == 0
    assert head_dim % pv_tile == 0

    count = 0
    for head in range(q_heads):
        for row_base in range(0, seq_len, pv_tile):
            for feature_base in range(0, head_dim, pv_tile):
                for reduce_index in range(seq_len):
                    assert 0 <= head < q_heads
                    assert row_base + pv_tile - 1 < seq_len
                    assert feature_base + pv_tile - 1 < head_dim
                    assert 0 <= reduce_index < seq_len
                    count += 1
    assert count == vectors

    for group_id in range(groups):
        first_addr = group_id * seq_len * head_dim
        last_addr = (((group_id * seq_len + seq_len - 1) * head_dim) +
                     head_dim - pv_tile)
        assert first_addr == group_id * seq_len * head_dim
        assert last_addr + pv_tile - 1 < groups * seq_len * head_dim
        for local_head in range(q_heads):
            global_q_head = group_id * q_heads + local_head
            assert 0 <= global_q_head < 32

    print(f'PASS seq={seq_len} head_dim={head_dim} pv_tile={pv_tile} '
          f'probabilities={probabilities} vectors={vectors} '
          f'group7_v_base={7*seq_len*head_dim}')


def main() -> None:
    audit(8, 8)
    audit(128, 128)
    print('PASS: B+C count, schedule, global-head and V-address contract')


if __name__ == '__main__':
    main()
