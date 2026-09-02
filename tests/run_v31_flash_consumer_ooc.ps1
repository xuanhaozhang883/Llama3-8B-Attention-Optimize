param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,
    [string]$LicenseFile = "",
    [string]$BuildRoot = "",
    [string]$ReportRoot = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $WorkspaceRoot = Split-Path (Split-Path $ProjectRoot -Parent) -Parent
    $BuildRoot = Join-Path $WorkspaceRoot "tmp\fpt_v314_flash_consumer_ooc"
}
if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path $ProjectRoot "reports\v31_flash_consumer_ooc_latest"
}
if ([string]::IsNullOrWhiteSpace($LicenseFile)) {
    $LicenseCandidates = @(
        $env:XILINXD_LICENSE_FILE
    )
    $LicenseFile = $LicenseCandidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -First 1
}
$Vivado = Join-Path $VivadoRoot "bin\vivado.bat"
if (-not (Test-Path -LiteralPath $Vivado -PathType Leaf)) {
    throw "Vivado not found: $Vivado"
}
if (-not [string]::IsNullOrWhiteSpace($LicenseFile)) {
    if (-not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
        throw "Vivado license not found: $LicenseFile"
    }
    Write-Host "Using Vivado license: $LicenseFile"
    $env:XILINXD_LICENSE_FILE = $LicenseFile.Replace('\','/')
} else {
    Write-Host "Using Vivado's configured local or floating license."
}
Write-Host "Using short build root: $BuildRoot"
Write-Host "Writing reports to: $ReportRoot"
$env:TCLLIBPATH = (Join-Path $VivadoRoot "data\XilinxTclStore\support\appinit").Replace('\','/')
$env:XILINX_LOCAL_USER_DATA = "no"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null

& $Vivado -mode batch -nojournal -nolog `
    -source (Join-Path $ProjectRoot "scripts\synth_flash_consumer_ooc.tcl") `
    -tclargs $ProjectRoot $BuildRoot $ReportRoot
if ($LASTEXITCODE -ne 0) {
    throw "FlashAttention consumer OOC synthesis failed"
}
Write-Host "[PASS] OOC reports: $ReportRoot"
