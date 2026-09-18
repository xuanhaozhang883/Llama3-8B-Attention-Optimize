$ErrorActionPreference = 'Stop'

$repo = 'C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09\03_work_v314_causal_bypass\workspace\Llama3-8B-Attention-Optimize-ABL-v314'
$statusDir = 'C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09\03_work_v314_causal_bypass\workspace\D\board_build_status'

New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
$env:XILINXD_LICENSE_FILE = 'C:\Users\23858\Downloads\Xilinx (1).lic'
$env:FPT_VIVADO_BUILD_ROOT = 'D:\fpt_build\v314_detached'

Set-Location -LiteralPath $repo
& 'D:\2025.2\Vivado\bin\vivado.bat' `
    -mode batch `
    -source "$repo\scripts\build_attention_board_all.tcl" `
    -tclargs 4 `
    *> "$statusDir\vivado_build_console.log"

$LASTEXITCODE | Set-Content -LiteralPath "$statusDir\vivado_build_exit_code.txt"
exit $LASTEXITCODE
