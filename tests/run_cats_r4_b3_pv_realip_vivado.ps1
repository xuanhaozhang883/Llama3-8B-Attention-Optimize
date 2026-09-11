param(
    [string]$VivadoRoot = 'E:\vivado_25_2\2025.2\Vivado',
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,
    [double]$ClockPeriodNs = 6.666,
    [switch]$SkipXsim,
    [switch]$SkipOoc,
    [string]$ExistingIpProject
)

$ErrorActionPreference = 'Stop'
if ($SkipXsim -and $SkipOoc) {
    throw 'SkipXsim and SkipOoc cannot both be selected'
}
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
$CreateIpScript = Join-Path $ProjectRoot 'scripts\create_fp32_ips.tcl'
$UserVivadoManifest = Join-Path $env:APPDATA `
    'Xilinx\Vivado\tclapp\manifest.tcl'
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
$XsimRoot = Join-Path $OutputRoot 'xsim'
$OocRoot = Join-Path $OutputRoot 'ooc'
New-Item -ItemType Directory -Path $IpRoot, $XsimRoot, $OocRoot |
    Out-Null
$VivadoWorkRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("b3v_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $VivadoWorkRoot | Out-Null
$VivadoSourceRoot = Join-Path $VivadoWorkRoot 'src'
$OocWorkResults = Join-Path $VivadoWorkRoot 'ooc_results'
New-Item -ItemType Directory -Path $OocWorkResults | Out-Null
$SourceFiles = @(
    'scripts\create_fp32_ips.tcl',
    'rtl\core\bc\qk\fp32_mul_ip.v',
    'rtl\core\bc\qk\fp32_add_ip.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv',
    'tb\tb_cats_r4_b3_pv_32lane.sv'
)
foreach ($RelativePath in $SourceFiles) {
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    $MirrorPath = Join-Path $VivadoSourceRoot $RelativePath
    New-Item -ItemType Directory -Force `
        -Path (Split-Path -Parent $MirrorPath) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $MirrorPath
}
$VivadoCreateIpScript = Join-Path $VivadoSourceRoot `
    'scripts\create_fp32_ips.tcl'

function Convert-ToTclPath([string]$Path) {
    return $Path.Replace('\', '/')
}

function Invoke-Vivado {
    param([string]$Root, [string]$TclPath, [string]$LogPath)
    # Vivado's user-level Tcl app manifest on this machine contains a stale
    # Active-HDL entry.  Give each isolated batch run a fresh APPDATA tree;
    # this neither edits the user's manifest nor lets one batch-generated
    # manifest poison the next phase.
    $SavedAppData = $env:APPDATA
    $BatchAppData = Join-Path $Root '.vivado_appdata'
    New-Item -ItemType Directory -Force -Path $BatchAppData | Out-Null
    $env:APPDATA = $BatchAppData
    $SavedManifest = Join-Path $Root 'user_manifest_before_run.tcl'
    $GeneratedManifest = Join-Path $Root 'user_manifest_generated_run.tcl'
    if (Test-Path -LiteralPath $UserVivadoManifest) {
        $ManifestText = (Get-Content -LiteralPath $UserVivadoManifest `
            -Raw).Trim()
        if ($ManifestText -ne `
            '::tclapp::load_app -namespace {aldec::activehdl} aldec::activehdl') {
            throw "Refusing to move unexpected Vivado manifest: $UserVivadoManifest"
        }
        Move-Item -LiteralPath $UserVivadoManifest -Destination $SavedManifest
    }
    Push-Location $Root
    try {
        & $Vivado -mode batch -nojournal -nolog -source $TclPath 2>&1 |
            Tee-Object -FilePath $LogPath
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $UserVivadoManifest) {
            Move-Item -LiteralPath $UserVivadoManifest `
                -Destination $GeneratedManifest
        }
        if (Test-Path -LiteralPath $SavedManifest) {
            Move-Item -LiteralPath $SavedManifest `
                -Destination $UserVivadoManifest
        }
        $env:APPDATA = $SavedAppData
    }
}

$IpProject = if ($ExistingIpProject) {
    [IO.Path]::GetFullPath($ExistingIpProject)
} else {
    Join-Path $VivadoWorkRoot 'ip_project'
}
if (-not $ExistingIpProject) {
    $CreateIpTcl = Join-Path $IpRoot 'generate.tcl'
    $CreateIpTclText = @"
create_project b3_fp32_ip_gen {$(Convert-ToTclPath $IpProject)} -part xczu15eg-ffvb1156-2-i
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source {$(Convert-ToTclPath $VivadoCreateIpScript)}
set ip_runs {}
foreach ip_obj [get_ips floating_point_0 floating_point_1 floating_point_2] {
    set xci_file [get_files -quiet `$ip_obj.xci]
    if {[llength `$xci_file] != 1} {
        error "Expected one XCI for `$ip_obj, got [llength `$xci_file]"
    }
    lappend ip_runs [create_ip_run `$xci_file]
}
launch_runs `$ip_runs -jobs 3
foreach ip_run `$ip_runs {
    wait_on_run `$ip_run
    if {[get_property PROGRESS [get_runs `$ip_run]] ne "100%"} {
        error "IP synthesis did not complete: `$ip_run"
    }
}
puts "CATS_R4_B3_FP32_IP_GENERATION_PASS"
close_project
"@
    [IO.File]::WriteAllText(
        $CreateIpTcl, $CreateIpTclText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $IpRoot -TclPath $CreateIpTcl `
        -LogPath (Join-Path $IpRoot 'vivado.log')
    if (-not (Select-String -Path (Join-Path $IpRoot 'vivado.log') `
            -Pattern 'CATS_R4_B3_FP32_IP_GENERATION_PASS')) {
        throw 'B3 FP32 IP generation PASS marker missing'
    }
}

