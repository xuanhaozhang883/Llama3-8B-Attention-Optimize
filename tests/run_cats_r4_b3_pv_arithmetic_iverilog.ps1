param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b3_pv_arithmetic_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "b3_pv_arithmetic.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"

try {
    & $Iverilog -g2012 -s tb_cats_r4_b3_pv_arithmetic -o $Snapshot `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b3_fp32_mocks.sv") `
        (Join-Path $ProjectRoot "rtl\core\bc\qk\fp32_to_bf16.v") `
        (Join-Path $ProjectRoot `
            "rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv") `
        (Join-Path $ProjectRoot `
            "rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b3_pv_arithmetic.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B3 PV arithmetic compile failed"
    }

    & $Vvp $Snapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B3 PV arithmetic simulation failed"
    }

    Write-Host "[PASS] CATS-R4 B3 PV arithmetic Icarus regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
