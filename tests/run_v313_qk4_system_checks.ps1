param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$DefaultChecks = @(
    @{ Path = "rtl\board\attention_board_top.sv"; Pattern = 'parameter\s+int\s+QK_LANES\s*=\s*4' },
    @{ Path = "rtl\board\attention_board_top.sv"; Pattern = 'parameter\s+bit\s+CAUSAL_MODE\s*=\s*1''b1' },
    @{ Path = "rtl\board\fpt_attention_board_engine.sv"; Pattern = 'parameter\s+int\s+QK_LANES\s*=\s*4' },
    @{ Path = "rtl\core\a\flash_attention_system_with_rope_top.sv"; Pattern = 'parameter\s+int\s+QK_LANES\s*=\s*4' },
    @{ Path = "rtl\core\online\rope_qk_flash_attention_pipeline_top.sv"; Pattern = 'parameter\s+int\s+QK_LANES\s*=\s*4' },
    @{ Path = "rtl\core\online\qk_flash_attention_pipeline_top.sv"; Pattern = 'parameter\s+int\s+QK_LANES\s*=\s*4' },
    @{ Path = "scripts\create_attention_board_project.tcl"; Pattern = 'set\s+qk_lanes\s+4' },
    @{ Path = "scripts\create_attention_board_project.tcl"; Pattern = 'FPT_QK_LANES must be 1, 2, 4, or 8' }
)

foreach ($Check in $DefaultChecks) {
    $Path = Join-Path $ProjectRoot $Check.Path
    if (-not (Select-String -LiteralPath $Path -Pattern $Check.Pattern -Quiet)) {
        throw "QK4 system configuration check failed: $($Check.Path)"
    }
}
Write-Host "[PASS] QK4 system defaults and build-profile guard verified."

$Runners = @(
    "run_v312_qk_multilane_checks.ps1",
    "run_v312_qk_multilane_flash_checks.ps1",
    "run_v31_flash_consumer_checks.ps1"
)
foreach ($Runner in $Runners) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot $Runner)
    if ($LASTEXITCODE -ne 0) {
        throw "$Runner failed"
    }
}

& powershell -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot "run_v31_flash_numerical_model.ps1") `
    -FullGqa `
    -ResultPath (Join-Path $env:TEMP "v314_qk4_full_gqa_numerical.json")
if ($LASTEXITCODE -ne 0) {
    throw "Full-GQA FlashAttention numerical regression failed"
}

Write-Host "============================================================"
Write-Host "[PASS] V3.1.4 QK4 causal-bypass system checks passed"
Write-Host "Covers : QK equivalence, causal skip, random backpressure"
Write-Host "         full consumer integration, causal consumer bypass"
Write-Host "         legacy regression and full-GQA numerical model"
Write-Host "============================================================"
