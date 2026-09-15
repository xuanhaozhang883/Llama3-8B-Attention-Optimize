param(
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [ValidateSet(1,2,4)] [int]$Clusters = 2,
    [ValidateRange(0,3)] [int]$ClusterId = 0
)
$ErrorActionPreference = 'Stop'
if ($ClusterId -ge $Clusters) { throw 'ClusterId must be less than Clusters' }
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Build = Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_group_adapter_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Build | Out-Null
try {
    $Vvp = Join-Path $Build 'sim.vvp'
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -Wall `
      -s tb_cats_r4_a4_group_job_adapter -o $Vvp `
      "-Ptb_cats_r4_a4_group_job_adapter.CLUSTERS=$Clusters" `
      "-Ptb_cats_r4_a4_group_job_adapter.CLUSTER_ID=$ClusterId" `
      (Join-Path $Root 'rtl\core\bc\integration\cats_r4_a4_group_job_adapter.sv') `
      (Join-Path $Root 'tb\tb_cats_r4_a4_group_job_adapter.sv')
    if ($LASTEXITCODE -ne 0) { throw "A4 group adapter compile failed: $LASTEXITCODE" }
    $Output = & (Join-Path $IcarusRoot 'bin\vvp.exe') $Vvp 2>&1
    $Output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "A4 group adapter simulation failed: $LASTEXITCODE" }
    $Joined = $Output -join "`n"
    $Marker = "PASS A4 GROUP JOB ADAPTER clusters=$Clusters cluster_id=$ClusterId"
    if (([regex]::Matches($Joined, [regex]::Escape($Marker))).Count -ne 1) {
        throw 'A4 group adapter PASS marker mismatch'
    }
} finally {
    if (Test-Path -LiteralPath $Build) { Remove-Item -LiteralPath $Build -Recurse -Force }
}
