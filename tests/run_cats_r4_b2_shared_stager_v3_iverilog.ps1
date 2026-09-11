param(
    [string]$IcarusRoot = "D:\iverilog\iverilog",
    [int[]]$Seeds = @(7, 19, 73)
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_b2_shared_stager_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
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
    (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_shared_stager_v3_wrapper.sv")
)

try {
    $ArbiterSnapshot = Join-Path $OutputRoot "locking_arbiter.vvp"
    & $Iverilog -g2012 -s tb_cats_r4_b2_locking_arbiter `
        -o $ArbiterSnapshot `
        (Join-Path $SoftmaxRoot "cats_r4_b2_locking_arbiter.sv") `
        (Join-Path $ProjectRoot "tb\tb_cats_r4_b2_locking_arbiter.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 locking arbiter compile failed"
    }
    & $Vvp $ArbiterSnapshot
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 locking arbiter simulation failed"
    }

    $Snapshot = Join-Path $OutputRoot "shared_stager_v3.vvp"
    & $Iverilog -g2012 `
        -s tb_cats_r4_b2_shared_stager_v3_wrapper `
        -o $Snapshot $Sources
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 shared-stager V3 wrapper compile failed"
    }

    foreach ($Seed in $Seeds) {
        & $Vvp $Snapshot "+SEED=$Seed"
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 B2 shared-stager V3 wrapper failed seed $Seed"
        }
    }

    Write-Host `
        "[PASS] CATS-R4 B2 shared-stager V3 wrapper seeds: $($Seeds -join ', ')"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
