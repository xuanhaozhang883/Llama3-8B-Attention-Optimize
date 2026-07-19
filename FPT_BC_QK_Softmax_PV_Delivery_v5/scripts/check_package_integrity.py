#!/usr/bin/env python3
"""Check required files and XSim-exported data basenames."""
from pathlib import Path
from collections import defaultdict
from hashlib import sha256
import re

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    'rtl/adapter/causal_mask_stream.sv',
    'rtl/adapter/score_rowtile_payload_bram.sv',
    'rtl/adapter/score_rowtile_buffer.sv',
    'rtl/adapter/qk_softmax_adapter.sv',
    'rtl/softmax/softmax_bf16.sv',
    'rtl/integration/qk_softmax_frontend.sv',
    'rtl/integration/qk_softmax_pipeline_top.sv',
    'rtl/qk/qk_systolic_gqa_top.sv',
    'tb/tb_qk_adapter_integration.sv',
    'tb/tb_qk_softmax_pipeline_small.sv',
    'tb/tb_qk_softmax_group_control.sv',
    'tb/tb_qk_softmax_frontend_golden.sv',
    'tb/tb_qk_softmax_reset_recovery.sv',
    'scripts/run_vivado_v4_quick.tcl',
    'scripts/run_vivado_v4_all.tcl',
    'scripts/run_synthesis_frontend_only.tcl',
    'scripts/run_synthesis_full_pipeline.tcl',
    'rtl/backend/softmax_output_buffer.sv',
    'rtl/backend/pv_input_loader.sv',
    'rtl/backend/softmax_pv_backend.sv',
    'rtl/backend/bf16_v_cache.sv',
    'rtl/integration/qk_softmax_pv_pipeline_top.sv',
    'rtl/integration/gqa_group_controller.sv',
    'rtl/integration/qk_softmax_pv_system_top.sv',
    'tb/tb_qk_softmax_pv_pipeline.sv',
    'tb/tb_bc_robustness.sv',
    'tb/tb_qk_softmax_pv_all_groups.sv',
    'scripts/run_vivado_bc_small.tcl',
    'scripts/run_vivado_bc_full_optional.tcl',
    'scripts/run_vivado_bc_extended.tcl',
    'scripts/run_synthesis_bc_pipeline.tcl',
    'scripts/run_synthesis_bc_system.tcl',
    'scripts/run_synthesis_row_buffer.tcl',
    'scripts/synthesis_bc_common.tcl',
    'scripts/check_v3_design.py',
    'scripts/check_bf16_to_fixed_equivalence.py',
    'scripts/check_exp_pipeline_equivalence.py',
    'scripts/analyze_v4_timing_evidence.py',
    'scripts/check_row_buffer_schedule.py',
    'scripts/build_manifest.py',
    'run_vivado_bc_all.tcl',
    'run_vivado_bc_extended.tcl',
    'run_synthesis_bc_pipeline.tcl',
    'run_synthesis_bc_system.tcl',
    'run_synthesis_row_buffer.tcl',
    'doc/BC_INTERFACE_CONTRACT.md',
    'doc/A_HANDOFF_BC.md',
    'doc/SECTION_FIVE_COMPLETION.md',
    'doc/ARTIX7_TIMING_FIX_V5.md',
]


def strip_sv_comments_and_strings(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//.*', ' ', text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    return text


def check_sv_structure(path: Path) -> list[str]:
    text = strip_sv_comments_and_strings(path.read_text(encoding='utf-8'))
    failures: list[str] = []
    pairs = [
        ('module', 'endmodule'),
        ('begin', 'end'),
        ('case', 'endcase'),
        ('function', 'endfunction'),
        ('task', 'endtask'),
        ('generate', 'endgenerate'),
    ]
    for opening, closing in pairs:
        left = len(re.findall(rf'\b{opening}\b', text))
        right = len(re.findall(rf'\b{closing}\b', text))
        if left != right:
            failures.append(f'{path.relative_to(ROOT)}: {opening}={left}, '
                            f'{closing}={right}')
    for opening, closing in [('(', ')'), ('[', ']'), ('{', '}')]:
        if text.count(opening) != text.count(closing):
            failures.append(f'{path.relative_to(ROOT)}: unbalanced '
                            f'{opening}{closing}')
    return failures


def main() -> None:
    missing = [name for name in REQUIRED if not (ROOT / name).is_file()]
    if missing:
        raise SystemExit('Missing required files:\n' + '\n'.join(missing))

    # Vivado exports memory initialization files by basename into the XSim work
    # directory. Duplicate .mem/.hex basenames can silently select wrong data.
    by_name: dict[str, list[Path]] = defaultdict(list)
    for suffix in ('*.mem', '*.hex'):
        for path in ROOT.rglob(suffix):
            by_name[path.name].append(path)
    duplicates = {name: paths for name, paths in by_name.items() if len(paths) > 1}
    if duplicates:
        lines = []
        for name, paths in sorted(duplicates.items()):
            lines.append(name + ':')
            lines.extend('  ' + str(p.relative_to(ROOT)) for p in paths)
        raise SystemExit('Duplicate runtime data basenames:\n' + '\n'.join(lines))

    structure_failures: list[str] = []
    for path in ROOT.rglob('*.sv'):
        structure_failures.extend(check_sv_structure(path))
    if structure_failures:
        raise SystemExit('SystemVerilog structure failures:\n' +
                         '\n'.join(structure_failures))

    manifest_path = ROOT / 'MANIFEST_SHA256.txt'
    manifest_failures: list[str] = []
    for line in manifest_path.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        digest, relative = line.split('  ./', 1)
        target = ROOT / relative
        if not target.is_file():
            manifest_failures.append(f'missing: {relative}')
        elif sha256(target.read_bytes()).hexdigest() != digest:
            manifest_failures.append(f'hash mismatch: {relative}')
    if manifest_failures:
        raise SystemExit('Manifest failures:\n' + '\n'.join(manifest_failures))

    print(f'PASS: package integrity, required_files={len(REQUIRED)}')
    print(f'HDL={sum(1 for _ in ROOT.rglob("*.sv")) + sum(1 for _ in ROOT.rglob("*.v"))}')
    print(f'TB={sum(1 for _ in (ROOT / "tb").glob("*.sv"))}')
    print('PASS: SystemVerilog token and bracket balance')
    print('PASS: SHA-256 manifest')


if __name__ == '__main__':
    main()
