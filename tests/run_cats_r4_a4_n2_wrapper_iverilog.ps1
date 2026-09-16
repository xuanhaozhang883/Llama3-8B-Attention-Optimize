param(
    [string]$IcarusRoot='C:\Software\iverilog',
    [int]$TimeoutSeconds=300,
    [string]$OutputRoot
)
$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){
    $OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_n2_wrapper_'+[guid]::NewGuid().ToString('N'))
}else{
    $OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
    if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot must not already exist: $OutputRoot"}
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot=Join-Path $OutputRoot 'n2_wrapper.vvp'
$Stdout=Join-Path $OutputRoot 'stdout.log'
$Stderr=Join-Path $OutputRoot 'stderr.log'
$RunScript=Join-Path $OutputRoot 'run_vvp.ps1'
$ExitStatus=Join-Path $OutputRoot 'vvp_exit_code.txt'
$Marker='PASS A4 N2 WRAPPER real_clusters=2 static_groups=0/1 peer_stall=1 telemetry_live=1 control_error_halt=1 txn_error_halt=1 clear=1'
$FailurePattern='(?im)^\s*(?:(?:FATAL|ERROR):|assertion\s+(?:failed|failure)\b)'
$Sources=@(
 'tb\tb_qk_fp32_mocks.sv','rtl\core\bc\qk\bf16_to_fp32.v',
 'rtl\core\bc\qk\fp32_to_bf16.v','tb\tb_cats_r4_a3_qk_protocol_model.sv',
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
 'rtl\core\bc\integration\cats_r4_a4_txn_fanout.sv',
 'rtl\core\bc\integration\cats_r4_a4_event_join.sv',
 'rtl\core\bc\integration\cats_r4_a4_telemetry.sv',
 'rtl\core\bc\integration\cats_r4_a4_compute_array_n2.sv',
 'tb\tb_cats_r4_a4_n2_wrapper.sv'
) | ForEach-Object {Join-Path $ProjectRoot $_}
try {
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -gno-shared-loop-index `
      -s tb_cats_r4_a4_n2_wrapper -o $Snapshot $Sources
    if($LASTEXITCODE-ne 0){throw "A4 N2 wrapper compile failed: $LASTEXITCODE"}
    $VvpExe=(Join-Path $IcarusRoot 'bin\vvp.exe').Replace("'","''")
    $SnapshotArg=$Snapshot.Replace("'","''")
    $ExitStatusArg=$ExitStatus.Replace("'","''")
    $RunText=@"
`$ErrorActionPreference='Stop'
& '$VvpExe' '$SnapshotArg'
`$Code=`$LASTEXITCODE
[IO.File]::WriteAllText('$ExitStatusArg',`$Code.ToString(),[Text.UTF8Encoding]::new(`$false))
exit `$Code
"@
    [IO.File]::WriteAllText($RunScript,$RunText,[Text.UTF8Encoding]::new($false))
    $proc=Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$RunScript) `
      -WorkingDirectory $ProjectRoot -WindowStyle Hidden `
      -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    if(-not $proc.WaitForExit($TimeoutSeconds*1000)){
        $proc.Kill();$proc.WaitForExit();throw 'A4 N2 wrapper timeout'
    }
    $runtime=@();if(Test-Path $Stdout){$runtime+=Get-Content $Stdout};if(Test-Path $Stderr){$runtime+=Get-Content $Stderr}
    $runtime|ForEach-Object{Write-Host $_};$joined=$runtime-join"`n"
    if(-not(Test-Path -LiteralPath $ExitStatus -PathType Leaf)){throw 'A4 N2 wrapper exit marker missing'}
    $VvpExitCode=[int](Get-Content -Raw -LiteralPath $ExitStatus)
    if($VvpExitCode-ne 0){throw "A4 N2 wrapper vvp failed: $VvpExitCode"}
    if([regex]::IsMatch($joined,$FailurePattern)){throw 'A4 N2 wrapper emitted fatal/error/assertion failure'}
    if(([regex]::Matches($joined,[regex]::Escape($Marker))).Count-ne 1){throw 'A4 N2 wrapper exact PASS marker count mismatch'}
} finally {
    Write-Host "EVIDENCE_DIR=$OutputRoot"
}
