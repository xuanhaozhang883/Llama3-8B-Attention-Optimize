@echo off
setlocal

if not defined FPT_VIVADO_ROOT (
    set "FPT_VIVADO_ROOT=D:\Vitis\2025.2\Vivado"
)
if not exist "%FPT_VIVADO_ROOT%\bin\vivado.bat" (
    echo [FAIL] Vivado was not found at %FPT_VIVADO_ROOT%
    pause
    exit /b 1
)

set "XILINX_LOCAL_USER_DATA=NO"
set "XILINX_TCLAPP_REPO=%FPT_VIVADO_ROOT%\data\XilinxTclStore"
if not defined FPT_V30_BUILD_ROOT (
    set "FPT_V30_BUILD_ROOT=%TEMP%\fpt_v30_online"
)
if not exist "%FPT_V30_BUILD_ROOT%" mkdir "%FPT_V30_BUILD_ROOT%"
set "FPT_V30_TEMP=%FPT_V30_BUILD_ROOT%\tmp"
if not exist "%FPT_V30_TEMP%" mkdir "%FPT_V30_TEMP%"

echo Starting the v3.0 Online Softmax XSim regression in Vivado GUI...
echo Generated files: %FPT_V30_BUILD_ROOT%
start "" "%FPT_VIVADO_ROOT%\bin\vivado.bat" ^
    -mode gui ^
    -log "%FPT_V30_BUILD_ROOT%\v30_vivado.log" ^
    -journal "%FPT_V30_BUILD_ROOT%\v30_vivado.jou" ^
    -tempDir "%FPT_V30_TEMP%" ^
    -source "%~dp0run_v30_online_fused_regression.tcl"

endlocal
