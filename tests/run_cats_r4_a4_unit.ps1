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
$P6Log = Join-Path $OutputRoot 'p6_control.log'
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
    if ($Clusters -eq 2) {
        $P6Runners = @(
            'run_cats_r4_a4_txn_fanout_iverilog.ps1',
            'run_cats_r4_a4_event_join_iverilog.ps1',
            'run_cats_r4_a4_telemetry_iverilog.ps1',
            'run_cats_r4_a4_control_plane_iverilog.ps1'
        )
        foreach ($Runner in $P6Runners) {
            & (Join-Path $PSScriptRoot $Runner) -IcarusRoot $IcarusRoot `
              *>&1 | Tee-Object -FilePath $P6Log -Append
            if ($LASTEXITCODE -ne 0) { throw "A4 P6 control unit failed: $Runner" }
        }
        $P6Text = Get-Content -Raw -LiteralPath $P6Log
        foreach ($Marker in @('PASS A4 TXN FANOUT','PASS A4 EVENT JOIN',
                              'PASS A4 TELEMETRY','PASS A4 CONTROL PLANE')) {
            if (([regex]::Matches($P6Text, $Marker)).Count -ne 1) {
                throw "A4 P6 exact PASS marker mismatch: $Marker"
            }
        }
    }
    Write-Host "PASS CATS-R4 A4 UNIT clusters=$Clusters mode=$Mode seed=$Seed"
} catch {
    throw
}
