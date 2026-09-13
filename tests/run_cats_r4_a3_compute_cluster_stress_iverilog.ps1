param(
    [ValidateSet(0, 1)] [int]$Mode = 0,
    [int]$Seed = 7,
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = '',
    [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
$SimulatorFailurePattern =
    '(?im)^\s*(?:(?:FATAL|ERROR):|assertion\s+(?:failed|failure)\b)'
function Test-SimulatorFailure([string]$Text) {
    return [regex]::IsMatch($Text, $script:SimulatorFailurePattern)
}
$ParserSelfChecks = @(
    @{ Text = "WARNING: benign compile warning`nPASS"; Expected = $false },
    @{ Text = "FATAL: fatal output"; Expected = $true },
    @{ Text = "  ERROR: assertion emitted by simulator"; Expected = $true },
    @{ Text = "Assertion failed in scope dut"; Expected = $true }
)
foreach ($check in $ParserSelfChecks) {
    if ((Test-SimulatorFailure $check.Text) -ne $check.Expected) {
        throw "A3 stress simulator-failure parser self-check failed: $($check.Text)"
    }
}
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
        "-Ptb_cats_r4_a3_compute_cluster_stress.SEED=$Seed" `
        -o $Snapshot @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }
    $proc = Start-Process -FilePath (Join-Path $IcarusRoot 'bin\vvp.exe') `
        -ArgumentList @($Snapshot) -WorkingDirectory $ProjectRoot -WindowStyle Hidden `
        -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        $proc.Kill(); $proc.WaitForExit()
        if (Test-Path $Stdout) { Get-Content $Stdout | ForEach-Object { Write-Host $_ } }
        if (Test-Path $Stderr) { Get-Content $Stderr | ForEach-Object { Write-Host $_ } }
        throw "A3 stress timeout mode=$Mode seed=$Seed phase=see-last-marker"
    }
    $runtime = @()
    if (Test-Path $Stdout) { $runtime += Get-Content $Stdout }
    if (Test-Path $Stderr) { $runtime += Get-Content $Stderr }
    $runtime | ForEach-Object { Write-Host $_ }
    if ($proc.ExitCode -ne 0) { throw "vvp failed: $($proc.ExitCode)" }
    $joined = $runtime -join "`n"
    if (Test-SimulatorFailure $joined) {
        throw 'A3 stress emitted a simulator fatal, error, or assertion failure'
    }
    $previousIndex = -1
    foreach ($phase in $Phases) {
        $needle = "PASS A3 STRESS mode=$Mode seed=$Seed phase=$phase"
        $matches = [regex]::Matches($joined, [regex]::Escape($needle))
        if ($matches.Count -ne 1) {
            throw "A3 stress phase marker count mismatch: $phase"
        }
        if ($matches[0].Index -le $previousIndex) {
            throw "A3 stress phase marker order mismatch: $phase"
        }
        $previousIndex = $matches[0].Index
    }
    $requiredEvidence = @(
        "phase=fill_three_slots allocations=16 handoffs=16 releases=16 aborts=0 live=0",
        "phase=independent_weight_v_output_release_backpressure rows=16 row0=1 three_row_batch=1 final_one_row_batch=1 stalls=1 live_counter_clear=1 completed=1",
        "phase=reset_with_pending_score_response pending=1 async_drop=1 stale=0 restart=1",
        "phase=clear_with_old_epoch_qk_response old_tag=0 dropped=1 errors=0 caveat=before_new_same_tag_request",
        "phase=qk_engine_error_report_retire_clear_restart errors=1 s0c7=1 s0c2=0 s1c7=0 other=0 retires=1 drained_q=25/25 drained_k=24/24 stalled_req=1 accepted_delayed=1 recovered=1",
        "phase=a2_nonfinite_score_abort errors=1 s0c2=1 s0c7=0 s1c7=0 other=0 code=2 row=0 slot=0 aborts=1",
        "phase=b4_score_token_error errors=1 s0c2=0 s0c7=0 s1c7=1 other=0 source=1 code=7",
        "phase=simultaneous_a_side_and_b4_error errors=2 s0c2=1 s0c7=0 s1c7=1 other=0 sources=0,1",
        "phase=slot_reuse_after_final_release row127=1 final_one_row=1 scores=1928 pv=246784"
    )
    foreach ($evidence in $requiredEvidence) {
        if (-not $joined.Contains($evidence)) { throw "A3 stress evidence missing: $evidence" }
    }
    $summary = "PASS A3 STRESS SUMMARY mode=$Mode seed=$Seed phases=9 qk=1 a2=1 b4=1 simultaneous=2 row127=1 scores=1928 pv=246784 s0=6/6/6/0/0 s1=5/5/5/0/0 s2=5/5/5/0/0"
    if (([regex]::Matches($joined, [regex]::Escape($summary))).Count -ne 1) {
        throw 'A3 stress exact summary marker mismatch'
    }
    Write-Host "[PASS] CATS-R4 A3 stress mode=$Mode seed=$Seed"
} finally {
    if (Test-Path -LiteralPath $OutputRoot) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
