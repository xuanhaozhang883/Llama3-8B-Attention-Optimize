param(
    [string]$IcarusRoot = 'D:\iverilog\iverilog',
    [ValidateSet(0,1)] [int]$Mode = 0,
    [uint32]$Seed = 3019898881,
    [int]$TimeoutSeconds = 1200
)
$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a3_full_protocol_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot=Join-Path $OutputRoot 'a3_full_protocol.vvp'
$Stdout=Join-Path $OutputRoot 'stdout.log'
$Stderr=Join-Path $OutputRoot 'stderr.log'
$Marker='PASS A3 FULL PROTOCOL MODEL rows=4096 causal_scores=264192 weight_writes=524288 qk_macs=33816576 pv_macs=33816576 context_words=524288 releases=4096'
$Label='EVIDENCE_LEVEL=PROTOCOL_MODEL_NOT_REAL_IP'
$FailurePattern='(?im)^\s*(?:(?:FATAL|ERROR):|assertion\s+(?:failed|failure)\b)'
$Sources=@(
 'tb\tb_qk_fp32_mocks.sv',
 'rtl\core\bc\qk\bf16_to_fp32.v','rtl\core\bc\qk\fp32_to_bf16.v',
 'tb\tb_cats_r4_a3_qk_protocol_model.sv',
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
 'tb\tb_cats_r4_b4_b2_protocol_model.sv',
 'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
 'tb\tb_cats_r4_b4_b3_protocol_model.sv',
 'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv',
 'rtl\core\bc\integration\cats_r4_a3_error_join.sv',
 'rtl\core\bc\integration\cats_r4_a3_compute_cluster.sv',
 'tb\tb_cats_r4_b4_c_weight_model.sv',
 'tb\tb_cats_r4_a3_full_protocol.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }
try {
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -gno-shared-loop-index `
      -s tb_cats_r4_a3_full_protocol `
      "-Ptb_cats_r4_a3_full_protocol.MODE=$Mode" `
      "-Ptb_cats_r4_a3_full_protocol.SEED=$Seed" -o $Snapshot @Sources
    if($LASTEXITCODE -ne 0){throw "A3 full protocol compile failed: $LASTEXITCODE"}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $proc=Start-Process -FilePath (Join-Path $IcarusRoot 'bin\vvp.exe') `
      -ArgumentList @($Snapshot) -WorkingDirectory $ProjectRoot -WindowStyle Hidden `
      -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    if(-not $proc.WaitForExit($TimeoutSeconds*1000)){
        $proc.Kill();$proc.WaitForExit();throw "A3 full protocol timeout mode=$Mode seed=$Seed"
    }
    $timer.Stop()
    $runtime=@();if(Test-Path $Stdout){$runtime+=Get-Content $Stdout};if(Test-Path $Stderr){$runtime+=Get-Content $Stderr}
    $runtime | ForEach-Object {Write-Host $_};$joined=$runtime -join "`n"
    if($proc.ExitCode -ne 0){throw "A3 full protocol vvp failed: $($proc.ExitCode)"}
    if([regex]::IsMatch($joined,$FailurePattern)){throw 'A3 full protocol emitted simulator fatal, error, or assertion failure'}
    if(([regex]::Matches($joined,[regex]::Escape($Marker))).Count -ne 1){throw 'A3 full protocol exact PASS marker count mismatch'}
    if(([regex]::Matches($joined,[regex]::Escape($Label))).Count -ne 1){throw 'A3 full protocol exact evidence label count mismatch'}
    Write-Host ("RUNTIME_SECONDS={0:F3}" -f $timer.Elapsed.TotalSeconds)
} finally {
    if(Test-Path -LiteralPath $OutputRoot){Remove-Item -LiteralPath $OutputRoot -Recurse -Force}
}