$IpBase = Join-Path $IpProject 'b3_fp32_ip_gen.srcs\sources_1\ip'
$Xci = 0..2 | ForEach-Object {
    Join-Path (Join-Path $IpBase "floating_point_$($_)") `
        "floating_point_$($_).xci"
}
foreach ($Path in $Xci) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Generated XCI missing: $Path"
    }
}
$XciTcl = $Xci | ForEach-Object { Convert-ToTclPath $_ }

$Rtl = @(
    'rtl\core\bc\qk\fp32_mul_ip.v',
    'rtl\core\bc\qk\fp32_add_ip.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv'
) | ForEach-Object { Convert-ToTclPath (Join-Path $VivadoSourceRoot $_) }
$Tb = Convert-ToTclPath (
    Join-Path $VivadoSourceRoot 'tb\tb_cats_r4_b3_pv_32lane.sv')

if (-not $SkipXsim) {
    $XsimProject = Join-Path $VivadoWorkRoot 'xsim_project'
    $XsimTcl = Join-Path $XsimRoot 'run.tcl'
    $XsimText = @"
create_project b3_realip_xsim {$(Convert-ToTclPath $XsimProject)} -part xczu15eg-ffvb1156-2-i
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target simulation [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$(($Rtl | ForEach-Object { "{$_}" }) -join ' ')}
add_files -fileset sim_1 -norecurse {$Tb}
set_property top tb_cats_r4_b3_pv_32lane [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
puts "CATS_R4_B3_REALIP_XSIM_PASS"
close_project
"@
    [IO.File]::WriteAllText(
        $XsimTcl, $XsimText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $XsimRoot -TclPath $XsimTcl `
        -LogPath (Join-Path $XsimRoot 'vivado.log')
    $XsimLog = Get-Content -Raw (Join-Path $XsimRoot 'vivado.log')
    if (-not $XsimLog.Contains('PASS B3 32-lane end-to-end') -or
        -not $XsimLog.Contains('CATS_R4_B3_REALIP_XSIM_PASS')) {
        throw 'B3 real-IP XSim PASS marker missing'
    }
}

