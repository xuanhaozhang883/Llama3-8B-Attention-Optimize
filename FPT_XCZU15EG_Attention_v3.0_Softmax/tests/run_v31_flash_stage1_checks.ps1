param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$BuildRoot = Join-Path (Split-Path -Parent $ProjectRoot) `
    "_fpt_v31_stage1_iverilog"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

function Invoke-IcarusSimulation {
    param(
        [Parameter(Mandatory = $true)][string]$Top,
        [Parameter(Mandatory = $true)][string[]]$Sources,
        [Parameter(Mandatory = $true)][string]$ImageName,
        [Parameter(Mandatory = $true)][string]$PassMarker
    )

    $Image = Join-Path $BuildRoot $ImageName
    & iverilog -g2012 -Wall -s $Top -o $Image @Sources
    if ($LASTEXITCODE -ne 0) {
        throw "Compilation failed for $Top"
    }

    Push-Location $BuildRoot
    try {
        $Output = & vvp $Image 2>&1
        $ExitCode = $LASTEXITCODE
        $Output | Write-Host
        if (($ExitCode -ne 0) -or
            (($Output -join "`n") -notmatch [regex]::Escape($PassMarker))) {
            throw "Simulation failed for $Top"
        }
    } finally {
        Pop-Location
    }
}

& python (Join-Path $ProjectRoot "python\validate_v31_stage1_install.py") `
    $ProjectRoot
if ($LASTEXITCODE -ne 0) {
    throw "Stage 1 installation validation failed"
}

$Fifo = Join-Path $ProjectRoot "rtl\core\flash\flash_score_tile_fifo.sv"
$Pipeline = Join-Path $ProjectRoot `
    "rtl\core\bc\integration\qk_softmax_pipeline_top.sv"

Invoke-IcarusSimulation `
    -Top "tb_v31_flash_score_tile_fifo" `
    -Sources @(
        $Fifo,
        (Join-Path $ProjectRoot "tb\tb_v31_flash_score_tile_fifo.sv")
    ) `
    -ImageName "v31_flash_score_fifo.vvp" `
    -PassMarker "V31_FLASH_SCORE_TILE_FIFO_TEST: PASS"

Invoke-IcarusSimulation `
    -Top "tb_v31_qk_softmax_fifo_integration" `
    -Sources @(
        $Fifo,
        $Pipeline,
        (Join-Path $ProjectRoot `
            "tb\tb_v31_qk_softmax_fifo_integration.sv")
    ) `
    -ImageName "v31_qk_softmax_fifo_integration.vvp" `
    -PassMarker "V31_QK_SOFTMAX_FIFO_INTEGRATION_TEST: PASS"

# The FIFO does not change Softmax arithmetic. Re-run every existing numerical
# and full-backend test so the stage cannot hide a baseline regression.
& powershell -ExecutionPolicy Bypass -File `
    (Join-Path $ProjectRoot "tests\run_online_softmax_checks.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Existing Online Softmax regression failed"
}

Write-Host "============================================================"
Write-Host "[PASS] V3.1 FlashAttention Stage 1 checks passed"
Write-Host "Build: $BuildRoot"
Write-Host "============================================================"
