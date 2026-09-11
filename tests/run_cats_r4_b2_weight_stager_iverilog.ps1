param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_weight_stager_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "b2_weight_stager.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"

try {
    & $Iverilog -g2012 -s tb_cats_r4_b2_weight_stager -o $Snapshot `
        (Join-Path $ProjectRoot `
            "rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_weight_stager.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 weight stager compile failed"
    }

    & $Vvp $Snapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 weight stager simulation failed"
    }

    Write-Host "[PASS] CATS-R4 B2 scheme-A weight stager Icarus regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
}
