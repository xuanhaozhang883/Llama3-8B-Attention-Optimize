param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$Xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$Xsim = Join-Path $VivadoRoot "bin\xsim.bat"

foreach ($tool in @($Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Vivado simulator tool not found: $tool"
    }
}

if (Test-Path -LiteralPath $OutputRoot) {
    throw "Output root already exists: $OutputRoot"
}

$ProtocolRoot = Join-Path $OutputRoot "protocol"
$StaticRoot = Join-Path $OutputRoot "static"
New-Item -ItemType Directory -Path $ProtocolRoot, $StaticRoot | Out-Null

$Bridge = Join-Path $ProjectRoot "rtl\core\cluster\cats_r4_qkv_axi_bank_bridge.sv"
$Testbench = Join-Path $ProjectRoot "tb\tb_cats_r4_qkv_axi_bank_bridge.sv"

function Invoke-Checked {
    param(
        [string]$Tool,
        [string[]]$Arguments,
        [string]$Label
    )
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

Push-Location $ProtocolRoot
try {
    Invoke-Checked -Tool $Xvlog -Arguments @(
        "-d", "CATS_R4_PROTOCOL_ONLY", "-sv", $Bridge, $Testbench
    ) -Label "protocol xvlog"
    Invoke-Checked -Tool $Xelab -Arguments @(
        "tb_cats_r4_qkv_axi_bank_bridge", "-O3", "-s", "bridge_protocol_sim"
    ) -Label "protocol xelab"
    Invoke-Checked -Tool $Xsim -Arguments @(
        "bridge_protocol_sim", "-runall"
    ) -Label "protocol xsim"
} finally {
    Pop-Location
}

$ProtocolLog = Get-Content -LiteralPath (Join-Path $ProtocolRoot "xsim.log") -Raw
if (-not $ProtocolLog.Contains("PASS: CATS-R4 AXI/core bank bridge descriptors and counters") -or
    -not $ProtocolLog.Contains("NEGATIVE_GATE_DONE")) {
    throw "Protocol simulation completed without both positive and negative PASS markers"
}

Push-Location $StaticRoot
try {
    Invoke-Checked -Tool $Xvlog -Arguments @(
        "-sv", $Bridge, $Testbench
    ) -Label "default-XPM xvlog"
    Invoke-Checked -Tool $Xelab -Arguments @(
        "tb_cats_r4_qkv_axi_bank_bridge", "-L", "xpm", "-s", "bridge_static_sim"
    ) -Label "default-XPM xelab"
} finally {
    Pop-Location
}

$ElabLog = Get-Content -LiteralPath (Join-Path $StaticRoot "xelab.log") -Raw
if (-not $ElabLog.Contains("Built simulation snapshot bridge_static_sim")) {
    throw "Default-XPM static elaboration did not build the expected snapshot"
}

Write-Host "[PASS] CATS-R4 bridge protocol runtime and default-XPM static elaboration"
