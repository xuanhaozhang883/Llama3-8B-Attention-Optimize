param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_accuracy_v3_full_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Metadata = Join-Path $OutputRoot "equal_row_metadata.hex"
$Snapshot = Join-Path $OutputRoot "accuracy_v3_full.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"
$SoftmaxRoot = Join-Path $ProjectRoot "rtl\core\bc\softmax"

try {
    & python (Join-Path $ProjectRoot `
        "python\cats_r4_b2_accuracy_fixed_model.py") `
        --equal-row-metadata-vectors $Metadata
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 equal-row metadata generation failed"
    }

    & $Iverilog -g2012 -s tb_cats_r4_b2_accuracy_v3_full `
        -o $Snapshot `
        (Join-Path $SoftmaxRoot "unsigned_restoring_divider.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_accuracy_exp_fixed.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_positive_add.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_row_reciprocal.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_row_softmax_accuracy.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_weight_stager.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_accuracy_v3_wrapper.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_accuracy_v3_full.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy V3 full-count compile failed"
    }

    & $Vvp $Snapshot "+META=$Metadata"
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy V3 full-count simulation failed"
    }

    Write-Host "[PASS] CATS-R4 B2 Accuracy V3 4096-row count regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
