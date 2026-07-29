param(
    [ValidateSet("project", "sim", "bitstream", "all")]
    [string]$Mode = "all",
    [string]$VivadoBat = $env:VIVADO_BIN
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($VivadoBat)) {
    $VivadoCommand = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($null -eq $VivadoCommand) {
        throw "Set VIVADO_BIN to vivado.bat or add Vivado to PATH."
    }
    $VivadoBat = $VivadoCommand.Source
}
if (-not (Test-Path -LiteralPath $VivadoBat -PathType Leaf)) {
    throw "Vivado launcher not found: $VivadoBat"
}

function Invoke-VivadoTcl {
    param(
        [string]$TclFile,
        [string]$LogFile
    )
    $LogDirectory = Split-Path -Parent $LogFile
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    & $VivadoBat -mode batch -nojournal -nolog -source $TclFile 2>&1 |
        Tee-Object -FilePath $LogFile
    $VivadoExitCode = $LASTEXITCODE
    if ($VivadoExitCode -ne 0) {
        throw "Vivado failed with exit code ${VivadoExitCode}: $TclFile"
    }
}

if ($Mode -in @("project", "all")) {
    Invoke-VivadoTcl `
        (Join-Path $ScriptDir "create_rk_pl_selftest_project.tcl") `
        (Join-Path $ScriptDir "..\reports\00_repo_baseline\project_build.log")
}
if ($Mode -in @("sim", "all")) {
    Invoke-VivadoTcl `
        (Join-Path $ScriptDir "run_rk_pl_selftest_sim.tcl") `
        (Join-Path $ScriptDir "..\reports\10_rk_pl_selftest_sim\build.log")
}
if ($Mode -in @("bitstream", "all")) {
    Invoke-VivadoTcl `
        (Join-Path $ScriptDir "build_rk_pl_selftest_bitstream.tcl") `
        (Join-Path $ScriptDir "..\reports\12_rk_pl_selftest_bitstream\build.log")
}
