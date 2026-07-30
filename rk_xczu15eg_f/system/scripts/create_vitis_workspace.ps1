[CmdletBinding()]
param(
    [ValidateSet('dma_loopback', 'attention_single_gqa')]
    [string]$Profile = 'dma_loopback',

    [string]$Xsa,
    [string]$Workspace,
    [string]$VitisBin = 'D:\Vitis\2025.2\Vitis\bin\vitis.bat',
    [switch]$Recreate
)

$ErrorActionPreference = 'Stop'
$systemDir = Split-Path $PSScriptRoot -Parent
$pythonScript = Join-Path $PSScriptRoot 'create_vitis_workspace.py'

if (-not $Xsa) {
    if ($Profile -eq 'dma_loopback') {
        $Xsa = Join-Path $systemDir `
            'generated\vivado_build\rk_ps_dma_loopback\artifacts\rk_ps_dma_loopback.xsa'
    } else {
        $Xsa = Join-Path $systemDir `
            'generated\vivado_build\rk_ps_attention_single_gqa\artifacts\rk_ps_attention_single_gqa.xsa'
    }
}
if (-not $Workspace) {
    # Vitis 2025.2 creates very deep BSP paths.  Keep the default workspace
    # short enough for Windows tools that still enforce MAX_PATH.  The
    # Attention platform exceeds MAX_PATH under the longer repository-style
    # workspace path while generating translation_table.S.obj.d.
    $shortRoot = 'D:\Vitis\ws'
    $workspaceLeaf = if ($Profile -eq 'dma_loopback') {
        'rkd'
    } else {
        'rka'
    }
    $Workspace = Join-Path $shortRoot $workspaceLeaf
} else {
    $shortRoot = Split-Path ([System.IO.Path]::GetFullPath($Workspace)) -Parent
}

if (-not (Test-Path -LiteralPath $Xsa -PathType Leaf)) {
    throw "XSA does not exist: $Xsa"
}
if (-not (Test-Path -LiteralPath $VitisBin -PathType Leaf)) {
    throw "Vitis executable does not exist: $VitisBin"
}

$env:RK_VITIS_XSA = [System.IO.Path]::GetFullPath($Xsa)
$env:RK_VITIS_WORKSPACE = [System.IO.Path]::GetFullPath($Workspace)
$env:RK_VITIS_PROFILE = $Profile
$env:RK_VITIS_RECREATE = if ($Recreate) { '1' } else { '0' }
$env:RK_VITIS_SAFE_ROOT = [System.IO.Path]::GetFullPath($shortRoot)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
if ($env:JAVA_TOOL_OPTIONS) {
    $env:JAVA_TOOL_OPTIONS += ' -Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8'
} else {
    $env:JAVA_TOOL_OPTIONS = '-Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8'
}
# Vitis 2025.2 reads the Java server's stdout as UTF-8.  On a Chinese Windows
# code page the localized launcher text is otherwise emitted as GBK and the
# Python client fails before it can parse the gRPC port.
& chcp.com 65001 | Out-Null

Write-Host "Profile   : $Profile"
Write-Host "XSA       : $env:RK_VITIS_XSA"
Write-Host "Workspace : $env:RK_VITIS_WORKSPACE"
Write-Host 'Simulation: disabled'

& $VitisBin -s $pythonScript
if ($LASTEXITCODE -ne 0) {
    throw "Vitis workspace build failed with exit code $LASTEXITCODE"
}
$statusPath = Join-Path $env:RK_VITIS_WORKSPACE 'vitis_build_status.json'
if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw "Vitis returned without a status file: $statusPath"
}
$status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
if ($status.status -ne 'SOFTWARE_PASS') {
    throw "Vitis did not report SOFTWARE_PASS: $($status.message)"
}

Write-Host 'Vitis GUI launch command:'
Write-Host "`"$VitisBin`" -w `"$env:RK_VITIS_WORKSPACE`""
