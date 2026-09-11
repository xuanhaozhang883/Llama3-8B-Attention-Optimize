param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_accuracy_interleave_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "accuracy_interleave.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"
$SoftmaxRoot = Join-Path $ProjectRoot "rtl\core\bc\softmax"

try {
    & $Iverilog -g2012 -s tb_cats_r4_row_softmax_accuracy_interleave `
        -o $Snapshot `
        (Join-Path $SoftmaxRoot "unsigned_restoring_divider.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_accuracy_exp_fixed.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_positive_add.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_row_reciprocal.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_row_softmax_accuracy.sv") `
        (Join-Path $ProjectRoot `
            "tb\tb_cats_r4_row_softmax_accuracy_interleave.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy interleave compile failed"
    }
    & $Vvp $Snapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy interleave simulation failed"
    }
    Write-Host "[PASS] CATS-R4 B2 Accuracy three-row interleave Icarus regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
