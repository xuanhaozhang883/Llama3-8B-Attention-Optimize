param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b3_pv_full_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "b3_pv_full.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"

try {
    & $Iverilog -g2012 -s tb_cats_r4_b3_pv_full_workload -o $Snapshot `
        (Join-Path $ProjectRoot `
            "rtl\core\bc\pv\cats_r4_b3_pv_controller.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b3_pv_full_workload.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B3 full workload compile failed"
    }

    & $Vvp $Snapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B3 full workload simulation failed"
    }

    Write-Host "[PASS] CATS-R4 B3 full workload Icarus regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
