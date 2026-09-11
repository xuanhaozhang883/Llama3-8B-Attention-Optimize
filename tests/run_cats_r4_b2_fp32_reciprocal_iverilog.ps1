param(
    [int]$Vectors = 8192
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $ProjectRoot ".Xil\cats_r4_b2"
$VectorFile = Join-Path $BuildRoot "reciprocal_vectors.mem"
$Simulation = Join-Path $BuildRoot "reciprocal.vvp"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

& python (Join-Path $ProjectRoot "python\cats_r4_b2_accuracy_fixed_model.py") `
    --reciprocal-vectors $VectorFile --vector-count $Vectors
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 FP32 reciprocal vector generation failed"
}

if ($Vectors -ne 8192) {
    throw "TB currently requires exactly 8192 vectors"
}

& iverilog -g2012 `
    -s tb_cats_r4_fp32_row_reciprocal `
    -o $Simulation `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv") `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv") `
    (Join-Path $ProjectRoot "tb\tb_cats_r4_fp32_row_reciprocal.sv")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 FP32 reciprocal RTL compile failed"
}

Push-Location $ProjectRoot
try {
    & vvp $Simulation
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 FP32 reciprocal RTL simulation failed"
    }
} finally {
    Pop-Location
}

Write-Host "[PASS] CATS-R4 B2 FP32 reciprocal bit-exact RTL/model regression"
