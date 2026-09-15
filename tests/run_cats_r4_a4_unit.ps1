param(
    [ValidateSet(1,2,4)] [int]$Clusters = 2,
    [ValidateSet(0,1)] [int]$Mode = 0,
    [uint32]$Seed = 3019898881,
    [int]$TimeoutSeconds = 300,
    [Parameter(Mandatory = $true)] [string]$OutputRoot,
    [string]$IcarusRoot = 'C:\Software\iverilog'
)
$ErrorActionPreference = 'Stop'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot must not exist: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Log = Join-Path $OutputRoot 'group_job_adapter.log'
try {
    foreach ($ClusterId in 0..($Clusters - 1)) {
        & (Join-Path $PSScriptRoot 'run_cats_r4_a4_group_job_adapter_iverilog.ps1') `
          -IcarusRoot $IcarusRoot -Clusters $Clusters -ClusterId $ClusterId `
          *>&1 | Tee-Object -FilePath $Log -Append
        if ($LASTEXITCODE -ne 0) { throw "A4 group adapter unit failed: $LASTEXITCODE" }
    }
    $Text = Get-Content -Raw -LiteralPath $Log
    if (([regex]::Matches($Text, 'PASS A4 GROUP JOB ADAPTER')).Count -ne $Clusters) {
        throw 'A4 unit exact PASS marker mismatch'
    }
    Write-Host "PASS CATS-R4 A4 UNIT clusters=$Clusters mode=$Mode seed=$Seed"
} catch {
    throw
}
