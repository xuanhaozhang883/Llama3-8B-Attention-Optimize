param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$BuildRoot = Join-Path (Split-Path -Parent $ProjectRoot) `
    "_fpt_v32_stage2a_iverilog"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

$Generator = Join-Path $ProjectRoot `
    "python\generate_v32_online_row_vectors.py"
$LutGenerator = Join-Path $ProjectRoot "python\generate_exp_lut_q23.py"
$AccuracyCheck = Join-Path $ProjectRoot `
    "python\validate_v32_online_accuracy.py"
$Lut = Join-Path $ProjectRoot "mem\exp_lut_q23.mem"
$CommittedVectors = Join-Path $ProjectRoot `
    "tests\data\v32_online_row_vectors.txt"
$GeneratedLut = Join-Path $BuildRoot "generated_exp_lut_q23.mem"
$GeneratedVectors = Join-Path $BuildRoot "v32_online_row_vectors.txt"
$ExpLutRtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_exp_approx_q23.sv"
$UpdateRtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_online_row_update.sv"
$Testbench = Join-Path $ProjectRoot `
    "tb\tb_v32_flash_online_row_update.sv"

foreach ($RequiredFile in @(
    $Generator,
    $LutGenerator,
    $AccuracyCheck,
    $Lut,
    $CommittedVectors,
    $ExpLutRtl,
    $UpdateRtl,
    $Testbench
)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "Missing Stage 2A file: $RequiredFile"
    }
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python was not found on PATH"
}
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    throw "iverilog was not found on PATH"
}
if (-not (Get-Command vvp -ErrorAction SilentlyContinue)) {
    throw "vvp was not found on PATH"
}

& python $LutGenerator --output $GeneratedLut
if ($LASTEXITCODE -ne 0) {
    throw "Stage 2A Q23 LUT generation failed"
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Lut).Hash -ne
    (Get-FileHash -Algorithm SHA256 -LiteralPath $GeneratedLut).Hash) {
    throw "Generated Q23 LUT differs from mem\exp_lut_q23.mem"
}

& python $Generator --lut $Lut --output $GeneratedVectors
if ($LASTEXITCODE -ne 0) {
    throw "Stage 2A vector generation failed"
}

$ExpectedHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $CommittedVectors).Hash
$GeneratedHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $GeneratedVectors).Hash
if ($ExpectedHash -ne $GeneratedHash) {
    throw "Generated vectors differ from tests\data\v32_online_row_vectors.txt"
}

& python $AccuracyCheck --lut $Lut --rows 4096 --max-relative-error 0.00001
if ($LASTEXITCODE -ne 0) {
    throw "Stage 2A full-row accuracy check failed"
}

Copy-Item -Force -LiteralPath $Lut `
    -Destination (Join-Path $BuildRoot "exp_lut_q23.mem")

$Image = Join-Path $BuildRoot "v32_online_row_update.vvp"
& iverilog -g2012 -Wall `
    -s tb_v32_flash_online_row_update `
    -o $Image `
    $ExpLutRtl `
    $UpdateRtl `
    $Testbench
if ($LASTEXITCODE -ne 0) {
    throw "Stage 2A compilation failed"
}

$Marker = Join-Path $BuildRoot "v32_online_row_update_pass.txt"
if (Test-Path -LiteralPath $Marker) {
    Remove-Item -Force -LiteralPath $Marker
}

Push-Location $BuildRoot
try {
    $Output = & vvp $Image 2>&1
    $ExitCode = $LASTEXITCODE
    $Output | Write-Host
} finally {
    Pop-Location
}

if (($ExitCode -ne 0) -or
    (($Output -join "`n") -notmatch
        "V32_FLASH_ONLINE_ROW_UPDATE_TEST: PASS") -or
    (-not (Test-Path -LiteralPath $Marker -PathType Leaf))) {
    throw "Stage 2A simulation failed"
}

Write-Host "============================================================"
Write-Host "[PASS] V3.2 FlashAttention Stage 2A checks passed"
Write-Host "Vectors: 512 bit-exact cases"
Write-Host "Build  : $BuildRoot"
Write-Host "============================================================"
