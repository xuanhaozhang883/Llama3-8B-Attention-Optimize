@echo off
setlocal

if defined VIVADO_BIN (
    set "RK_VIVADO_LAUNCHER=%VIVADO_BIN%"
) else (
    set "RK_VIVADO_LAUNCHER=D:\Vitis\2025.2\Vivado\bin\vivado.bat"
)

set "RK_STAGE1H_XPR=%~dp0..\vx\rk_pl_selftest.xpr"

if not exist "%RK_VIVADO_LAUNCHER%" (
    echo [ERROR] Vivado launcher not found:
    echo         %RK_VIVADO_LAUNCHER%
    echo Set VIVADO_BIN to the full vivado.bat path and run again.
    pause
    exit /b 1
)

if not exist "%RK_STAGE1H_XPR%" (
    echo [ERROR] Stage 1H Vivado project not found:
    echo         %RK_STAGE1H_XPR%
    echo Recreate the project with run_stage1.ps1 -Mode project.
    pause
    exit /b 1
)

echo Opening RK-XCZU15EG-F Stage 1H project in Vivado GUI...
start "" "%RK_VIVADO_LAUNCHER%" -mode gui "%RK_STAGE1H_XPR%"
exit /b 0
