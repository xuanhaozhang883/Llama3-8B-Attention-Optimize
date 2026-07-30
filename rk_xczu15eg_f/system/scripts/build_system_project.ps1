[CmdletBinding()]
param(
    [ValidateSet('ps_dma_loopback', 'ps_attention', 'custom')]
    [string]$Project = 'ps_dma_loopback',

    [ValidateSet('xsa', 'bitstream')]
    [string]$BuildMode = 'xsa',

    [string]$Xpr,
    [string]$OutputDir,
    [string]$VivadoBin,

    [ValidateRange(1, 64)]
    [int]$Jobs = 4,

    [bool]$UpgradeIp = $true,
    [switch]$ResetRuns,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Resolve-VivadoExecutable {
    param([string]$RequestedPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($RequestedPath) {
        $candidates.Add($RequestedPath)
    }
    if ($env:VIVADO_BIN) {
        $candidates.Add($env:VIVADO_BIN)
    }
    $candidates.Add('D:\Vitis\2025.2\Vivado\bin\vivado.bat')
    $candidates.Add('D:\Vitis\2025.2\Vivado\bin\unwrapped\win64.o\vivado.exe')

    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            foreach ($leaf in @('vivado.bat', 'vivado.exe')) {
                $nested = Join-Path $candidate $leaf
                if (Test-Path -LiteralPath $nested -PathType Leaf) {
                    return (Resolve-Path -LiteralPath $nested).Path
                }
            }
        }
    }

    foreach ($commandName in @('vivado.bat', 'vivado.exe', 'vivado')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    throw 'Vivado executable not found. Pass -VivadoBin or set VIVADO_BIN.'
}

$scriptDir = $PSScriptRoot
$systemDir = Split-Path $scriptDir -Parent
$tclScript = Join-Path $scriptDir 'build_system_project.tcl'

if (-not $Xpr) {
    switch ($Project) {
        'ps_dma_loopback' {
            $Xpr = Join-Path $systemDir 'vx\ps_dma_loopback\rk_ps_dma_loopback.xpr'
        }
        'ps_attention' {
            $Xpr = Join-Path $systemDir 'vx\ps_attention\rk_ps_attention_single_gqa.xpr'
        }
        'custom' {
            throw '-Xpr is required when -Project custom is selected.'
        }
    }
}

if (-not (Test-Path -LiteralPath $Xpr -PathType Leaf)) {
    throw "Vivado project does not exist: $Xpr"
}
$resolvedXpr = (Resolve-Path -LiteralPath $Xpr).Path

if (-not $OutputDir) {
    $projectStem = [System.IO.Path]::GetFileNameWithoutExtension($resolvedXpr)
    $OutputDir = Join-Path $systemDir "generated\vivado_build\$projectStem"
}
$absoluteOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
[System.IO.Directory]::CreateDirectory($absoluteOutputDir) | Out-Null

$vivado = Resolve-VivadoExecutable -RequestedPath $VivadoBin
$vivadoLog = Join-Path $absoluteOutputDir 'vivado_console.log'
$vivadoJournal = Join-Path $absoluteOutputDir 'vivado.jou'
$upgradeValue = if ($UpgradeIp) { '1' } else { '0' }
$resetValue = if ($ResetRuns) { '1' } else { '0' }

$vivadoArgs = @(
    '-mode', 'batch',
    '-log', $vivadoLog,
    '-journal', $vivadoJournal,
    '-source', $tclScript,
    '-tclargs',
    '--xpr', $resolvedXpr,
    '--mode', $BuildMode,
    '--out', $absoluteOutputDir,
    '--expected-part', 'xczu15eg-ffvb1156-2-i',
    '--jobs', $Jobs.ToString(),
    '--upgrade-ip', $upgradeValue,
    '--reset-runs', $resetValue
)

Write-Host "Vivado project : $resolvedXpr"
Write-Host "Build mode     : $BuildMode"
Write-Host "Output         : $absoluteOutputDir"
Write-Host 'Simulation     : disabled'

if ($DryRun) {
    Write-Host "Dry run only. Executable: $vivado"
    Write-Host ('Arguments: ' + ($vivadoArgs -join ' '))
    return
}

& $vivado @vivadoArgs
if ($LASTEXITCODE -ne 0) {
    throw "Vivado build failed with exit code $LASTEXITCODE. See $vivadoLog and $absoluteOutputDir\status.json."
}

$statusPath = Join-Path $absoluteOutputDir 'status.json'
if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw "Vivado exited successfully but status.json was not created: $statusPath"
}
$status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
if ($status.status -ne 'SOFTWARE_PASS') {
    throw "Vivado script did not report SOFTWARE_PASS (reported '$($status.status)')."
}

Write-Host "Build completed. XSA: $($status.xsa)"
if ($status.bitstream) {
    Write-Host "Bitstream: $($status.bitstream)"
}
Write-Host 'Board validation remains HARDWARE_PENDING.'
