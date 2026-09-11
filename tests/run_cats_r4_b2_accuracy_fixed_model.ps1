param(
    [switch]$Full
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

& python (Join-Path $ProjectRoot "tests\test_cats_r4_b2_accuracy_fixed_model.py")
if ($LASTEXITCODE -ne 0) {
    throw "CATS-R4 B2 Accuracy fixed model tests failed"
}

if ($Full) {
    & python (Join-Path $ProjectRoot "python\cats_r4_b2_accuracy_fixed_model.py") --full
    if ($LASTEXITCODE -ne 0) {
        throw "CATS-R4 B2 Accuracy fixed full sweep failed"
    }
}

Write-Host "[PASS] CATS-R4 B2 Accuracy fixed software candidate"
