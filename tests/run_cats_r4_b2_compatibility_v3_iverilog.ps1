param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_compatibility_v3_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "b2_compatibility_v3.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"

$Sources = @(
    "rtl\core\bc\softmax\exp_lut.sv",
    "rtl\core\bc\softmax\unsigned_restoring_divider.sv",
    "rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv",
    "rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv",
    "rtl\core\bc\softmax\cats_r4_b2_compatibility_v3_wrapper.sv",
    "tb\tb_cats_r4_b2_compatibility_v3_wrapper.sv"
) | ForEach-Object { Join-Path $ProjectRoot $_ }

try {
    & $Iverilog -g2012 -s tb_cats_r4_b2_compatibility_v3_wrapper `
        -o $Snapshot $Sources
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Compatibility V3 compile failed"
    }

    Push-Location $ProjectRoot
    try {
        & $Vvp $Snapshot
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 B2 Compatibility V3 simulation failed"
        }
    } finally {
        Pop-Location
    }

    Write-Host "[PASS] CATS-R4 B2 Compatibility V3 staged wrapper Icarus regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
}
