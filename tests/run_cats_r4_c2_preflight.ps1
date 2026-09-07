param(
    [Parameter(Mandatory = $true)]
    [string]$BuildRoot,
    [string]$VivadoRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ResolvedBuildRoot = [IO.Path]::GetFullPath($BuildRoot)

if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    throw 'BuildRoot must be a new short ASCII path outside the checkout'
}
if ($ResolvedBuildRoot.StartsWith($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "BuildRoot must be outside the checkout: $ResolvedBuildRoot"
}
if ($ResolvedBuildRoot -match '[^\x00-\x7F]') {
    throw "BuildRoot must contain ASCII characters only: $ResolvedBuildRoot"
}
if (Test-Path -LiteralPath $ResolvedBuildRoot) {
    throw "BuildRoot must not already exist: $ResolvedBuildRoot"
}

$Required = @(
    'docs\CATS_R4_INTERFACE_COMMIT.md',
    'docs\CATS_R4_C1_SYSTEM_CONTRACT.md',
    'scripts\source_manifest.tcl',
    'rtl\core\cluster\cats_r4_qkv_axi_bank_bridge.sv',
    'tests\run_cats_r4_c_contract_only.ps1'
)
foreach ($Relative in $Required) {
    $Path = Join-Path $ProjectRoot $Relative
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required C2 preflight input missing: $Relative"
    }
}

if (-not [string]::IsNullOrWhiteSpace($VivadoRoot)) {
    $Vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
    if (-not (Test-Path -LiteralPath $Vivado -PathType Leaf)) {
        throw "Vivado executable not found: $Vivado"
    }
}

Write-Host '[PASS] C2 build root is new, ASCII-only, and outside the checkout'
Write-Host '[INFO] No production manifest/top/BD/constraints were changed by this preflight'
Write-Host '[INFO] Full-board build remains gated on A READY, B READY, and compute-wrapper READY'
