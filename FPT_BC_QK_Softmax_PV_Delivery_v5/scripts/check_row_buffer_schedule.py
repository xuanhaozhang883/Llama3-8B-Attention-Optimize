#!/usr/bin/env python3
"""Audit the v3 registered-BRAM elastic drain schedule under backpressure."""

import random

SEQ_LEN = 128
TILE = 4
DEPTH = SEQ_LEN * TILE


def run_schedule(seed: int) -> None:
    memory = [
        (row, col, (row * SEQ_LEN + col) & 0xFFFF, int(col > row))
        for row in range(TILE)
        for col in range(SEQ_LEN)
    ]

    next_index = 0
    load_done = False
    out_valid = False
    out_payload = None
    out_metadata = None
    held = None
    received = []
    rng = random.Random(seed)

    for _cycle in range(20_000):
        out_ready = rng.randrange(5) != 0

        if held is not None:
            assert out_valid and (out_payload, out_metadata) == held
        held = ((out_payload, out_metadata)
                if out_valid and not out_ready else None)

        accepted = out_valid and out_ready
        if accepted:
            received.append((out_metadata, out_payload))

        read_enable = (not load_done) and ((not out_valid) or out_ready)
        finished = accepted and out_metadata == DEPTH - 1 and load_done

        next_valid = out_valid
        if accepted:
            next_valid = False

        if read_enable:
            out_payload = memory[next_index]
            out_metadata = next_index
            next_valid = True
            if next_index == DEPTH - 1:
                load_done = True
            else:
                next_index += 1

        out_valid = next_valid
        if finished:
            break
    else:
        raise AssertionError(f"seed {seed}: drain timeout")

    assert len(received) == DEPTH
    for index, (metadata, payload) in enumerate(received):
        assert metadata == index
        assert payload == memory[index]


def main() -> None:
    for seed in range(1_000):
        run_schedule(seed)
    print("PASS: Row Buffer registered-read elastic schedule, "
          "1000 randomized backpressure cases")


if __name__ == "__main__":
    main()
