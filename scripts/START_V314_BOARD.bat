@echo off
setlocal
set "BOARD_ROOT=D:\fpt_gui\v314"
set "BOARD_PORT=%~1"
if not defined BOARD_PORT set "BOARD_PORT=COM3"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOARD_ROOT%\tools\ready_and_run_v314_board.ps1" -Root "%BOARD_ROOT%" -Port "%BOARD_PORT%"
set "BOARD_EXIT=%ERRORLEVEL%"
echo.
if "%BOARD_EXIT%"=="0" (
    echo [PASS] Board flow completed.
) else (
    echo [FAIL] Board flow stopped with exit code %BOARD_EXIT%.
)
pause
exit /b %BOARD_EXIT%
