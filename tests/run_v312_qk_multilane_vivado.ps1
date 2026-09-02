param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,
    [string]$BuildRoot = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $env:TEMP "fpt_v312_qk_multilane_xsim"
}
$Xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$Xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$Xsim = Join-Path $VivadoRoot "bin\xsim.bat"
foreach ($Tool in @($Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "Vivado Simulator tool not found: $Tool"
    }
}

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$MemLink = Join-Path $BuildRoot "mem"
if (-not (Test-Path -LiteralPath $MemLink)) {
    New-Item -ItemType Junction -Path $MemLink `
        -Target (Join-Path $ProjectRoot "mem") | Out-Null
}

$Sources = @(
    (Join-Path $ProjectRoot "tb\tb_qk_fp32_mocks.sv"),
    (Join-Path $ProjectRoot "tb\tb_flash_fp32_mocks.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\bf16_to_fp32.v"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\fp32_to_bf16.v"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_pe.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_result_scaler.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_tile.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_parallel_systolic_gqa_top.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\backend\bf16_v_cache.sv"),
    (Join-Path $ProjectRoot "rtl\core\online\flash_score_tile_fifo.sv"),
    (Join-Path $ProjectRoot "rtl\core\online\flash_online_softmax_frontend.sv"),
    (Join-Path $ProjectRoot "rtl\core\online\flash_context_update_pe.sv"),
    (Join-Path $ProjectRoot "rtl\core\online\flash_context_fusion_backend.sv"),
    (Join-Path $ProjectRoot "rtl\core\online\flash_attention_consumer_top.sv"),
    (Join-Path $ProjectRoot "rtl\core\online\qk_flash_attention_pipeline_top.sv"),
    (Join-Path $ProjectRoot "tb\tb_v312_qk_multilane_equivalence.sv"),
    (Join-Path $ProjectRoot "tb\tb_v312_qk_multilane_flash_integration.sv")
)

Push-Location $BuildRoot
try {
    & $Xvlog --sv --nolog @Sources
    if ($LASTEXITCODE -ne 0) { throw "QK multilane xvlog failed" }

    $Top = "tb_v312_qk_multilane_equivalence"
    $Snapshot = "${Top}_sim"
    & $Xelab --nolog $Top -s $Snapshot
    if ($LASTEXITCODE -ne 0) { throw "QK multilane equivalence xelab failed" }
    $Result = & $Xsim --nolog $Snapshot -runall 2>&1
    $Result | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or
        -not ($Result -match "QK_MULTILANE_EQUIVALENCE_TEST: PASS")) {
        throw "QK multilane equivalence XSIM failed"
    }

    foreach ($Lanes in @(1, 2, 4, 8)) {
        $Top = "tb_v312_qk_multilane_flash_lanes$Lanes"
        $Snapshot = "${Top}_lanes${Lanes}_sim"
        & $Xelab --nolog $Top -s $Snapshot
        if ($LASTEXITCODE -ne 0) { throw "QK lane$Lanes Flash xelab failed" }
        $Result = & $Xsim --nolog $Snapshot -runall 2>&1
        $Result | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0 -or
            -not ($Result -match "QK_MULTILANE_FLASH_INTEGRATION_TEST: PASS lanes=$Lanes")) {
            throw "QK lane$Lanes Flash XSIM failed"
        }
    }
} finally {
    Pop-Location
}
Write-Host "[PASS] Vivado XSIM QK_LANES=1/2/4/8 checks passed."
