param(
    [string]$IcarusRoot = 'D:\iverilog\iverilog',
    [ValidateSet(0,1)] [int]$Mode = 0,
    [uint32]$Seed = 3019898881,
    [int]$TimeoutSeconds = 1800,
    [string]$OutputRoot,
    [switch]$SmokeOnly,
    [switch]$DirectedOnly,
    [switch]$UseRealCWeightMem,
    [ValidateRange(8,256)] [int]$JobCount = 256,
    [ValidateSet(1,2,4)] [int]$Clusters = 1,
    [ValidateRange(0,3)] [int]$ClusterId = 0,
    [string]$PythonExe = 'python.exe'
)
$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){
    $OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_compute_array_'+[guid]::NewGuid().ToString('N'))
}else{
    $OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
    if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot must not already exist: $OutputRoot"}
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot=Join-Path $OutputRoot 'a3_full_protocol.vvp'
$Stdout=Join-Path $OutputRoot 'stdout.log'
$Stderr=Join-Path $OutputRoot 'stderr.log'
$TimeoutDiagnostic=Join-Path $OutputRoot 'timeout_diagnostic.json'
$TimeoutDiagnosticScript=Join-Path $ProjectRoot 'python\cats_r4_a4_timeout_diagnostic.py'
if($SmokeOnly -and $DirectedOnly){throw 'SmokeOnly and DirectedOnly are mutually exclusive'}
$Marker=if($Clusters -ne 1){"PASS A4 CLUSTER INSTANCE MAP clusters=$Clusters cluster_id=$ClusterId jobs=$JobCount"}elseif($SmokeOnly){'PASS A4 N1 QK HANDSHAKE PRELUDE'}elseif($DirectedOnly){'PASS A4 N1 QK COUNTER CLEAR DIRECTED'}elseif($JobCount -ne 256){"PASS A4 N1 FULL PROTOCOL SLICE jobs=$JobCount"}else{'PASS A4 N1 FULL PROTOCOL MODEL rows=4096 causal_scores=264192 weight_writes=524288 qk_macs=33816576 pv_macs=33816576 context_words=524288 releases=4096'}
$Label=if($Clusters -eq 1){'EVIDENCE_LEVEL=A4_N1_PROTOCOL_MODEL_NOT_REAL_IP'}else{'EVIDENCE_LEVEL=A4_CLUSTER_INSTANCE_PROTOCOL_MODEL_NOT_REAL_IP'}
$ServiceLabel=if($UseRealCWeightMem){'C_WEIGHT_SERVICE=REAL_CATS_R4_WEIGHT_SLOT_MEM'}else{'C_WEIGHT_SERVICE=A4_PROTOCOL_MODEL'}
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
 'rtl\core\bc\integration\cats_r4_a4_group_job_adapter.sv',
 'rtl\core\bc\integration\cats_r4_a4_compute_array.sv',
 'rtl\core\cluster\cats_r4_weight_slot_mem.sv',
 'tb\tb_cats_r4_a4_service_model.sv',
 'tb\tb_cats_r4_a4_compute_array.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }
try {
    $ParameterOverrides=@(
      "-Ptb_cats_r4_a4_compute_array.MODE=$Mode",
      "-Ptb_cats_r4_a4_compute_array.SEED=$Seed",
      "-Ptb_cats_r4_a4_compute_array.JOB_COUNT=$JobCount",
      "-Ptb_cats_r4_a4_compute_array.CLUSTERS=$Clusters",
      "-Ptb_cats_r4_a4_compute_array.CLUSTER_ID=$ClusterId"
    )
    if($UseRealCWeightMem){$ParameterOverrides+='-Ptb_cats_r4_a4_compute_array.USE_REAL_C_WEIGHT_MEM=1'}
    if($SmokeOnly){$ParameterOverrides+='-Ptb_cats_r4_a4_compute_array.SMOKE_ONLY=1'}
    if($DirectedOnly){$ParameterOverrides+='-Ptb_cats_r4_a4_compute_array.DIRECTED_ONLY=1'}
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -gno-shared-loop-index `
      -s tb_cats_r4_a4_compute_array @ParameterOverrides -o $Snapshot @Sources
    if($LASTEXITCODE -ne 0){throw "A4 N1 compute array compile failed: $LASTEXITCODE"}
    $VvpExe=Join-Path $IcarusRoot 'bin\vvp.exe'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $proc=Start-Process -FilePath $VvpExe -ArgumentList @($Snapshot) `
      -WorkingDirectory $ProjectRoot -WindowStyle Hidden `
      -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    if(-not $proc.WaitForExit($TimeoutSeconds*1000)){
        $proc.Kill()
        $proc.WaitForExit()
        & $PythonExe $TimeoutDiagnosticScript `
          --stdout $Stdout --stderr $Stderr --output $TimeoutDiagnostic `
          --mode $Mode --seed $Seed --clusters $Clusters `
          --cluster-id $ClusterId --job-count $JobCount `
          --timeout-seconds $TimeoutSeconds
        if($LASTEXITCODE -ne 0){throw "A4 timeout diagnostic generation failed: $LASTEXITCODE"}
        throw "A4 N1 compute array timeout mode=$Mode seed=$Seed diagnostic=$TimeoutDiagnostic"
    }
    $timer.Stop()
    $runtime=@();if(Test-Path $Stdout){$runtime+=Get-Content $Stdout};if(Test-Path $Stderr){$runtime+=Get-Content $Stderr}
    $runtime | ForEach-Object {Write-Host $_};$joined=$runtime -join "`n"
    $VvpExitCode=$proc.ExitCode
    if($VvpExitCode -ne 0){throw "A4 N1 compute array vvp failed: $VvpExitCode"}
    if([regex]::IsMatch($joined,$FailurePattern)){throw 'A4 N1 compute array emitted simulator fatal, error, or assertion failure'}
    if(([regex]::Matches($joined,[regex]::Escape($Marker))).Count -ne 1){throw 'A4 N1 compute array exact PASS marker count mismatch'}
    if(([regex]::Matches($joined,[regex]::Escape($Label))).Count -ne 1){throw 'A4 N1 compute array exact evidence label count mismatch'}
    if(([regex]::Matches($joined,[regex]::Escape($ServiceLabel))).Count -ne 1){throw 'A4 N1 compute array exact C service label count mismatch'}
    Write-Host ("RUNTIME_SECONDS={0:F3}" -f $timer.Elapsed.TotalSeconds)
} finally {
    Write-Host "EVIDENCE_DIR=$OutputRoot"
}
