param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $ProjectRoot ".Xil\xsim_v31_flash_consumer"
$Xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$Xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$Xsim = Join-Path $VivadoRoot "bin\xsim.bat"

foreach ($Tool in @($Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "Vivado Simulator tool not found: $Tool"
    }
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$MemLink = Join-Path $BuildDir "mem"
if (-not (Test-Path -LiteralPath $MemLink)) {
    New-Item -ItemType Junction -Path $MemLink `
        -Target (Join-Path $ProjectRoot "mem") | Out-Null
}
$Tests = @(
    @{
        Name = "tb_v31_flash_score_tile_fifo_multigroup"
        Pass = "FLASH_SCORE_TILE_FIFO_MULTIGROUP_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "rtl\core\online\flash_score_tile_fifo.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_flash_score_tile_fifo_multigroup.sv")
        )
    },
    @{
        Name = "tb_v31_flash_score_tile_fifo"
        Pass = "FLASH_SCORE_TILE_FIFO_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "rtl\core\online\flash_score_tile_fifo.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_flash_score_tile_fifo.sv")
        )
    },
    @{
        Name = "tb_v31_flash_online_softmax_frontend"
        Pass = "FLASH_ONLINE_SOFTMAX_FRONTEND_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_online_softmax_frontend.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_flash_online_softmax_frontend.sv")
        )
    },
    @{
        Name = "tb_v31_flash_context_fusion_backend"
        Pass = "FLASH_CONTEXT_FUSION_BACKEND_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "tb\tb_flash_fp32_mocks.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_update_pe.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_fusion_backend.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_flash_context_fusion_backend.sv")
        )
    },
    @{
        Name = "tb_v31_flash_attention_consumer_top"
        Pass = "FLASH_ATTENTION_CONSUMER_TOP_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "tb\tb_flash_fp32_mocks.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\backend\bf16_v_cache.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_score_tile_fifo.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_online_softmax_frontend.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_update_pe.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_fusion_backend.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_attention_consumer_top.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_flash_attention_consumer_top.sv")
        )
    },
    @{
        Name = "tb_v31_flash_attention_consumer_multigroup"
        Pass = "FLASH_ATTENTION_CONSUMER_MULTIGROUP_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "tb\tb_flash_fp32_mocks.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\backend\bf16_v_cache.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_score_tile_fifo.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_online_softmax_frontend.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_update_pe.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_fusion_backend.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_attention_consumer_top.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_flash_attention_consumer_multigroup.sv")
        )
    },
    @{
        Name = "tb_v31_qk_flash_attention_pipeline_top"
        Pass = "QK_FLASH_ATTENTION_PIPELINE_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "tb\tb_flash_fp32_mocks.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\backend\bf16_v_cache.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_score_tile_fifo.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_online_softmax_frontend.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_update_pe.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_context_fusion_backend.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\flash_attention_consumer_top.sv"),
            (Join-Path $ProjectRoot "rtl\core\online\qk_flash_attention_pipeline_top.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_qk_flash_attention_pipeline_top.sv")
        )
    },
    @{
        Name = "tb_v31_v_ddr_loader_lanes8"
        Pass = "V_DDR_LOADER_LANES8_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "rtl\board\fpt_v_ddr_loader.sv"),
            (Join-Path $ProjectRoot "tb\tb_v31_v_ddr_loader_lanes8.sv")
        )
    },
    @{
        Name = "tb_v31_real_qk_flash_attention_pipeline_top"
        Pass = "REAL_QK_FLASH_PIPELINE_TEST: PASS"
        Sources = @(
            (Join-Path $ProjectRoot "tb\tb_qk_fp32_mocks.sv"),
            (Join-Path $ProjectRoot "tb\tb_flash_fp32_mocks.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\qk\bf16_to_fp32.v"),
            (Join-Path $ProjectRoot "rtl\core\bc\qk\fp32_to_bf16.v"),
            (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_pe.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_result_scaler.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_tile.sv"),
            (Join-Path $ProjectRoot "rtl\core\bc\qk\qk_systolic_gqa_top.sv"),
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
            (Join-Path $ProjectRoot "tb\tb_v31_real_qk_flash_attention_pipeline_top.sv")
        )
    }
)

Push-Location $BuildDir
try {
    foreach ($Test in $Tests) {
        & $Xvlog --sv --nolog @($Test.Sources)
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado compilation failed for $($Test.Name)"
        }
        $Snapshot = "$($Test.Name)_sim"
        & $Xelab --nolog $Test.Name -s $Snapshot
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado elaboration failed for $($Test.Name)"
        }
        $Output = & $Xsim $Snapshot --runall --nolog 2>&1
        $ExitCode = $LASTEXITCODE
        $Output | Write-Host
        if (($ExitCode -ne 0) -or (($Output -join "`n") -notmatch $Test.Pass)) {
            throw "Vivado simulation failed for $($Test.Name)"
        }
    }
} finally {
    Pop-Location
}

Write-Host "[PASS] Vivado v3.1 FlashAttention consumer checks passed."
