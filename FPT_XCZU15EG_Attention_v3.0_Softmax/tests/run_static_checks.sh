#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_dir="$(mktemp -d)"
trap 'rm -rf "$result_dir"' EXIT

python3 "$root_dir/python/validate_v26_architecture.py"
python3 "$root_dir/python/validate_profile_contract.py"
python3 -m py_compile "$root_dir"/python/*.py

gcc -std=gnu11 -fsyntax-only \
    -I"$root_dir/tests/host_stubs" \
    -I"$root_dir/vitis/src" \
    "$root_dir/vitis/src/fpt_attention_board_test.c"

python3 "$root_dir/python/parse_v23_profile_log.py" \
    "$root_dir/logs/v2.4_hardware_profile_10run.txt" \
    --out-dir "$result_dir"
python3 "$root_dir/python/validate_profile_results.py" \
    "$result_dir/v23_hardware_profile_runs.csv" \
    --expected-runs 10

echo "[PASS] all host-side static checks"
