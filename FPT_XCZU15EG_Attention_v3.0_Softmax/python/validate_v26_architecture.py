#!/usr/bin/env python3
"""Host-side contract and schedule checks for the integrated v2.6 RTL.

This is intentionally independent of Vivado.  It proves the coordinate/order
contracts and expected operation counts, and performs a lightweight structural
audit of every Verilog source.  It does not replace Vivado elaboration,
implementation, timing closure, or board validation.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASELINE_SHA256 = (
    "711bdadf66cc54e7176ee59c58fe3c889064cc38ba3b64d5a4e893e97fc1832f"
)


@dataclass(frozen=True)
class Shape:
    q_heads: int = 4
    groups: int = 8
    seq_len: int = 128
    head_dim: int = 128
    tile: int = 4
    qk_lanes: int = 2
    pv_lanes: int = 2


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def qk_tile_stream(shape: Shape, lanes: int) -> list[tuple[int, int, int, int, int]]:
    """Return the externally visible score coordinate order."""
    stream: list[tuple[int, int, int, int, int]] = []
    pair_span = lanes * shape.tile
    for head in range(shape.q_heads):
        for row_base in range(0, shape.seq_len, shape.tile):
            for pair_col in range(0, shape.seq_len, pair_span):
                for lane in range(lanes):
                    col_base = pair_col + lane * shape.tile
                    for local_row in range(shape.tile):
                        for local_col in range(shape.tile):
                            stream.append(
                                (head, row_base, col_base, local_row, local_col)
                            )
    return stream


def validate_qk(shape: Shape) -> tuple[int, int]:
    legacy = qk_tile_stream(shape, 1)
    parallel = qk_tile_stream(shape, shape.qk_lanes)
    require(parallel == legacy, "dual-QK output order differs from legacy order")

    computed = 0
    skipped = 0
    for head in range(shape.q_heads):
        del head
        for row_base in range(0, shape.seq_len, shape.tile):
            for col_base in range(0, shape.seq_len, shape.tile):
                if col_base > row_base:
                    skipped += 1
                    for local_row in range(shape.tile):
                        for local_col in range(shape.tile):
                            row = row_base + local_row
                            col = col_base + local_col
                            require(col > row, "whole-tile skip crossed causal diagonal")
                else:
                    computed += 1

    tile_count = (
        shape.q_heads
        * (shape.seq_len // shape.tile)
        * (shape.seq_len // shape.tile)
    )
    require(computed + skipped == tile_count, "QK tile accounting mismatch")
    require(computed == 2112, f"unexpected computed QK tiles: {computed}")
    require(skipped == 1984, f"unexpected skipped QK tiles: {skipped}")
    return computed, skipped


def pv_output_stream(shape: Shape, lanes: int) -> list[tuple[int, int, int, int, int]]:
    """Return the externally visible Context coordinate order."""
    stream: list[tuple[int, int, int, int, int]] = []
    pair_span = lanes * shape.tile
    for head in range(shape.q_heads):
        for row_base in range(0, shape.seq_len, shape.tile):
            for pair_col in range(0, shape.head_dim, pair_span):
                for lane in range(lanes):
                    col_base = pair_col + lane * shape.tile
                    for local_row in range(shape.tile):
                        for local_col in range(shape.tile):
                            stream.append(
                                (head, row_base, col_base, local_row, local_col)
                            )
    return stream


def validate_pv(shape: Shape) -> tuple[int, int, int, int]:
    legacy = pv_output_stream(shape, 1)
    parallel = pv_output_stream(shape, shape.pv_lanes)
    require(parallel == legacy, "dual-PV Context order differs from legacy order")

    computed_per_head = 0
    accepted_beats_per_head = 0
    for row_base in range(0, shape.seq_len, shape.tile):
        accepted = list(range(row_base + shape.tile))
        require(
            accepted[-1] == row_base + shape.tile - 1,
            "PV shared reduction did not end on maximum row",
        )
        accepted_beats_per_head += (
            len(accepted) * (shape.head_dim // (shape.tile * shape.pv_lanes))
        )
        for local_row in range(shape.tile):
            row = row_base + local_row
            enabled = [k for k in accepted if k <= row]
            disabled = [k for k in accepted if k > row]
            require(enabled == list(range(row + 1)), "PV row enable is not k<=row")
            require(
                all(k > row for k in disabled),
                "PV disabled term is not causally masked",
            )
            computed_per_head += len(enabled) * shape.head_dim

    computed = computed_per_head * shape.q_heads
    total = (
        shape.q_heads
        * shape.seq_len
        * shape.head_dim
        * shape.seq_len
    )
    skipped = total - computed
    accepted_beats = accepted_beats_per_head * shape.q_heads

    require(computed == 4_227_072, f"unexpected PV computed terms: {computed}")
    require(skipped == 4_161_536, f"unexpected PV skipped terms: {skipped}")
    require(accepted_beats == 135_168, f"unexpected PV input beats: {accepted_beats}")
    require(computed + skipped == total, "PV term accounting mismatch")
    return computed, skipped, accepted_beats, total


def validate_native_tile4(shape: Shape) -> tuple[int, int]:
    p_addresses: set[int] = set()
    v_addresses: list[set[int]] = [set() for _ in range(shape.pv_lanes)]

    row_tiles = shape.seq_len // shape.tile
    col_tiles = shape.head_dim // shape.tile
    col_tiles_per_lane = col_tiles // shape.pv_lanes

    for head in range(shape.q_heads):
        for row_base in range(0, shape.seq_len, shape.tile):
            for reduce in range(shape.seq_len):
                p_addr = (
                    (head * row_tiles + row_base // shape.tile) * shape.seq_len
                    + reduce
                )
                require(p_addr not in p_addresses, "native P address collision")
                p_addresses.add(p_addr)

    for reduce in range(shape.seq_len):
        for feature_base in range(0, shape.head_dim, shape.tile):
            tile_index = feature_base // shape.tile
            lane = tile_index % shape.pv_lanes
            addr = reduce * col_tiles_per_lane + tile_index // shape.pv_lanes
            require(addr not in v_addresses[lane], "native V bank address collision")
            v_addresses[lane].add(addr)

    require(
        len(p_addresses) == shape.q_heads * row_tiles * shape.seq_len,
        "native P depth mismatch",
    )
    require(
        all(len(bank) == shape.seq_len * col_tiles_per_lane for bank in v_addresses),
        "native V bank depth mismatch",
    )

    vectors_per_group = shape.q_heads * row_tiles * col_tiles * shape.seq_len
    vectors_per_run = vectors_per_group * shape.groups
    require(vectors_per_group == 524_288, "native capture vectors/group mismatch")
    require(vectors_per_run == 4_194_304, "native capture vectors/run mismatch")
    return vectors_per_group, vectors_per_run


def strip_sv_comments_and_strings(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    return text


def matching_paren(text: str, opening: int) -> int:
    require(text[opening] == "(", "internal parser did not start on '('")
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    raise AssertionError("unclosed parenthesis in internal RTL parser")


def split_top_level_commas(text: str) -> list[str]:
    items: list[str] = []
    start = 0
    paren = bracket = brace = 0
    for index, char in enumerate(text):
        if char == "(":
            paren += 1
        elif char == ")":
            paren -= 1
        elif char == "[":
            bracket += 1
        elif char == "]":
            bracket -= 1
        elif char == "{":
            brace += 1
        elif char == "}":
            brace -= 1
        elif char == "," and paren == bracket == brace == 0:
            items.append(text[start:index])
            start = index + 1
    items.append(text[start:])
    return items


def module_ports(text: str) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for match in re.finditer(
        r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)", text
    ):
        name = match.group(1)
        cursor = match.end()
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        if cursor < len(text) and text[cursor] == "#":
            cursor += 1
            while cursor < len(text) and text[cursor].isspace():
                cursor += 1
            require(text[cursor] == "(", f"{name}: malformed parameter header")
            cursor = matching_paren(text, cursor) + 1
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        require(text[cursor] == "(", f"{name}: missing ANSI port header")
        end = matching_paren(text, cursor)
        ports: set[str] = set()
        direction_seen = False
        for item in split_top_level_commas(text[cursor + 1 : end]):
            if re.search(r"\b(input|output|inout)\b", item):
                direction_seen = True
            if not direction_seen:
                continue
            identifiers = re.findall(r"[A-Za-z_][A-Za-z0-9_$]*", item)
            if identifiers:
                ports.add(identifiers[-1])
        result[name] = ports
    return result


def named_port_audit(all_text: str, definitions: dict[str, set[str]]) -> int:
    """Check named connections for every locally defined module instance."""
    instance_count = 0
    for module_name, ports in definitions.items():
        pattern = re.compile(rf"\b{re.escape(module_name)}\b")
        for match in pattern.finditer(all_text):
            prefix = all_text[max(0, match.start() - 12) : match.start()]
            if re.search(r"\bmodule\s+$", prefix):
                continue
            cursor = match.end()
            while cursor < len(all_text) and all_text[cursor].isspace():
                cursor += 1
            if cursor < len(all_text) and all_text[cursor] == "#":
                cursor += 1
                while cursor < len(all_text) and all_text[cursor].isspace():
                    cursor += 1
                if cursor >= len(all_text) or all_text[cursor] != "(":
                    continue
                cursor = matching_paren(all_text, cursor) + 1
            while cursor < len(all_text) and all_text[cursor].isspace():
                cursor += 1
            instance = re.match(r"[A-Za-z_][A-Za-z0-9_$]*", all_text[cursor:])
            if not instance:
                continue
            cursor += instance.end()
            while cursor < len(all_text) and all_text[cursor].isspace():
                cursor += 1
            if cursor >= len(all_text) or all_text[cursor] != "(":
                continue
            end = matching_paren(all_text, cursor)
            connection_text = all_text[cursor + 1 : end]
            named = set(re.findall(r"\.([A-Za-z_][A-Za-z0-9_$]*)", connection_text))
            if not named:
                continue
            unknown = sorted(named - ports)
            require(
                not unknown,
                f"{module_name} {instance.group(0)}: unknown named ports {unknown}",
            )
            instance_count += 1
    return instance_count


def structural_rtl_audit() -> tuple[int, int, int]:
    rtl_files = sorted((ROOT / "rtl").rglob("*.sv"))
    rtl_files += sorted((ROOT / "rtl").rglob("*.v"))
    require(rtl_files, "no RTL files found")

    module_names: list[str] = []
    clean_sources: list[str] = []
    delimiter_pairs = {"(": ")", "[": "]", "{": "}"}
    keyword_pairs = (
        ("module", "endmodule"),
        ("begin", "end"),
        ("case", "endcase"),
        ("generate", "endgenerate"),
        ("function", "endfunction"),
        ("task", "endtask"),
    )

    for path in rtl_files:
        text = strip_sv_comments_and_strings(path.read_text(encoding="utf-8"))
        clean_sources.append(text)
        stack: list[str] = []
        for char in text:
            if char in delimiter_pairs:
                stack.append(delimiter_pairs[char])
            elif char in delimiter_pairs.values():
                require(stack and stack.pop() == char, f"{path}: unbalanced {char}")
        require(not stack, f"{path}: unclosed delimiter(s): {stack}")

        for opening, closing in keyword_pairs:
            open_count = len(re.findall(rf"\b{opening}\b", text))
            close_count = len(re.findall(rf"\b{closing}\b", text))
            require(
                open_count == close_count,
                f"{path}: {opening}/{closing} = {open_count}/{close_count}",
            )

        module_names.extend(
            re.findall(r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)", text)
        )

    duplicates = sorted(
        name for name in set(module_names) if module_names.count(name) > 1
    )
    require(not duplicates, f"duplicate module definitions: {duplicates}")

    required_modules = {
        "attention_board_top",
        "qk_parallel_systolic_gqa_top",
        "pv_parallel_systolic_gqa_top",
        "pv_tile4_pingpong_buffer",
    }
    require(
        required_modules.issubset(module_names),
        f"required v2.6 modules missing: {sorted(required_modules-set(module_names))}",
    )

    all_text = "\n".join(clean_sources)
    definitions = module_ports(all_text)
    require(set(definitions) == set(module_names), "module header audit mismatch")
    instance_count = named_port_audit(all_text, definitions)

    return len(rtl_files), len(module_names), instance_count


def text_contract_audit() -> None:
    contracts = {
        "rtl/board/attention_board_top.sv": (
            "parameter int QK_LANES = 2",
            "parameter int CAPTURE_TILE = 4",
            "parameter int PV_LANES = 2",
            "6'd46",
        ),
        "rtl/core/a/attention_system_with_rope_pv_top.sv": (
            "GEN_V25_CAPTURE_FALLBACK",
            "GEN_NATIVE_TILE4_PARALLEL_PV",
            "CAUSAL_QK_TILE_SKIP",
            "CAUSAL_PV_ROW_EFFECTIVE",
        ),
        "rtl/core/bc/qk/qk_parallel_systolic_gqa_top.sv": (
            "qk_tiles_computed",
            "qk_tiles_skipped",
            "masked_tiles_emitted",
        ),
        "rtl/core/pv/pv_parallel_systolic_gqa_top.sv": (
            "in_row_enable",
            "pv_reductions_computed",
            "pv_reductions_skipped",
        ),
        "vitis/src/fpt_attention_board_test.c": (
            "V26_CAUSAL_CSV",
            "PROF_QK_TILES_COMPUTED",
            "PROF_PV_REDUCTIONS_SKIPPED",
        ),
    }
    for relative, tokens in contracts.items():
        text = (ROOT / relative).read_text(encoding="utf-8")
        for token in tokens:
            require(token in text, f"{relative}: missing contract token {token!r}")


def validate_baseline_record() -> None:
    record = ROOT / "doc" / "V2_5_BASELINE_SHA256.md"
    require(record.is_file(), "missing v2.5 baseline SHA-256 record")
    require(BASELINE_SHA256 in record.read_text(encoding="utf-8"), "baseline hash mismatch")


def main() -> None:
    shape = Shape()
    qk_computed, qk_skipped = validate_qk(shape)
    pv_computed, pv_skipped, pv_beats, pv_total = validate_pv(shape)
    vectors_group, vectors_run = validate_native_tile4(shape)
    rtl_files, module_count, instance_count = structural_rtl_audit()
    text_contract_audit()
    validate_baseline_record()

    print("V26_ARCHITECTURE_CHECK: PASS")
    print(f"baseline_source_sha256={BASELINE_SHA256}")
    print(
        f"rtl_files={rtl_files}, module_definitions={module_count}, "
        f"named_instances_checked={instance_count}"
    )
    print(f"qk_tiles/group: computed={qk_computed}, skipped={qk_skipped}")
    print(
        "pv_terms/group: "
        f"computed={pv_computed}, skipped={pv_skipped}, total={pv_total}"
    )
    print(f"pv_input_beats/group={pv_beats}")
    print(
        "native_tile4_vectors: "
        f"per_group={vectors_group}, per_8group_run={vectors_run}"
    )
    print("fallback=QK_LANES=1,CAPTURE_TILE=2,PV_LANES=1")


if __name__ == "__main__":
    main()
