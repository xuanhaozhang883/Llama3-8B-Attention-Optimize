param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$BuildRoot = Join-Path (Split-Path -Parent $ProjectRoot) `
    "_fpt_v34_stage3a_iverilog"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

$Generator = Join-Path $ProjectRoot `
    "python\generate_v34_pv_o_vectors.py"
$Accuracy = Join-Path $ProjectRoot `
    "python\validate_v34_pv_o_accuracy.py"
$CommittedVectors = Join-Path $ProjectRoot `
    "tests\data\v34_pv_o_vectors.txt"
$GeneratedVectors = Join-Path $BuildRoot "v34_pv_o_vectors.txt"
$Rtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_pv_o_tile_update.sv"
$Testbench = Join-Path $ProjectRoot `
    "tb\tb_v34_flash_pv_o_tile_update.sv"

foreach ($RequiredFile in @(
    $Generator,
    $Accuracy,
    $CommittedVectors,
    $Rtl,
    $Testbench
)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "Missing Stage 3A file: $RequiredFile"
    }
}

foreach ($Tool in @("python", "iverilog", "vvp")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "$Tool was not found on PATH"
    }
}

& python $Generator --output $GeneratedVectors
if ($LASTEXITCODE -ne 0) {
    throw "Stage 3A vector generation failed"
}

$ExpectedHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $CommittedVectors).Hash
$GeneratedHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $GeneratedVectors).Hash
if ($ExpectedHash -ne $GeneratedHash) {
    throw "Generated vectors differ from tests\data\v34_pv_o_vectors.txt"
}

& python $Accuracy
if ($LASTEXITCODE -ne 0) {
    throw "Stage 3A numerical accuracy qualification failed"
}

$Image = Join-Path $BuildRoot "v34_pv_o_tile.vvp"
& iverilog -g2012 -Wall `
    -s tb_v34_flash_pv_o_tile_update `
    -o $Image `
    $Rtl `
    $Testbench
if ($LASTEXITCODE -ne 0) {
    throw "Stage 3A compilation failed"
}

$Marker = Join-Path $BuildRoot "v34_pv_o_tile_pass.txt"
if (Test-Path -LiteralPath $Marker) {
    Remove-Item -Force -LiteralPath $Marker
}
$LocalVectorName = Split-Path -Leaf $GeneratedVectors
$LocalMarkerName = Split-Path -Leaf $Marker

Push-Location $BuildRoot
try {
    $Output = & vvp $Image `
        "+VECTORS=$LocalVectorName" `
        "+MARKER=$LocalMarkerName" 2>&1
    $ExitCode = $LASTEXITCODE
    $Output | Write-Host
} finally {
    Pop-Location
}

if (($ExitCode -ne 0) -or
    (($Output -join "`n") -notmatch "V34_FLASH_PV_O_TILE_TEST: PASS") -or
    (-not (Test-Path -LiteralPath $Marker -PathType Leaf))) {
    throw "Stage 3A simulation failed"
}

Write-Host "============================================================"
Write-Host "[PASS] V3.4 FlashAttention Stage 3A checks passed"
Write-Host "Vectors: 133 bit-exact 4x8 P/V/O update cases"
Write-Host "Accuracy: 4096 complete rows, 32768 context components"
Write-Host "Covers : recurrence, RNE, saturation, protocol, backpressure"
Write-Host "Build  : $BuildRoot"
Write-Host "============================================================"
