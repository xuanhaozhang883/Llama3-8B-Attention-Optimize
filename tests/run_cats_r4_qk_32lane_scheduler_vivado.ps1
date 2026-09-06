param(
    [string]$VivadoRoot = 'D:\Vitis\2025.2\Vivado',
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Rtl = Join-Path $ProjectRoot 'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv'
$Tb = Join-Path $ProjectRoot 'tb\tb_cats_r4_qk_32lane_scheduler.sv'
$Xvlog = Join-Path $VivadoRoot 'bin\xvlog.bat'
$Xelab = Join-Path $VivadoRoot 'bin\xelab.bat'
$Xsim = Join-Path $VivadoRoot 'bin\xsim.bat'
$Vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
foreach ($Path in @($Rtl, $Tb, $Xvlog, $Xelab, $Xsim, $Vivado)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required path does not exist: $Path" }
}
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot must not already exist: $OutputRoot" }
$XsimRoot = Join-Path $OutputRoot 'xsim'
$OocRoot = Join-Path $OutputRoot 'ooc'
New-Item -ItemType Directory -Path $XsimRoot, $OocRoot | Out-Null
Push-Location $XsimRoot
try {
    & $Xvlog -sv $Rtl $Tb
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $LASTEXITCODE" }
    & $Xelab tb_cats_r4_qk_32lane_scheduler -s qk_sched_sim
    if ($LASTEXITCODE -ne 0) { throw "xelab failed: $LASTEXITCODE" }
    $XsimLog = & $Xsim qk_sched_sim -runall 2>&1 | Tee-Object -FilePath (Join-Path $XsimRoot 'runtime.log')
    if ($LASTEXITCODE -ne 0) { throw "xsim failed: $LASTEXITCODE" }
    if (-not (($XsimLog -join [Environment]::NewLine).Contains('PASS: CATS-R4 R16/32-lane QK scheduler tags, causal mask, stalls, and counters'))) { throw 'XSim PASS marker missing' }
} finally { Pop-Location }
$RtlTcl = $Rtl.Replace('\', '/')
$Tcl = @'
read_verilog -sv {__RTL__}
synth_design -mode out_of_context -top cats_r4_qk_32lane_scheduler -part xczu15eg-ffvb1156-2-i
create_clock -name core_clk -period 6.666 [get_ports clk]
report_timing_summary -delay_type max -max_paths 10 -file timing_summary.rpt
report_utilization -file utilization.rpt
set paths [get_timing_paths -delay_type max -max_paths 1]
puts "OOC_SETUP_WNS=[get_property SLACK [lindex $paths 0]]"
puts "OOC_SYNTH_PASS"
'@
$Tcl = $Tcl.Replace('__RTL__', $RtlTcl)
$TclPath = Join-Path $OocRoot 'run.tcl'
[IO.File]::WriteAllText($TclPath, $Tcl, [Text.UTF8Encoding]::new($false))
Push-Location $OocRoot
try {
    $OocLog = & $Vivado -mode batch -nojournal -nolog -source $TclPath 2>&1 | Tee-Object -FilePath (Join-Path $OocRoot 'vivado.log')
    if ($LASTEXITCODE -ne 0) { throw "Vivado OOC failed: $LASTEXITCODE" }
    if (-not (($OocLog -join [Environment]::NewLine).Contains('OOC_SYNTH_PASS'))) { throw 'OOC PASS marker missing' }
    $Timing = [IO.File]::ReadAllText((Join-Path $OocRoot 'timing_summary.rpt'))
    if (-not $Timing.Contains('Setup :            0  Failing Endpoints')) { throw 'OOC setup timing has failing endpoints' }
} finally { Pop-Location }
Write-Host '[PASS] CATS-R4 R16/32-lane QK scheduler XSim and 150 MHz OOC'
