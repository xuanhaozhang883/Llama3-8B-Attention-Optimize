param(
    [string]$IcarusRoot = "D:\iverilog\iverilog",
    [int[]]$Seeds = @(7, 19, 73, 101, 313)
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b3_pv_controller_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "b3_pv_controller.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"

try {
    & $Iverilog -g2012 -s tb_cats_r4_b3_pv_controller -o $Snapshot `
        (Join-Path $ProjectRoot `
            "rtl\core\bc\pv\cats_r4_b3_pv_controller.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b3_pv_controller.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B3 PV controller compile failed"
    }

    foreach ($Seed in $Seeds) {
        & $Vvp $Snapshot "+SEED=$Seed"
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 B3 PV controller failed seed $Seed"
        }
    }

    Write-Host `
        "[PASS] CATS-R4 B3 PV controller seeds: $($Seeds -join ', ')"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
