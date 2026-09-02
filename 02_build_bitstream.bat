@echo off
setlocal
cd /d "%~dp0"

where vivado.bat >nul 2>nul
if errorlevel 1 (
    echo [FAIL] vivado.bat was not found. Call Vivado 2025.2 settings64.bat first.
    exit /b 1
)

call vivado.bat -mode batch -nolog -nojournal ^
    -source scripts/run_all.tcl
if errorlevel 1 (
    echo [FAIL] v3.1.3 synthesis/implementation/bitstream build failed.
    exit /b 1
)

echo [PASS] v3.1.3 bitstream and XSA build passed.
exit /b 0
