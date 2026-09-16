param(
  [string]$VivadoRoot='C:\Software\AMD\vivado25.2\2025.2\Vivado',
  [Parameter(Mandatory=$true)][string]$OutputRoot,
  [double]$ClockPeriodNs=6.666,
  [int]$VivadoTimeoutSeconds=5400
)
$ErrorActionPreference='Stop'
$Runner=Join-Path $PSScriptRoot 'run_cats_r4_a3_realip_vivado.ps1'
& $Runner -VivadoRoot $VivadoRoot -OutputRoot $OutputRoot `
  -ClockPeriodNs $ClockPeriodNs -SkipXsim -SynthOnly -A4N2 `
  -VivadoTimeoutSeconds $VivadoTimeoutSeconds
if($LASTEXITCODE-ne 0){exit $LASTEXITCODE}
