param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_shared_compatibility_full_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Metadata = Join-Path $OutputRoot "compatibility_equal_row_metadata.hex"
$Snapshot = Join-Path $OutputRoot "shared_compatibility_full.vvp"
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"
$SoftmaxRoot = Join-Path $ProjectRoot "rtl\core\bc\softmax"

try {
    & python (Join-Path $ProjectRoot "python\cats_r4_b2_row_model.py") `
        --compat-equal-row-metadata-vectors $Metadata
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Compatibility metadata generation failed"
    }

    & $Iverilog -g2012 `
        -DCATS_R4_SHARED_INTEGRATION `
        -DCATS_R4_COMPATIBILITY_FULL `
        -s tb_cats_r4_b2_accuracy_v3_full `
        -o $Snapshot `
        (Join-Path $SoftmaxRoot "exp_lut.sv") `
        (Join-Path $SoftmaxRoot "unsigned_restoring_divider.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_row_softmax_compatibility.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_compatibility_core_adapter.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_accuracy_exp_fixed.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_positive_add.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_fp32_row_reciprocal.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_row_softmax_accuracy.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_locking_arbiter.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_weight_stager.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_shared_stager_v3_wrapper.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_accuracy_v3_full.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 shared Compatibility full-count compile failed"
    }

    Push-Location $ProjectRoot
    try {
        & $Vvp $Snapshot "+META=$Metadata"
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 B2 shared Compatibility full-count simulation failed"
        }
    } finally {
        Pop-Location
    }

    Write-Host "[PASS] CATS-R4 B2 shared Compatibility 4096-row regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
