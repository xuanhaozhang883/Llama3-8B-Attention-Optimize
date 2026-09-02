param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,
    [string]$BuildRoot = "",
    [string]$ReportRoot = "",
    [string]$LicenseFile = "",
    [ValidateSet(0, 1, 2, 4, 8)]
    [int]$Lanes = 0
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Vivado = Join-Path $VivadoRoot "bin\vivado.bat"
if (-not (Test-Path -LiteralPath $Vivado -PathType Leaf)) {
    throw "Vivado not found: $Vivado"
}
if (-not [string]::IsNullOrWhiteSpace($LicenseFile)) {
    if (-not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
        throw "Vivado license not found: $LicenseFile"
    }
    $env:XILINXD_LICENSE_FILE = $LicenseFile.Replace('\','/')
}
$env:XILINX_LOCAL_USER_DATA = "no"

function Test-VivadoSafePath([string]$Path) {
    return ($Path.Length -le 72) -and -not ($Path.ToCharArray() | Where-Object { [int]$_ -gt 127 })
}

$VivadoProjectRoot = $ProjectRoot
$MappedDrive = $null
if (-not (Test-VivadoSafePath $ProjectRoot)) {
    foreach ($Letter in @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
        if (-not (Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue)) {
            & subst "${Letter}:" $ProjectRoot
            if ($LASTEXITCODE -eq 0) {
                $MappedDrive = "${Letter}:"
                $VivadoProjectRoot = "${Letter}:\"
                break
            }
        }
    }
    if (-not $MappedDrive) {
        throw "Vivado 2018.3 needs a short ASCII path, but no temporary drive letter could be created."
    }
}

if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $env:TEMP "fpt_v312_qk_multilane_ooc"
}
if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path $VivadoProjectRoot "reports\v312_qk_multilane_ooc"
}
$LaneSet = if ($Lanes -eq 0) { @(1, 2, 4, 8) } else { @($Lanes) }

try {
    foreach ($LaneCount in $LaneSet) {
        $LaneBuild = Join-Path $BuildRoot "lanes$LaneCount"
        $LaneReport = Join-Path $ReportRoot "lanes$LaneCount"
        New-Item -ItemType Directory -Force -Path $LaneBuild | Out-Null
        New-Item -ItemType Directory -Force -Path $LaneReport | Out-Null
        Write-Host "[RUN] QK_LANES=$LaneCount OOC synthesis"
        & $Vivado -mode batch -nojournal -nolog `
            -source (Join-Path $VivadoProjectRoot "scripts\synth_qk_multilane_ooc.tcl") `
            -tclargs $VivadoProjectRoot $LaneBuild $LaneReport $LaneCount
        if ($LASTEXITCODE -ne 0) {
            throw "QK_LANES=$LaneCount OOC synthesis failed"
        }
    }
    Write-Host "[PASS] QK multi-lane OOC synthesis scan completed."
}
finally {
    if ($MappedDrive) {
        & subst $MappedDrive /D
    }
}
