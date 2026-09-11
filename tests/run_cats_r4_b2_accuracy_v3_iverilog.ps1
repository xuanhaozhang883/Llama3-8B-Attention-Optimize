param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_accuracy_v3_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"
$SoftmaxRoot = Join-Path $ProjectRoot "rtl\core\bc\softmax"
$CommonSources = @(
    (Join-Path $SoftmaxRoot "unsigned_restoring_divider.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_accuracy_exp_fixed.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_fp32_positive_add.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_fp32_row_reciprocal.sv"),
    (Join-Path $SoftmaxRoot "cats_r4_row_softmax_accuracy.sv")
)

try {
    $CoreSnapshot = Join-Path $OutputRoot "accuracy_core.vvp"
    & $Iverilog -g2012 -s tb_cats_r4_row_softmax_accuracy `
        -o $CoreSnapshot $CommonSources `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_row_softmax_accuracy.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy row core compile failed"
    }
    & $Vvp $CoreSnapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy row core simulation failed"
    }

    $WrapperSnapshot = Join-Path $OutputRoot "accuracy_v3_wrapper.vvp"
    & $Iverilog -g2012 -s tb_cats_r4_b2_accuracy_v3_wrapper `
        -o $WrapperSnapshot $CommonSources `
        (Join-Path $SoftmaxRoot "cats_r4_b2_weight_stager.sv") `
        (Join-Path $SoftmaxRoot "cats_r4_b2_accuracy_v3_wrapper.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_accuracy_v3_wrapper.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy V3 wrapper compile failed"
    }
    & $Vvp $WrapperSnapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy V3 wrapper simulation failed"
    }

    Write-Host "[PASS] CATS-R4 B2 Accuracy row core and V3 wrapper Icarus regression"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
