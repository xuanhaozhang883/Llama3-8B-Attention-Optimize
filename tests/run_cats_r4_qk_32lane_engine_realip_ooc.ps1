param(
    [string]$VivadoRoot = 'C:\Software\AMD\vivado25.2\2025.2\Vivado',
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
$CreateIpScript = Join-Path $ProjectRoot 'scripts\create_fp32_ips.tcl'
foreach ($Path in @($Vivado, $CreateIpScript)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required path does not exist: $Path"
    }
}

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
$IpRoot = Join-Path $OutputRoot 'ip_gen'
$OocRoot = Join-Path $OutputRoot 'ooc'
New-Item -ItemType Directory -Path $IpRoot, $OocRoot | Out-Null

function Invoke-Vivado {
    param([string]$Root, [string]$TclPath, [string]$LogPath)
    Push-Location $Root
    try {
        # Let Vivado own its log file.  PowerShell 7 can promote Vivado's
        # stderr progress records to NativeCommandError while a Tee pipeline
        # is active even when Vivado completes the Tcl successfully.
        & $Vivado -mode batch -nojournal -log $LogPath -source $TclPath *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado failed: $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

$IpProject = Join-Path $IpRoot 'project'
$CreateIpTcl = Join-Path $IpRoot 'generate.tcl'
$TclStore = Join-Path $VivadoRoot 'data\XilinxTclStore'
$CreateIpTclText = @"
lappend auto_path {$((Join-Path $TclStore 'support\appinit').Replace('\', '/'))}
foreach app_dir [glob -nocomplain -types d {$($TclStore.Replace('\', '/'))/tclapp/*/*}] {
    lappend auto_path `$app_dir
}
create_project fp32_ip_gen {$($IpProject.Replace('\', '/'))} -part xczu15eg-ffvb1156-2-i
source {$($CreateIpScript.Replace('\', '/'))}
puts "FP32_IP_GENERATION_PASS"
close_project
"@
[IO.File]::WriteAllText($CreateIpTcl, $CreateIpTclText, [Text.UTF8Encoding]::new($false))
Invoke-Vivado -Root $IpRoot -TclPath $CreateIpTcl -LogPath (Join-Path $IpRoot 'vivado.log')
if (-not (Select-String -Path (Join-Path $IpRoot 'vivado.log') -Pattern 'FP32_IP_GENERATION_PASS')) {
    throw 'FP32 IP generation PASS marker missing'
}

$IpBase = Join-Path $IpProject 'fp32_ip_gen.srcs\sources_1\ip'
$Xci = 0..2 | ForEach-Object {
    $Name = "floating_point_$_.xci"
    Join-Path (Join-Path $IpBase "floating_point_$($_)") $Name
}
foreach ($Path in $Xci) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Generated XCI missing: $Path"
    }
}

$OocProject = Join-Path $OocRoot 'project'
$Rtl = @(
    'rtl\core\bc\qk\bf16_to_fp32.v',
    'rtl\core\bc\qk\fp32_mul_ip.v',
    'rtl\core\bc\qk\fp32_add_ip.v',
    'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_fp32_service.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_engine.sv'
) | ForEach-Object { (Join-Path $ProjectRoot $_).Replace('\', '/') }
$XciTcl = ($Xci | ForEach-Object { $_.Replace('\', '/') })
$OocTcl = Join-Path $OocRoot 'run.tcl'
$OocText = @"
lappend auto_path {$((Join-Path $TclStore 'support\appinit').Replace('\', '/'))}
foreach app_dir [glob -nocomplain -types d {$($TclStore.Replace('\', '/'))/tclapp/*/*}] {
    lappend auto_path `$app_dir
}
create_project realip_ooc {$($OocProject.Replace('\', '/'))} -part xczu15eg-ffvb1156-2-i
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$($Rtl[0])}
add_files -norecurse {$($Rtl[1])}
add_files -norecurse {$($Rtl[2])}
add_files -norecurse {$($Rtl[3])}
add_files -norecurse {$($Rtl[4])}
add_files -norecurse {$($Rtl[5])}
set_property top cats_r4_qk_32lane_engine [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top cats_r4_qk_32lane_engine -part xczu15eg-ffvb1156-2-i
create_clock -name core_clk -period 6.666 [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
# This is an interface-level OOC smoke budget, not the production shell
# timing contract.  Constrain every synchronous data/control port so
# check_timing and methodology cannot hide unanalysed I/O paths.
set ooc_inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -max 0.100 -clock core_clk `$ooc_inputs
set_input_delay -min 0.000 -clock core_clk `$ooc_inputs
set_output_delay -max 0.100 -clock core_clk [all_outputs]
set_output_delay -min 0.000 -clock core_clk [all_outputs]
report_timing_summary -delay_type max -max_paths 10 -file {$($OocRoot.Replace('\', '/'))/timing_summary.rpt}
check_timing -verbose -file {$($OocRoot.Replace('\', '/'))/check_timing.rpt}
report_methodology -file {$($OocRoot.Replace('\', '/'))/methodology.rpt}
report_utilization -file {$($OocRoot.Replace('\', '/'))/utilization.rpt}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength `$timing_paths] == 0} {
    error "A2_REALIP_OOC: no constrained timing path returned"
}
set worst_slack [get_property SLACK [lindex `$timing_paths 0]]
puts "A2_REALIP_OOC: worst_slack=`$worst_slack"
if {`$worst_slack < 0.0} {
    error "A2_REALIP_OOC: timing failed, worst_slack=`$worst_slack"
}
puts "OOC_ENGINE_REALIP_SYNTH_PASS"
"@
[IO.File]::WriteAllText($OocTcl, $OocText, [Text.UTF8Encoding]::new($false))
Invoke-Vivado -Root $OocRoot -TclPath $OocTcl -LogPath (Join-Path $OocRoot 'vivado.log')
if (-not (Select-String -Path (Join-Path $OocRoot 'vivado.log') -Pattern 'OOC_ENGINE_REALIP_SYNTH_PASS')) {
    throw 'real-IP OOC PASS marker missing'
}
$Timing = Get-Content -Raw (Join-Path $OocRoot 'timing_summary.rpt')
if (-not $Timing.Contains('All user specified timing constraints are met.')) {
    throw 'real-IP OOC timing report does not show a clean timing result'
}
$CheckTiming = Get-Content -Raw (Join-Path $OocRoot 'check_timing.rpt')
if ($CheckTiming -match 'checking\s+\S+\s+\([1-9][0-9]*\)') {
    throw 'real-IP OOC check_timing report contains nonzero findings'
}
$Methodology = Get-Content -Raw (Join-Path $OocRoot 'methodology.rpt')
if (-not $Methodology.Contains('Checks found: 0')) {
    throw 'real-IP OOC methodology report contains findings'
}
$Util = Get-Content -Raw (Join-Path $OocRoot 'utilization.rpt')
if ($Util -match 'floating_point_[012]') {
    throw 'real-IP OOC utilization still reports a blackbox'
}
Write-Host '[PASS] CATS-R4 QK engine real Floating Point IP generation and OOC synthesis'
