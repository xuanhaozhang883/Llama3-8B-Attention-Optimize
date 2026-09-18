$ErrorActionPreference = 'Stop'

$repo = 'C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09\03_work_v314_causal_bypass\workspace\Llama3-8B-Attention-Optimize-ABL-v314'
$out = 'C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09\03_work_v314_causal_bypass\workspace\D\output\BOARD_VALIDATION_2026-09-13'
$xsa = Join-Path $out 'artifacts\archive_extract\export\fpt_attention_board_v314_qk4_causal_bypass.xsa'
$vitisWorkspace = 'D:\fv314_0913'
$logDir = Join-Path $out 'logs'
$log = Join-Path $logDir 'vitis_build.log'

New-Item -ItemType Directory -Force -Path $vitisWorkspace, $logDir | Out-Null
$env:FPT_XSA_OVERRIDE = $xsa
$env:FPT_VITIS_WORKSPACE = $vitisWorkspace
$env:XILINXD_LICENSE_FILE = 'C:\Users\23858\AppData\Roaming\XilinxLicense\Xilinx_Enterprise_2026.lic'

& 'D:\2025.2\Vitis\bin\xsct.bat' (Join-Path $repo 'scripts\create_vitis_app_xsct.tcl') 2>&1 |
    Tee-Object -FilePath $log
$xsctExit = $LASTEXITCODE
$appElf = Join-Path $vitisWorkspace 'fpt_attention_test\Debug\fpt_attention_test.elf'
if (-not (Test-Path -LiteralPath $appElf)) {
    $xsctExit = 1
    Add-Content -LiteralPath $log -Value "FAIL: expected ELF was not generated: $appElf"
}
Set-Content -LiteralPath (Join-Path $logDir 'vitis_build_exit_code.txt') -Value $xsctExit
exit $xsctExit
