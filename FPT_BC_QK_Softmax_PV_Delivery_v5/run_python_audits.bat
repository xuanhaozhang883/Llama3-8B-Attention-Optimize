@echo off
python scripts\check_package_integrity.py || exit /b 1
python scripts\analyze_v4_timing_evidence.py || exit /b 1
python scripts\check_v4_vectors.py || exit /b 1
python scripts\check_bf16_to_fixed_equivalence.py || exit /b 1
python scripts\check_exp_pipeline_equivalence.py || exit /b 1
python scripts\check_softmax_rtl_reference.py || exit /b 1
python scripts\check_bc_contract.py || exit /b 1
python scripts\check_v3_design.py || exit /b 1
python scripts\check_row_buffer_schedule.py || exit /b 1
echo All Python audits passed.
