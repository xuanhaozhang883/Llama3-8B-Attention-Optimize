param(
    [ValidateSet(0, 1)] [int]$Mode = 0,
    [int]$Seed = 7,
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = '',
    [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_a3_stress_' + $Mode + '_' + $Seed + '_' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'a3_stress.vvp'
$Stdout = Join-Path $OutputRoot 'vvp.stdout.log'
$Stderr = Join-Path $OutputRoot 'vvp.stderr.log'
$Sources = @(
    'rtl\core\bc\qk\bf16_to_fp32.v','rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv','rtl\core\bc\qk\cats_r4_qk_32lane_fp32_service.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_engine.sv','rtl\core\bc\qk\cats_r4_qk_q_slab_client.sv',
    'rtl\core\bc\qk\cats_r4_qk_score_formatter.sv','rtl\core\bc\qk\cats_r4_qk_row_assembler.sv',
    'rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv','rtl\core\bc\qk\cats_r4_qk_slot_lifecycle.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv','rtl\core\bc\qk\cats_r4_qk_row_handoff_wrapper.sv',
    'rtl\core\bc\qk\cats_r4_qk_a2_row_pipeline.sv','rtl\core\bc\qk\cats_r4_qk_score_slot_mem.sv',
    'rtl\core\bc\integration\cats_r4_a3_row_frontend.sv','rtl\core\bc\softmax\exp_lut.sv',
    'rtl\core\bc\softmax\unsigned_restoring_divider.sv','rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv',
    'rtl\core\bc\softmax\cats_r4_b2_compatibility_core_adapter.sv','rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv','rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_accuracy.sv','rtl\core\bc\softmax\cats_r4_b2_locking_arbiter.sv',
    'rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv','rtl\core\bc\softmax\cats_r4_b2_shared_stager_v3_wrapper.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv','rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv','rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv',
    'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv','rtl\core\bc\integration\cats_r4_a3_error_join.sv',
    'rtl\core\bc\integration\cats_r4_a3_compute_cluster.sv','tb\tb_cats_r4_b4_c_weight_model.sv',
    'tb\tb_cats_r4_a3_compute_cluster_stress.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }
$Phases = @('fill_three_slots','independent_weight_v_output_release_backpressure',
    'reset_with_pending_score_response','clear_with_old_epoch_qk_response',
    'qk_engine_error_report_retire_clear_restart','a2_nonfinite_score_abort',
    'b4_score_token_error','simultaneous_a_side_and_b4_error',
    'slot_reuse_after_final_release')
try {
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -gno-shared-loop-index `
        -s tb_cats_r4_a3_compute_cluster_stress `
        "-Ptb_cats_r4_a3_compute_cluster_stress.MODE=$Mode" `
        "-Ptb_cats_r4_a3_compute_cluster_stress.SEED=$Seed" -o $Snapshot @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }
    $proc = Start-Process -FilePath (Join-Path $IcarusRoot 'bin\vvp.exe') `
        -ArgumentList @($Snapshot) -WorkingDirectory $ProjectRoot -WindowStyle Hidden `
        -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        $proc.Kill(); throw "A3 stress timeout mode=$Mode seed=$Seed phase=unknown"
    }
    $runtime = @()
    if (Test-Path $Stdout) { $runtime += Get-Content $Stdout }
    if (Test-Path $Stderr) { $runtime += Get-Content $Stderr }
    $runtime | ForEach-Object { Write-Host $_ }
    if ($proc.ExitCode -ne 0) { throw "vvp failed: $($proc.ExitCode)" }
    $joined = $runtime -join "`n"
    foreach ($phase in $Phases) {
        $needle = "PASS A3 STRESS mode=$Mode seed=$Seed phase=$phase"
        if (([regex]::Matches($joined, [regex]::Escape($needle))).Count -ne 1) {
            throw "A3 stress phase marker count mismatch: $phase"
        }
    }
    $summary = "PASS A3 STRESS SUMMARY mode=$Mode seed=$Seed phases=9"
    if (-not $joined.Contains($summary)) { throw 'A3 stress summary marker missing' }
    Write-Host "[PASS] CATS-R4 A3 stress mode=$Mode seed=$Seed"
} finally {
    if (Test-Path -LiteralPath $OutputRoot) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
