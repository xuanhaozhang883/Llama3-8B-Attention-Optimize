$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $env:TEMP "fpt_v312_qk_flash_iverilog"
$Iverilog = (Get-Command iverilog -ErrorAction Stop).Source
$Vvp = (Get-Command vvp -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

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
    (Join-Path $ProjectRoot "tb\tb_v312_qk_multilane_flash_integration.sv")
)

foreach ($Lanes in @(1, 2, 4, 8)) {
    $Output = Join-Path $BuildRoot "tb_v312_qk_flash_lanes$Lanes.vvp"
    & $Iverilog -g2012 -s tb_v312_qk_multilane_flash_integration `
        "-Ptb_v312_qk_multilane_flash_integration.QK_LANES=$Lanes" `
        -o $Output $Sources
    if ($LASTEXITCODE -ne 0) {
        throw "QK lane$Lanes Flash integration compilation failed"
    }
    $Result = & $Vvp $Output 2>&1
    $Result | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or
        -not ($Result -match "QK_MULTILANE_FLASH_INTEGRATION_TEST: PASS lanes=$Lanes")) {
        throw "QK lane$Lanes Flash integration regression failed"
    }
}
Write-Host "[PASS] QK_LANES=1/2/4/8 full FlashAttention integration checks passed."
