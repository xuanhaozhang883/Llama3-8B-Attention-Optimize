param(
    [ValidateSet(2)] [int]$Clusters = 2,
    [ValidateSet(0,1)] [int]$Mode = 0,
    [uint32]$Seed = 7,
    [int]$TimeoutSeconds = 1800,
    [Parameter(Mandatory=$true)] [string]$OutputRoot,
    [string]$IcarusRoot = 'C:\Software\iverilog'
)
$ErrorActionPreference='Stop'
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot must not exist: $OutputRoot"}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Runner=Join-Path $PSScriptRoot 'run_cats_r4_a4_compute_array_iverilog.ps1'
$Seeds=@([uint32]$Seed,[uint32]($Seed+(12+16*$Mode)))
$Processes=@()
for($ClusterId=0;$ClusterId-lt 2;$ClusterId++){
    $ClusterRoot=Join-Path $OutputRoot ("cluster_$ClusterId")
    $Stdout=Join-Path $OutputRoot ("cluster_${ClusterId}_runner_stdout.log")
    $Stderr=Join-Path $OutputRoot ("cluster_${ClusterId}_runner_stderr.log")
    $RunnerExit=Join-Path $OutputRoot ("cluster_${ClusterId}_runner_exit_code.txt")
    $ChildScript=Join-Path $OutputRoot ("run_cluster_${ClusterId}.ps1")
    $ChildText=@"
`$ErrorActionPreference='Stop'
& '$Runner' -IcarusRoot '$IcarusRoot' -Mode $Mode -Seed $($Seeds[$ClusterId]) `
  -JobCount 128 -Clusters 2 -ClusterId $ClusterId -TimeoutSeconds $TimeoutSeconds `
  -OutputRoot '$ClusterRoot'
`$Code=`$LASTEXITCODE
[IO.File]::WriteAllText('$RunnerExit',`$Code.ToString(),[Text.UTF8Encoding]::new(`$false))
exit `$Code
"@
    [IO.File]::WriteAllText($ChildScript,$ChildText,[Text.UTF8Encoding]::new($false))
    $Args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ChildScript)
    $Proc=Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
      -ArgumentList $Args -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    $Processes+=@{proc=$Proc;id=$ClusterId;stdout=$Stdout;stderr=$Stderr;
                  root=$ClusterRoot;runner_exit=$RunnerExit}
}

$Failed=$false
foreach($Item in $Processes){
    if(-not $Item.proc.WaitForExit($TimeoutSeconds*1000)){
        $Item.proc.Kill();$Item.proc.WaitForExit();$Failed=$true
        Write-Error "A4 full protocol cluster $($Item.id) timeout" -ErrorAction Continue
    }else{
        $Item.proc.WaitForExit();$Item.proc.Refresh()
    }
    foreach($Log in @($Item.stdout,$Item.stderr)){
        if(Test-Path -LiteralPath $Log){Get-Content -LiteralPath $Log|ForEach-Object{Write-Host $_}}
    }
    $RunnerExitCode=if(Test-Path -LiteralPath $Item.runner_exit){
        [int](Get-Content -Raw -LiteralPath $Item.runner_exit)
    }else{$Item.proc.ExitCode}
    if($null-eq $RunnerExitCode -or $RunnerExitCode-ne 0){
        $Failed=$true
        Write-Error "A4 full protocol cluster $($Item.id) failed: $RunnerExitCode" -ErrorAction Continue
    }
    $RuntimeLog=Join-Path $Item.root 'stdout.log'
    if(Test-Path -LiteralPath $RuntimeLog){
        $Text=Get-Content -Raw -LiteralPath $RuntimeLog
        $Marker="PASS A4 CLUSTER INSTANCE MAP clusters=2 cluster_id=$($Item.id) jobs=128"
        if(([regex]::Matches($Text,[regex]::Escape($Marker))).Count-ne 1){
            $Failed=$true
            Write-Error "A4 full protocol cluster $($Item.id) marker mismatch" -ErrorAction Continue
        }
    }else{$Failed=$true}
}
if($Failed){throw 'A4 N2 full protocol slices failed'}

$Aggregate=[ordered]@{
    schema='cats-r4-a4-n2-full-protocol-slices-v1'
    evidence_class='two_real_cluster_slices_not_simultaneous_production_ip'
    mode=$Mode
    seeds=@($Seeds[0],$Seeds[1])
    clusters=2
    groups=8
    jobs=256
    rows=4096
    causal_scores=264192
    qk_macs=33816576
    context_chunks=16384
    context_words=524288
    final_releases=4096
}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'aggregate.json'),
  ($Aggregate|ConvertTo-Json -Depth 4)+"`n",[Text.UTF8Encoding]::new($false))
Write-Host "PASS A4 N2 FULL PROTOCOL SLICES mode=$Mode seeds=$($Seeds[0])/$($Seeds[1]) rows=4096 causal_scores=264192 qk_macs=33816576 context_words=524288 releases=4096"
Write-Host 'EVIDENCE_LEVEL=A4_N2_TWO_REAL_CLUSTER_SLICES_NOT_SIMULTANEOUS_PRODUCTION_IP'
