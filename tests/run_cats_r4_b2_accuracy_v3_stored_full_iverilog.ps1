param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_accuracy_stored_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot "accuracy_stored_full.vvp"
$Rows = Join-Path $OutputRoot "rows.hex"
$Scores = Join-Path $OutputRoot "scores.hex"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"
$SoftmaxRoot = Join-Path $ProjectRoot "rtl\core\bc\softmax"

try {
    & python (Join-Path $ProjectRoot `
        "python\cats_r4_b2_accuracy_fixed_model.py") `
        --full-row-rtl-vectors $OutputRoot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 stored-row vector generation failed"
    }

    & $Iverilog -g2012 -DCATS_R4_STORED_VECTOR `
        -s tb_cats_r4_b2_accuracy_v3_full -o $Snapshot `
        (Join-Path $SoftmaxRoot "unsigned_restoring_divider.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_accuracy_exp_fixed.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_positive_add.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_row_reciprocal.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_row_softmax_accuracy.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_weight_stager.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_accuracy_v3_wrapper.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_accuracy_v3_full.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy stored-full compile failed"
    }

    & $Vvp $Snapshot "+ROWS=$Rows" "+SCORES=$Scores"
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy stored-full simulation failed"
    }

    Write-Host "[PASS] CATS-R4 B2 Accuracy stored full-row RTL regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
