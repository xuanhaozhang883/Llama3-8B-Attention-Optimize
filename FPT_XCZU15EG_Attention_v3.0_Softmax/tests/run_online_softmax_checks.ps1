$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $ProjectRoot ".Xil"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$SoftmaxSources = @(
    (Join-Path $ProjectRoot "rtl/core/bc/softmax/exp_lut.sv"),
    (Join-Path $ProjectRoot "rtl/core/bc/softmax/unsigned_restoring_divider.sv"),
    (Join-Path $ProjectRoot "rtl/core/bc/softmax/softmax_bf16.sv"),
    (Join-Path $ProjectRoot "rtl/core/bc/backend/softmax_output_buffer.sv"),
    (Join-Path $ProjectRoot "rtl/core/bc/backend/pv_input_loader.sv"),
    (Join-Path $ProjectRoot "rtl/core/bc/backend/softmax_pv_backend.sv")
)

function Invoke-SoftmaxSimulation {
    param(
        [Parameter(Mandatory = $true)][string]$Top,
        [Parameter(Mandatory = $true)][string]$Testbench,
        [Parameter(Mandatory = $true)][string]$OutputName,
        [Parameter(Mandatory = $true)][string]$PassMarker
    )

    $SimulationImage = Join-Path $BuildDir $OutputName
    & iverilog -g2012 -Wall -s $Top -o $SimulationImage @SoftmaxSources `
        (Join-Path $ProjectRoot $Testbench)
    if ($LASTEXITCODE -ne 0) {
        throw "Compilation failed for $Top"
    }

    Push-Location $ProjectRoot
    try {
        $Output = & vvp $SimulationImage 2>&1
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

Invoke-SoftmaxSimulation `
    -Top "tb_softmax_online" `
    -Testbench "tb/tb_softmax_online.sv" `
    -OutputName "tb_softmax_online.vvp" `
    -PassMarker "SOFTMAX_ONLINE_TEST: PASS"

Invoke-SoftmaxSimulation `
    -Top "tb_online_softmax_regression" `
    -Testbench "tb/tb_online_softmax_regression.sv" `
    -OutputName "tb_online_softmax_regression.vvp" `
    -PassMarker "ONLINE_SOFTMAX_REGRESSION: PASS"

Invoke-SoftmaxSimulation `
    -Top "tb_softmax_equivalence_vectors" `
    -Testbench "tb/tb_softmax_equivalence_vectors.sv" `
    -OutputName "tb_softmax_equivalence_vectors.vvp" `
    -PassMarker "EQ_VECTOR_TEST: PASS"

Invoke-SoftmaxSimulation `
    -Top "tb_online_softmax_continuous_rows" `
    -Testbench "tb/tb_online_softmax_continuous_rows.sv" `
    -OutputName "tb_online_softmax_continuous_rows.vvp" `
    -PassMarker "CONTINUOUS_ROWS_TEST: PASS"

Invoke-SoftmaxSimulation `
    -Top "tb_online_softmax_full_backend" `
    -Testbench "tb/tb_online_softmax_full_backend.sv" `
    -OutputName "tb_online_softmax_full_backend.vvp" `
    -PassMarker "FULL_BACKEND_TEST: PASS"

& python (Join-Path $ProjectRoot "python/validate_v26_architecture.py")
if ($LASTEXITCODE -ne 0) {
    throw "v2.6 architecture validation failed"
}

Write-Host "[PASS] Online Softmax checks passed."
