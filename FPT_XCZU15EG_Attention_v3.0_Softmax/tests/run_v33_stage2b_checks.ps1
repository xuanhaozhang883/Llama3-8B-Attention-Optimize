param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$BuildRoot = Join-Path (Split-Path -Parent $ProjectRoot) `
    "_fpt_v33_stage2b_iverilog"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

$Generator = Join-Path $ProjectRoot `
    "python\generate_v33_online_tile_vectors.py"
$Stage2AGenerator = Join-Path $ProjectRoot `
    "python\generate_v32_online_row_vectors.py"
$Lut = Join-Path $ProjectRoot "mem\exp_lut_q23.mem"
$CommittedVectors = Join-Path $ProjectRoot `
    "tests\data\v33_online_tile_vectors.txt"
$GeneratedVectors = Join-Path $BuildRoot "v33_online_tile_vectors.txt"
$ExpRtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_exp_approx_q23.sv"
$RowRtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_online_row_update.sv"
$TileRtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_online_tile_update.sv"
$AdapterRtl = Join-Path $ProjectRoot `
    "rtl\core\flash\flash_score_fifo_online_tile.sv"
$Testbench = Join-Path $ProjectRoot `
    "tb\tb_v33_flash_score_fifo_online_tile.sv"

foreach ($RequiredFile in @(
    $Generator,
    $Stage2AGenerator,
    $Lut,
    $CommittedVectors,
    $ExpRtl,
    $RowRtl,
    $TileRtl,
    $AdapterRtl,
    $Testbench
)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "Missing Stage 2B file: $RequiredFile"
    }
}

foreach ($Tool in @("python", "iverilog", "vvp")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "$Tool was not found on PATH"
    }
}

& python $Generator --lut $Lut --output $GeneratedVectors
if ($LASTEXITCODE -ne 0) {
    throw "Stage 2B vector generation failed"
}

$ExpectedHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $CommittedVectors).Hash
$GeneratedHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $GeneratedVectors).Hash
if ($ExpectedHash -ne $GeneratedHash) {
    throw "Generated vectors differ from tests\data\v33_online_tile_vectors.txt"
}

Copy-Item -Force -LiteralPath $Lut `
    -Destination (Join-Path $BuildRoot "exp_lut_q23.mem")

$Image = Join-Path $BuildRoot "v33_online_tile.vvp"
& iverilog -g2012 -Wall `
    -s tb_v33_flash_score_fifo_online_tile `
    -o $Image `
    $ExpRtl `
    $RowRtl `
    $TileRtl `
    $AdapterRtl `
    $Testbench
if ($LASTEXITCODE -ne 0) {
    throw "Stage 2B compilation failed"
}

$Marker = Join-Path $BuildRoot "v33_online_tile_pass.txt"
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
    (($Output -join "`n") -notmatch
        "V33_FLASH_SCORE_FIFO_ONLINE_TILE_TEST: PASS") -or
    (-not (Test-Path -LiteralPath $Marker -PathType Leaf))) {
    throw "Stage 2B simulation failed"
}

Write-Host "============================================================"
Write-Host "[PASS] V3.3 FlashAttention Stage 2B checks passed"
Write-Host "Vectors: 112 bit-exact 4x4 tile cases"
Write-Host "Covers : state clear, causal mask, ping-pong, backpressure"
Write-Host "Build  : $BuildRoot"
Write-Host "============================================================"
