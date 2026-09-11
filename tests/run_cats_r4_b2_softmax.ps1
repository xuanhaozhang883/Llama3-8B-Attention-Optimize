param(
    [int]$DiagnosticCases = 256
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $ProjectRoot ".Xil\cats_r4_b2"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$Simulation = Join-Path $BuildRoot "row_softmax_compatibility.vvp"
$NumericSimulation = Join-Path $BuildRoot "row_softmax_compatibility_numeric.vvp"

& python (Join-Path $ProjectRoot "tests\test_cats_r4_b2_row_model.py")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 numerical model tests failed"
}

& python (Join-Path $ProjectRoot "python\cats_r4_b2_row_model.py")
if ($LASTEXITCODE -ne 0) {
    throw "B2 recovered official candidate artifact audit failed"
}

& python (Join-Path $ProjectRoot "python\cats_r4_b2_row_model.py") `
    --diagnostic --cases $DiagnosticCases
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 diagnostic model failed"
}

& iverilog -g2012 `
    -s tb_cats_r4_row_softmax_compatibility `
    -o $Simulation `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv") `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv") `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv") `
    (Join-Path $ProjectRoot "tb\tb_cats_r4_row_softmax_compatibility.sv")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 compatibility RTL compile failed"
}

Push-Location $ProjectRoot
try {
    & vvp $Simulation
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 compatibility RTL simulation failed"
    }
} finally {
    Pop-Location
}

& iverilog -g2012 `
    -s tb_cats_r4_row_softmax_compatibility_numeric `
    -o $NumericSimulation `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv") `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv") `
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv") `
    (Join-Path $ProjectRoot "tb\tb_cats_r4_row_softmax_compatibility_numeric.sv")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 compatibility numeric RTL compile failed"
}

Push-Location $ProjectRoot
try {
    & vvp $NumericSimulation
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 compatibility numeric RTL simulation failed"
    }
} finally {
    Pop-Location
}

Write-Host "[PASS] CATS-R4 B2 direct model/RTL diagnostics"
