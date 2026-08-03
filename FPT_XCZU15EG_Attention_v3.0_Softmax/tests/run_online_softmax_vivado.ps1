param(
    [string]$VivadoRoot = "D:\Vitis\2025.2\Vivado"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SimulationRoot = Join-Path $ProjectRoot ".Xil\xsim_online"
$Xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$Xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$Xsim = Join-Path $VivadoRoot "bin\xsim.bat"

foreach ($Tool in @($Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "Vivado Simulator tool not found: $Tool"
    }
}

New-Item -ItemType Directory -Force -Path $SimulationRoot | Out-Null
$MemLink = Join-Path $SimulationRoot "mem"
if (-not (Test-Path -LiteralPath $MemLink)) {
    New-Item -ItemType Junction -Path $MemLink `
        -Target (Join-Path $ProjectRoot "mem") | Out-Null
}

$Sources = @(
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\exp_lut.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\softmax\softmax_bf16.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\backend\softmax_output_buffer.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\backend\pv_input_loader.sv"),
    (Join-Path $ProjectRoot "rtl\core\bc\backend\softmax_pv_backend.sv"),
    (Join-Path $ProjectRoot "tb\tb_softmax_online.sv"),
    (Join-Path $ProjectRoot "tb\tb_online_softmax_regression.sv"),
    (Join-Path $ProjectRoot "tb\tb_softmax_equivalence_vectors.sv"),
    (Join-Path $ProjectRoot "tb\tb_online_softmax_continuous_rows.sv"),
    (Join-Path $ProjectRoot "tb\tb_online_softmax_full_backend.sv")
)

function Invoke-XsimTest {
    param(
        [Parameter(Mandatory = $true)][string]$Top,
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][string]$PassMarker
    )

    & $Xelab --nolog $Top -s $Snapshot
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado elaboration failed for $Top"
    }

    $Output = & $Xsim $Snapshot --runall --nolog 2>&1
    $ExitCode = $LASTEXITCODE
    $Output | Write-Host
    if (($ExitCode -ne 0) -or (($Output -join "`n") -notmatch [regex]::Escape($PassMarker))) {
        throw "Vivado simulation failed for $Top"
    }
}

Push-Location $SimulationRoot
try {
    & $Xvlog --sv --nolog @Sources
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado SystemVerilog compilation failed"
    }

    Invoke-XsimTest `
        -Top "tb_softmax_online" `
        -Snapshot "tb_softmax_online_sim" `
        -PassMarker "SOFTMAX_ONLINE_TEST: PASS"

    Invoke-XsimTest `
        -Top "tb_online_softmax_regression" `
        -Snapshot "tb_online_softmax_regression_sim" `
        -PassMarker "ONLINE_SOFTMAX_REGRESSION: PASS"

    Invoke-XsimTest `
        -Top "tb_softmax_equivalence_vectors" `
        -Snapshot "tb_softmax_equivalence_vectors_sim" `
        -PassMarker "EQ_VECTOR_TEST: PASS"

    Invoke-XsimTest `
        -Top "tb_online_softmax_continuous_rows" `
        -Snapshot "tb_online_softmax_continuous_rows_sim" `
        -PassMarker "CONTINUOUS_ROWS_TEST: PASS"

    Invoke-XsimTest `
        -Top "tb_online_softmax_full_backend" `
        -Snapshot "tb_online_softmax_full_backend_sim" `
        -PassMarker "FULL_BACKEND_TEST: PASS"
} finally {
    Pop-Location
}

Write-Host "[PASS] Vivado Online Softmax simulations passed."
