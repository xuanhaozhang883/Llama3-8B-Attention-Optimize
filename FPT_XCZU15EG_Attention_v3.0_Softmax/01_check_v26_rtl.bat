@echo off
setlocal
cd /d "%~dp0"

where vivado.bat >nul 2>nul
if errorlevel 1 (
    echo [FAIL] vivado.bat was not found. Call Vivado 2024.2 settings64.bat first.
    exit /b 1
)

call vivado.bat -mode batch -nolog -nojournal ^
    -source scripts/check_rtl_elaboration_ipfix.tcl
if errorlevel 1 (
    echo [FAIL] v2.6 full RTL elaboration failed.
    exit /b 1
)

echo [PASS] v2.6 full RTL elaboration passed.
exit /b 0
