param(
    [int]$Vectors = 8192
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $ProjectRoot ".Xil\cats_r4_b2"
$VectorFile = Join-Path $BuildRoot "positive_add_vectors.mem"
$Simulation = Join-Path $BuildRoot "fp32_positive_add.vvp"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

& python (Join-Path $ProjectRoot "python\cats_r4_b2_accuracy_fixed_model.py") `
    --add-vectors $VectorFile --vector-count $Vectors
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 positive FP32 add vector generation failed"
}

if ($Vectors -ne 8192) {
    throw "TB currently requires exactly 8192 vectors"
}

& iverilog -g2012 `
    -s tb_cats_r4_fp32_positive_add `
    -o $Simulation `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv") `
    (Join-Path $ProjectRoot "tb\tb_cats_r4_fp32_positive_add.sv")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 positive FP32 add RTL compile failed"
}

Push-Location $ProjectRoot
try {
    & vvp $Simulation
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 positive FP32 add RTL simulation failed"
    }
} finally {
    Pop-Location
}

Write-Host "[PASS] CATS-R4 B2 positive FP32 add bit-exact RTL/model regression"
