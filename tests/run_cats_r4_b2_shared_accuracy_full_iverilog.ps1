param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_shared_accuracy_full_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$EqualMetadata = Join-Path $OutputRoot "equal_row_metadata.hex"
$StoredRoot = Join-Path $OutputRoot "stored"
New-Item -ItemType Directory -Force -Path $StoredRoot | Out-Null
$StoredRows = Join-Path $StoredRoot "rows.hex"
$StoredScores = Join-Path $StoredRoot "scores.hex"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"
$SoftmaxRoot = Join-Path $ProjectRoot "rtl\core\bc\softmax"
$Sources = @(
    (Join-Path $SoftmaxRoot "exp_lut.sv"),
    (Join-Path $SoftmaxRoot "unsigned_restoring_divider.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_row_softmax_compatibility.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_b2_compatibility_core_adapter.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_accuracy_exp_fixed.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_fp32_positive_add.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_fp32_row_reciprocal.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_row_softmax_accuracy.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_b2_locking_arbiter.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_b2_weight_stager.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_b2_shared_stager_v3_wrapper.sv"),
    (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_accuracy_v3_full.sv")
)

try {
    & python (Join-Path $ProjectRoot `
        "python\cats_r4_b2_accuracy_fixed_model.py") `
        --equal-row-metadata-vectors $EqualMetadata
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 equal-row metadata generation failed"
    }
    & python (Join-Path $ProjectRoot `
        "python\cats_r4_b2_accuracy_fixed_model.py") `
        --full-row-rtl-vectors $StoredRoot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 stored-row vector generation failed"
    }

    $EqualSnapshot = Join-Path $OutputRoot "shared_accuracy_equal_full.vvp"
    & $Iverilog -g2012 -DCATS_R4_SHARED_INTEGRATION `
        -s tb_cats_r4_b2_accuracy_v3_full -o $EqualSnapshot $Sources
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 shared Accuracy equal-full compile failed"
    }

    Push-Location $ProjectRoot
    try {
        & $Vvp $EqualSnapshot "+META=$EqualMetadata"
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 B2 shared Accuracy equal-full simulation failed"
        }
    } finally {
        Pop-Location
    }

    $StoredSnapshot = Join-Path $OutputRoot "shared_accuracy_stored_full.vvp"
    & $Iverilog -g2012 -DCATS_R4_SHARED_INTEGRATION `
        -DCATS_R4_STORED_VECTOR -s tb_cats_r4_b2_accuracy_v3_full `
        -o $StoredSnapshot $Sources
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 shared Accuracy stored-full compile failed"
    }

    Push-Location $ProjectRoot
    try {
        & $Vvp $StoredSnapshot "+ROWS=$StoredRows" "+SCORES=$StoredScores"
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 B2 shared Accuracy stored-full simulation failed"
        }
    } finally {
        Pop-Location
    }

    Write-Host `
        "[PASS] CATS-R4 B2 shared wrapper Accuracy equal/stored 4096-row regressions"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
