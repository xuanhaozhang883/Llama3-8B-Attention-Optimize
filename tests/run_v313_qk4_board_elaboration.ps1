param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,
    [string]$BuildRoot = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Vivado = Join-Path $VivadoRoot "bin\vivado.bat"
if (-not (Test-Path -LiteralPath $Vivado -PathType Leaf)) {
    throw "Vivado not found: $Vivado"
}
$RequiredPsIp = Join-Path $VivadoRoot "data\ip\xilinx\zynq_ultra_ps_e_v3_3"
if (-not (Test-Path -LiteralPath $RequiredPsIp -PathType Container)) {
    throw ("Full board elaboration requires Zynq UltraScale+ PS IP v3.3. " +
           "Run tests\run_v313_qk4_board_rtl_elaboration.ps1 for the " +
           "Vivado 2018.3-compatible project-owned RTL synthesis, and use " +
           "a Vivado installation with PS v3.3 for BIT/XSA sign-off.")
}
if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $env:TEMP "fpt_v313_qk4_board_elaboration"
}

function Test-VivadoSafePath([string]$Path) {
    return ($Path.Length -le 72) -and -not ($Path.ToCharArray() | Where-Object { [int]$_ -gt 127 })
}

$VivadoProjectRoot = $ProjectRoot
$MappedDrive = $null
$OldBuildRoot = $env:FPT_VIVADO_BUILD_ROOT
$OldQkLanes = $env:FPT_QK_LANES
$OldConfig = $env:FPT_V26_CONFIG

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
        throw "Vivado 2018.3 needs a short ASCII source path, but no drive letter could be mapped."
    }
}

try {
    $env:FPT_VIVADO_BUILD_ROOT = [IO.Path]::GetFullPath($BuildRoot)
    $env:FPT_QK_LANES = "4"
    Remove-Item Env:FPT_V26_CONFIG -ErrorAction SilentlyContinue
    & $Vivado -mode batch -nojournal -nolog `
        -source (Join-Path $VivadoProjectRoot "scripts\check_rtl_elaboration_ipfix.tcl")
    if ($LASTEXITCODE -ne 0) {
        throw "QK4 FlashAttention board RTL elaboration failed"
    }
    Write-Host "[PASS] QK4 FlashAttention board RTL elaboration passed."
}
finally {
    if ($null -eq $OldBuildRoot) { Remove-Item Env:FPT_VIVADO_BUILD_ROOT -ErrorAction SilentlyContinue }
    else { $env:FPT_VIVADO_BUILD_ROOT = $OldBuildRoot }
    if ($null -eq $OldQkLanes) { Remove-Item Env:FPT_QK_LANES -ErrorAction SilentlyContinue }
    else { $env:FPT_QK_LANES = $OldQkLanes }
    if ($null -eq $OldConfig) { Remove-Item Env:FPT_V26_CONFIG -ErrorAction SilentlyContinue }
    else { $env:FPT_V26_CONFIG = $OldConfig }
    if ($MappedDrive) { & subst $MappedDrive /D }
}
