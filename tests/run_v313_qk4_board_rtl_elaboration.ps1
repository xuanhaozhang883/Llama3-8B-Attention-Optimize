param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,
    [string]$BuildRoot = (Join-Path $env:TEMP "fpt_v313_qk4_board_rtl")
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
                if ($LASTEXITCODE -ne 0) { throw "Failed to map project path" }
                $sourceRoot = "$mappedDrive\"
                break
            }
        }
        if (-not $mappedDrive) { throw "No free temporary drive letter" }
    }
    if (Test-Path -LiteralPath $BuildRoot) {
        Remove-Item -LiteralPath $BuildRoot -Recurse -Force
    }
    $tcl = Join-Path $sourceRoot "scripts\elaborate_qk4_board_rtl_ooc.tcl"
    & $vivadoBat -mode batch -nojournal -nolog -source $tcl -tclargs `
        $sourceRoot $BuildRoot
    if ($LASTEXITCODE -ne 0) {
        throw "QK4 board RTL integration synthesis failed"
    }
    Write-Host "============================================================"
    Write-Host "[PASS] V3.1.3 QK4 board RTL integration synthesis passed"
    Write-Host "Vivado: $VivadoRoot"
    Write-Host "Note  : PS/DDR Block Design is intentionally black-boxed"
    Write-Host "============================================================"
}
finally {
    if ($mappedDrive) { & subst $mappedDrive /D | Out-Null }
}
