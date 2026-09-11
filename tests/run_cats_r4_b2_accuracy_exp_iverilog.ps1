param(
    [int]$Vectors = 8192,
    [switch]$FullSoftwareSweep
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $ProjectRoot ".Xil\cats_r4_b2"
$VectorFile = Join-Path $BuildRoot "accuracy_exp_vectors.mem"
$Simulation = Join-Path $BuildRoot "accuracy_exp.vvp"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

& python (Join-Path $ProjectRoot "tests\test_cats_r4_b2_accuracy_fixed_model.py")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 Accuracy fixed model tests failed"
}

& python (Join-Path $ProjectRoot "python\cats_r4_b2_accuracy_fixed_model.py") `
    --exp-vectors $VectorFile --vector-count $Vectors
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 Accuracy exp vector generation failed"
}

if ($Vectors -ne 8192) {
    throw "TB currently requires exactly 8192 vectors"
}

& iverilog -g2012 `
    -s tb_cats_r4_accuracy_exp_fixed `
    -o $Simulation `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv") `
    (Join-Path $ProjectRoot "tb\tb_cats_r4_accuracy_exp_fixed.sv")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 Accuracy exp RTL compile failed"
}

Push-Location $ProjectRoot
try {
    & vvp $Simulation
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy exp RTL simulation failed"
    }
} finally {
    Pop-Location
}

if ($FullSoftwareSweep) {
    & python (Join-Path $ProjectRoot "python\cats_r4_b2_accuracy_fixed_model.py") --full
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy fixed full software sweep failed"
    }
}

Write-Host "[PASS] CATS-R4 B2 Accuracy exp bit-exact RTL/model regression"
