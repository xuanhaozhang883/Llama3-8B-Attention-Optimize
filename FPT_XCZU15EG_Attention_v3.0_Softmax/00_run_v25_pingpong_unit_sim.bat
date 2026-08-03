@echo off
setlocal
cd /d "%~dp0"

where vivado.bat >nul 2>nul
if errorlevel 1 (
    echo [FAIL] vivado.bat was not found. Call Vivado 2024.2 settings64.bat first.
    exit /b 1
)

call vivado.bat -mode batch -nolog -nojournal ^
    -source scripts/run_v25_pingpong_unit_sim.tcl
if errorlevel 1 (
    echo [FAIL] v2.5 Ping-Pong unit simulation failed.
    exit /b 1
)

echo [PASS] v2.5 Ping-Pong unit simulation passed.
exit /b 0
