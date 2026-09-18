$ErrorActionPreference = 'Stop'
$base = 'C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09\03_work_v314_causal_bypass\workspace'
$script = Join-Path $base 'D\rebuild_vitis_app_python_2025_2.py'
$logDir = Join-Path $base 'D\output\BOARD_VALIDATION_2026-09-13\logs'
$log = Join-Path $logDir 'vitis_app_rebuild.log'

& 'D:\2025.2\Vitis\bin\vitis.bat' -s $script 2>&1 | Tee-Object -FilePath $log
$buildExit = $LASTEXITCODE
$appElf = Get-ChildItem -LiteralPath 'D:\fv314py_0913\fpt_attention_test_py' -Recurse -File -Filter '*.elf' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $appElf) {
    $buildExit = 1
    Add-Content -LiteralPath $log -Value 'FAIL: application ELF was not generated.'
}
Set-Content -LiteralPath (Join-Path $logDir 'vitis_app_rebuild_exit_code.txt') -Value $buildExit
exit $buildExit
