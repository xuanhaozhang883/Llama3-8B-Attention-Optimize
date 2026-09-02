param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,
    [string]$BuildRoot = (Join-Path $env:TEMP "fpt_v313_qk4_system_ooc")
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$vivadoBat = Join-Path $VivadoRoot "bin\vivado.bat"
if (-not (Test-Path -LiteralPath $vivadoBat)) {
    throw "Vivado was not found at: $vivadoBat"
}

$sourceRoot = $projectRoot
$mappedDrive = $null
try {
    if (($projectRoot.Length -gt 70) -or ($projectRoot -match '[^\x00-\x7F]')) {
        foreach ($letter in @('Q:', 'R:', 'S:', 'T:')) {
            if (-not (Test-Path "$letter\")) {
                $mappedDrive = $letter
                & subst $mappedDrive $projectRoot
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to map $projectRoot to $mappedDrive"
                }
                $sourceRoot = "$mappedDrive\"
                break
            }
        }
        if (-not $mappedDrive) {
            throw "No free temporary drive letter was available"
        }
    }

    if (Test-Path -LiteralPath $BuildRoot) {
        Remove-Item -LiteralPath $BuildRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $BuildRoot | Out-Null
    $reportRoot = Join-Path $BuildRoot "reports"
    New-Item -ItemType Directory -Path $reportRoot | Out-Null

    $tcl = Join-Path $sourceRoot "scripts\synth_qk4_flash_system_ooc.tcl"
    & $vivadoBat -mode batch -nojournal -nolog -source $tcl -tclargs `
        $sourceRoot $BuildRoot $reportRoot
    if ($LASTEXITCODE -ne 0) {
        throw "QK4 full FlashAttention system synthesis failed"
    }

    $summary = Join-Path $reportRoot "summary.txt"
    if (-not (Test-Path -LiteralPath $summary)) {
        throw "Vivado completed without the expected summary: $summary"
    }
    Write-Host "============================================================"
    Write-Host "[PASS] V3.1.3 QK4 full FlashAttention system synthesis passed"
    Get-Content -LiteralPath $summary
    Write-Host "Reports: $reportRoot"
    Write-Host "============================================================"
}
finally {
    if ($mappedDrive) {
        & subst $mappedDrive /D | Out-Null
    }
}