if (-not $SkipOoc) {
$Xdc = Join-Path $OocWorkResults 'cats_r4_b3_pv_ooc.xdc'
$XdcText = @"
create_clock -name core_clk -period $ClockPeriodNs [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
set_input_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -clock core_clk -min 0.200 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == OUT}]
set_output_delay -clock core_clk -min -0.200 [get_ports -filter {DIRECTION == OUT}]
"@
[IO.File]::WriteAllText($Xdc, $XdcText, [Text.UTF8Encoding]::new($false))

$OocProject = Join-Path $VivadoWorkRoot 'ooc_project'
# Run synthesis itself from the ASCII-only temporary tree. Vivado 2025.2
# writes generated real-time IP stubs beneath the current directory and can
# corrupt its heap when that path contains non-ASCII characters.
$OocRunRoot = Join-Path $VivadoWorkRoot 'ooc_run'
New-Item -ItemType Directory -Path $OocRunRoot | Out-Null
$OocTcl = Join-Path $OocRunRoot 'run.tcl'
$OocLog = Join-Path $OocRunRoot 'vivado.log'
$OocText = @"
create_project b3_realip_ooc {$(Convert-ToTclPath $OocProject)} -part xczu15eg-ffvb1156-2-i
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$(($Rtl | ForEach-Object { "{$_}" }) -join ' ')}
read_xdc {$(Convert-ToTclPath $Xdc)}
set_property top cats_r4_b3_pv_32lane [current_fileset]
update_compile_order -fileset sources_1
# Keep the controller, 32-lane MAC, and normalize service as explicit
# hierarchy so the unit OOC report preserves useful PPA attribution and the
# intended bottom-up integration boundary for B3.
synth_design -mode out_of_context -flatten_hierarchy none -top cats_r4_b3_pv_32lane -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {$(Convert-ToTclPath (Join-Path $OocWorkResults 'cats_r4_b3_pv_32lane_ooc.dcp'))}
report_utilization -hierarchical -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'utilization.rpt'))}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'timing_summary.rpt'))}
report_power -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'power.rpt'))}
report_methodology -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'methodology.rpt'))}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength `$timing_paths] == 0} {
    error "CATS-R4 B3 OOC returned no timing path"
}
set worst_slack [get_property SLACK [lindex `$timing_paths 0]]
puts "CATS_R4_B3_REALIP_OOC_WNS=`$worst_slack"
if {`$worst_slack < 0.0} {
    puts "CATS_R4_B3_REALIP_OOC_FAIL_NEGATIVE_WNS"
} else {
    puts "CATS_R4_B3_REALIP_OOC_PASS"
}
close_project
"@
[IO.File]::WriteAllText(
    $OocTcl, $OocText, [Text.UTF8Encoding]::new($false))
Invoke-Vivado -Root $OocRunRoot -TclPath $OocTcl -LogPath $OocLog
Copy-Item -LiteralPath $OocTcl -Destination (Join-Path $OocRoot 'run.tcl')
Copy-Item -LiteralPath $OocLog -Destination (Join-Path $OocRoot 'vivado.log')
$OocArtifacts = @(
    'cats_r4_b3_pv_ooc.xdc',
    'cats_r4_b3_pv_32lane_ooc.dcp',
    'utilization.rpt',
    'timing_summary.rpt',
    'power.rpt',
    'methodology.rpt'
)
foreach ($Name in $OocArtifacts) {
    Copy-Item -LiteralPath (Join-Path $OocWorkResults $Name) `
        -Destination (Join-Path $OocRoot $Name)
}
if (-not (Select-String -Path $OocLog `
        -Pattern 'CATS_R4_B3_REALIP_OOC_PASS')) {
    throw 'B3 real-IP OOC PASS marker missing'
}
}

if ($SkipXsim) {
    Write-Host '[PASS] CATS-R4 B3 real-IP 150 MHz OOC synthesis'
} elseif ($SkipOoc) {
    Write-Host '[PASS] CATS-R4 B3 real-IP XSim'
} else {
    Write-Host '[PASS] CATS-R4 B3 real-IP XSim and 150 MHz OOC synthesis'
}
