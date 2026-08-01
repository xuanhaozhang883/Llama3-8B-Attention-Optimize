@echo off
setlocal

rem Double-click entry for the Gate 0 closure in Vivado GUI.
rem Every environment change is local to the newly launched Vivado process.

if not defined FPT_VIVADO_ROOT (
    set "FPT_VIVADO_ROOT=D:\Vitis\2025.2\Vivado"
)
if not exist "%FPT_VIVADO_ROOT%\bin\vivado.bat" (
    echo [FAIL] Vivado was not found:
    echo        %FPT_VIVADO_ROOT%\bin\vivado.bat
    echo Set FPT_VIVADO_ROOT to the Vivado installation directory.
    pause
    exit /b 1
)

rem Gate 0 does not use downloadable Tcl Store apps. Keep this GUI session
rem independent of a missing or read-only Windows user Tcl Store.
set "XILINX_LOCAL_USER_DATA=NO"
set "XILINX_TCLAPP_REPO=%FPT_VIVADO_ROOT%\data\XilinxTclStore"

rem A short generated-project path avoids nested Vivado Windows path issues.
rem Set FPT_VIVADO_BUILD_ROOT before launching this file to override it.
if not defined FPT_VIVADO_BUILD_ROOT (
    set "FPT_VIVADO_BUILD_ROOT=%TEMP%\fpt_gate0"
)
if not exist "%FPT_VIVADO_BUILD_ROOT%" (
    mkdir "%FPT_VIVADO_BUILD_ROOT%"
)
set "FPT_GATE0_TEMP=%FPT_VIVADO_BUILD_ROOT%\tmp"
if not exist "%FPT_GATE0_TEMP%" (
    mkdir "%FPT_GATE0_TEMP%"
)

echo Starting Vivado GUI Gate 0 closure...
echo Vivado    : %FPT_VIVADO_ROOT%
echo Build root: %FPT_VIVADO_BUILD_ROOT%
echo.

start "" "%FPT_VIVADO_ROOT%\bin\vivado.bat" ^
    -mode gui ^
    -log "%FPT_VIVADO_BUILD_ROOT%\gate0_vivado.log" ^
    -journal "%FPT_VIVADO_BUILD_ROOT%\gate0_vivado.jou" ^
    -tempDir "%FPT_GATE0_TEMP%" ^
    -source "%~dp0run_gate0_legacy_closure.tcl"

endlocal
