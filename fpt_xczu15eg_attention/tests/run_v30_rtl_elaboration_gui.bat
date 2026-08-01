@echo off
setlocal
if not defined FPT_VIVADO_ROOT set "FPT_VIVADO_ROOT=D:\Vitis\2025.2\Vivado"
if not exist "%FPT_VIVADO_ROOT%\bin\vivado.bat" (
    echo [FAIL] Vivado was not found at %FPT_VIVADO_ROOT%
    pause
    exit /b 1
)
set "XILINX_LOCAL_USER_DATA=NO"
set "XILINX_TCLAPP_REPO=%FPT_VIVADO_ROOT%\data\XilinxTclStore"
if not defined FPT_VIVADO_BUILD_ROOT set "FPT_VIVADO_BUILD_ROOT=%TEMP%\fpt_v30_elab"
if not exist "%FPT_VIVADO_BUILD_ROOT%" mkdir "%FPT_VIVADO_BUILD_ROOT%"
start "" "%FPT_VIVADO_ROOT%\bin\vivado.bat" -mode gui ^
  -source "%~dp0..\scripts\check_rtl_elaboration.tcl"
endlocal
