param(
    [ValidateSet(0, 1)]
    [int]$Mode = 0,
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = ''
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_a3_compute_cluster_' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'a3_compute_cluster.vvp'
$Sources = @(
    'rtl\core\bc\qk\bf16_to_fp32.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_fp32_service.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_engine.sv',
    'rtl\core\bc\qk\cats_r4_qk_q_slab_client.sv',
    'rtl\core\bc\qk\cats_r4_qk_score_formatter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_assembler.sv',
    'rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv',
    'rtl\core\bc\qk\cats_r4_qk_slot_lifecycle.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_handoff_wrapper.sv',
    'rtl\core\bc\qk\cats_r4_qk_a2_row_pipeline.sv',
    'rtl\core\bc\qk\cats_r4_qk_score_slot_mem.sv',
    'rtl\core\bc\integration\cats_r4_a3_row_frontend.sv',
    'rtl\core\bc\softmax\exp_lut.sv',
    'rtl\core\bc\softmax\unsigned_restoring_divider.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv',
    'rtl\core\bc\softmax\cats_r4_b2_compatibility_core_adapter.sv',
    'rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_accuracy.sv',
    'rtl\core\bc\softmax\cats_r4_b2_locking_arbiter.sv',
    'rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv',
    'rtl\core\bc\softmax\cats_r4_b2_shared_stager_v3_wrapper.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv',
    'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv',
    'rtl\core\bc\integration\cats_r4_a3_error_join.sv',
    'rtl\core\bc\integration\cats_r4_a3_compute_cluster.sv',
    'tb\tb_cats_r4_b4_c_weight_model.sv',
    'tb\tb_cats_r4_a3_compute_cluster.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }
try {
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 `
        -gno-shared-loop-index -s tb_cats_r4_a3_compute_cluster `
        "-Ptb_cats_r4_a3_compute_cluster.MODE=$Mode" `
        -o $Snapshot @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }
    Push-Location $ProjectRoot
    try { $Runtime = & (Join-Path $IcarusRoot 'bin\vvp.exe') $Snapshot 2>&1 }
    finally { Pop-Location }
    $Runtime | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (($Runtime -join "`n").Contains(
        "PASS A3 COMPUTE CLUSTER mode=$Mode"))) {
        throw 'A3 compute-cluster PASS marker missing'
    }
    Write-Host "[PASS] CATS-R4 A3 compute cluster mode=$Mode"
} finally {
    if (Test-Path -LiteralPath $OutputRoot) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
