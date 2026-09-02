@echo off
setlocal
cd /d "%~dp0"

where xsct.bat >nul 2>nul
if errorlevel 1 (
    echo [FAIL] xsct.bat was not found. Call Vitis 2025.2 settings64.bat first.
    exit /b 1
)

call xsct.bat scripts/create_vitis_app_xsct.tcl
if errorlevel 1 (
    echo [FAIL] v3.1.3 Vitis application build failed.
    exit /b 1
)

echo [PASS] v3.1.3 Vitis application build passed.
exit /b 0
