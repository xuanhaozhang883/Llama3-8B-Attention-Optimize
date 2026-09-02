$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $env:TEMP "fpt_v312_qk_multilane_iverilog"
$Iverilog = (Get-Command iverilog -ErrorAction Stop).Source
$Vvp = (Get-Command vvp -ErrorAction Stop).Source

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$Output = Join-Path $BuildRoot "tb_v312_qk_multilane_equivalence.vvp"
$Sources = @(
    (Join-Path $ProjectRoot "tb\tb_qk_fp32_mocks.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\bf16_to_fp32.v"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\fp32_to_bf16.v"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_pe.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_result_scaler.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_tile.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_parallel_systolic_gqa_top.sv"),
    (Join-Path $ProjectRoot "tb\tb_v312_qk_multilane_equivalence.sv")
)

& $Iverilog -g2012 -s tb_v312_qk_multilane_equivalence -o $Output $Sources
if ($LASTEXITCODE -ne 0) {
    throw "QK multilane compilation failed"
}
$Result = & $Vvp $Output 2>&1
$Result | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0 -or
    -not ($Result -match "QK_MULTILANE_EQUIVALENCE_TEST: PASS")) {
    throw "QK multilane equivalence regression failed"
}
Write-Host "[PASS] QK_LANES=1/2/4/8 equivalence, causal skip, and backpressure checks passed."
