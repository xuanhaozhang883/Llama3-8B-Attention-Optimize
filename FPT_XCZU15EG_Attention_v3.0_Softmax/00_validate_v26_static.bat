@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
    echo [FAIL] python was not found.
    exit /b 1
)

python python\validate_v26_architecture.py
if errorlevel 1 (
    echo [FAIL] v2.6 host-side architecture checks failed.
    exit /b 1
)

echo [PASS] v2.6 host-side architecture checks passed.
exit /b 0
