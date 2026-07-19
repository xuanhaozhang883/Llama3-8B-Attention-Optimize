#!/usr/bin/env bash
set -euo pipefail
python3 scripts/check_package_integrity.py
python3 scripts/analyze_v4_timing_evidence.py
python3 scripts/check_v4_vectors.py
python3 scripts/check_bf16_to_fixed_equivalence.py
python3 scripts/check_exp_pipeline_equivalence.py
python3 scripts/check_softmax_rtl_reference.py
python3 scripts/check_bc_contract.py
python3 scripts/check_v3_design.py
python3 scripts/check_row_buffer_schedule.py
echo "All Python audits passed."
