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

# Vivado 2025.2 has crashed while synthesizing from a non-ASCII current
# directory on this machine.  All generated projects and synthesis work stay
# under an ASCII-only temporary root; final evidence is copied back afterward.
$VivadoWorkRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('b4v_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$VivadoSourceRoot = Join-Path $VivadoWorkRoot 'src'
$OocWorkResults = Join-Path $VivadoWorkRoot 'ooc_results'
New-Item -ItemType Directory -Path $VivadoSourceRoot, $OocWorkResults |
    Out-Null

$SourceFiles = @(
    'scripts\create_fp32_ips.tcl',
    'mem\exp_lut_q15.mem',
    'rtl\core\bc\qk\fp32_mul_ip.v',
    'rtl\core\bc\qk\fp32_add_ip.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\softmax\exp_lut.sv',
    'rtl\core\bc\softmax\unsigned_restoring_divider.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv',
    'rtl\core\bc\softmax\cats_r4_b2_compatibility_core_adapter.sv',
    'rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_accuracy.sv',
    'rtl\core\bc\softmax\cats_r4_b2_locking_arbiter.sv',
    'rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv',
    'rtl\core\bc\softmax\cats_r4_b2_shared_stager_v3_wrapper.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv',
    'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv',
    'tb\tb_cats_r4_b4_c_weight_model.sv',
    'tb\tb_cats_r4_b4_multicluster.sv'
)
foreach ($RelativePath in $SourceFiles) {
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Required source does not exist: $SourcePath"
    }
    $MirrorPath = Join-Path $VivadoSourceRoot $RelativePath
    New-Item -ItemType Directory -Force `
        -Path (Split-Path -Parent $MirrorPath) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $MirrorPath
}

function Convert-ToTclPath([string]$Path) {
    return $Path.Replace('\', '/')
}

function Invoke-Vivado {
    param([string]$Root, [string]$TclPath, [string]$LogPath)
    $SavedAppData = $env:APPDATA
    $MovedUserManifest = $false
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
        $MovedUserManifest = $true
    }
    Push-Location $Root
    try {
        # Vivado emits the non-fatal Common 17-354 user-cache warning on
        # stderr in the managed workspace.  PowerShell would turn that line
        # into a terminating NativeCommandError under the script-wide Stop
        # policy, before the Tcl flow can run.  Preserve the complete merged
        # log and gate on Vivado's process exit code and explicit Tcl markers.
        $SavedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $Vivado -mode batch -nojournal -nolog -source $TclPath 2>&1 |
                Tee-Object -FilePath $LogPath
            $VivadoExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $SavedErrorActionPreference
        }
        if ($VivadoExitCode -ne 0) {
            throw "Vivado failed with exit code $VivadoExitCode"
        }
    } finally {
        Pop-Location
        try {
            if (Test-Path -LiteralPath $UserVivadoManifest) {
                Move-Item -LiteralPath $UserVivadoManifest `
                    -Destination $GeneratedManifest -Force
            }
            if ($MovedUserManifest -and (Test-Path -LiteralPath $SavedManifest)) {
                # Copy rather than move: Vivado can retain a short-lived read
                # handle on the generated manifest after batch exit.
                Copy-Item -LiteralPath $SavedManifest `
                    -Destination $UserVivadoManifest -Force
            }
        } finally {
            $env:APPDATA = $SavedAppData
        }
    }
}

$VivadoCreateIpScript = Join-Path $VivadoSourceRoot `
    'scripts\create_fp32_ips.tcl'
$IpProject = if ($ExistingIpProject) {
    [IO.Path]::GetFullPath($ExistingIpProject)
} else {
    Join-Path $VivadoWorkRoot 'ip_project'
}
if (-not $ExistingIpProject) {
    $IpRunRoot = Join-Path $VivadoWorkRoot 'ip_run'
    New-Item -ItemType Directory -Path $IpRunRoot | Out-Null
    $CreateIpTcl = Join-Path $IpRunRoot 'generate.tcl'
    $CreateIpLog = Join-Path $IpRunRoot 'vivado.log'
    $CreateIpTclText = @"
create_project b4_fp32_ip_gen {$(Convert-ToTclPath $IpProject)} -part xczu15eg-ffvb1156-2-i
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
puts "CATS_R4_B4_FP32_IP_GENERATION_PASS"
close_project
"@
    [IO.File]::WriteAllText(
        $CreateIpTcl, $CreateIpTclText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $IpRunRoot -TclPath $CreateIpTcl `
        -LogPath $CreateIpLog
    Copy-Item -LiteralPath $CreateIpTcl `
        -Destination (Join-Path $IpRoot 'generate.tcl')
    Copy-Item -LiteralPath $CreateIpLog `
        -Destination (Join-Path $IpRoot 'vivado.log')
    if (-not (Select-String -Path $CreateIpLog `
            -Pattern 'CATS_R4_B4_FP32_IP_GENERATION_PASS')) {
        throw 'B4 FP32 IP generation PASS marker missing'
    }
}

$Xci = if ($ExistingIpProject) {
    0..2 | ForEach-Object {
        $IpName = "floating_point_$($_)"
        $Matches = @(Get-ChildItem -LiteralPath $IpProject -Recurse `
            -Filter ($IpName + '.xci') | Where-Object {
                $_.Directory.Name -eq $IpName
            })
        if ($Matches.Count -ne 1) {
            throw "Expected one $IpName XCI under $IpProject, got $($Matches.Count)"
        }
        $Matches[0].FullName
    }
} else {
    $IpBase = Join-Path $IpProject `
        'b4_fp32_ip_gen.srcs\sources_1\ip'
    0..2 | ForEach-Object {
        Join-Path (Join-Path $IpBase "floating_point_$($_)") `
            "floating_point_$($_).xci"
    }
}
foreach ($Path in $Xci) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Generated XCI missing: $Path"
    }
}
$XciTcl = $Xci | ForEach-Object { Convert-ToTclPath $_ }

$RtlRelative = @(
    'rtl\core\bc\qk\fp32_mul_ip.v',
    'rtl\core\bc\qk\fp32_add_ip.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\softmax\exp_lut.sv',
    'rtl\core\bc\softmax\unsigned_restoring_divider.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv',
    'rtl\core\bc\softmax\cats_r4_b2_compatibility_core_adapter.sv',
    'rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv',
    'rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv',
    'rtl\core\bc\softmax\cats_r4_row_softmax_accuracy.sv',
    'rtl\core\bc\softmax\cats_r4_b2_locking_arbiter.sv',
    'rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv',
    'rtl\core\bc\softmax\cats_r4_b2_shared_stager_v3_wrapper.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv',
    'rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv',
    'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv'
)
$Rtl = $RtlRelative | ForEach-Object {
    Convert-ToTclPath (Join-Path $VivadoSourceRoot $_)
}
$Tb = @(
    'tb\tb_cats_r4_b4_c_weight_model.sv',
    'tb\tb_cats_r4_b4_multicluster.sv'
) | ForEach-Object {
    Convert-ToTclPath (Join-Path $VivadoSourceRoot $_)
}
$Mem = Convert-ToTclPath (
    Join-Path $VivadoSourceRoot 'mem\exp_lut_q15.mem')

if (-not $SkipXsim) {
    $XsimProject = Join-Path $VivadoWorkRoot 'xsim_project'
    $XsimRunRoot = Join-Path $VivadoWorkRoot 'xsim_run'
    New-Item -ItemType Directory -Path $XsimRunRoot | Out-Null
    $XsimTcl = Join-Path $XsimRunRoot 'run.tcl'
    $XsimLogPath = Join-Path $XsimRunRoot 'vivado.log'
    $XsimText = @"
create_project b4_realip_xsim {$(Convert-ToTclPath $XsimProject)} -part xczu15eg-ffvb1156-2-i
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target simulation [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$(($Rtl | ForEach-Object { "{$_}" }) -join ' ')}
add_files -fileset sim_1 -norecurse {$(($Tb | ForEach-Object { "{$_}" }) -join ' ')}
add_files -fileset sim_1 -norecurse {$Mem}
set_property file_type {Memory File} [get_files -all {$Mem}]
set_property top tb_cats_r4_b4_multicluster [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
foreach clusters {1 2 4} {
    foreach mode {0 1} {
        set_property generic "CLUSTERS=`$clusters GLOBAL_HEADS=4 ROWS_PER_HEAD=2 MODE=`$mode SEED=3019898881 EXP_LUT_FILE=$Mem" [get_filesets sim_1]
        launch_simulation -simset sim_1 -mode behavioral
        run all
        close_sim
        puts "CATS_R4_B4_REALIP_XSIM_CONFIG_COMPLETE clusters=`$clusters mode=`$mode"
    }
}
puts "CATS_R4_B4_REALIP_XSIM_COMPLETE"
close_project
"@
    [IO.File]::WriteAllText(
        $XsimTcl, $XsimText, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $VivadoSourceRoot 'mem') `
        -Destination $XsimRunRoot -Recurse
    Invoke-Vivado -Root $XsimRunRoot -TclPath $XsimTcl `
        -LogPath $XsimLogPath
    Copy-Item -LiteralPath $XsimTcl `
        -Destination (Join-Path $XsimRoot 'run.tcl')
    Copy-Item -LiteralPath $XsimLogPath `
        -Destination (Join-Path $XsimRoot 'vivado.log')
    $XsimLog = Get-Content -Raw $XsimLogPath
    $ExpectedAggregatePasses = 6
    $AggregatePasses = ([regex]::Matches(
        $XsimLog, '(?m)^PASS B4 aggregate clusters=')).Count
    $ConfigCompletes = ([regex]::Matches(
        $XsimLog,
        '(?m)^CATS_R4_B4_REALIP_XSIM_CONFIG_COMPLETE')).Count
    $SimulationFatals = ([regex]::Matches(
        $XsimLog, '(?im)^\s*(Fatal:|FATAL:)')).Count
    if ($AggregatePasses -ne $ExpectedAggregatePasses -or
        $ConfigCompletes -ne $ExpectedAggregatePasses -or
        $SimulationFatals -ne 0 -or
        -not $XsimLog.Contains('CATS_R4_B4_REALIP_XSIM_COMPLETE')) {
        throw "B4 real-IP XSim closure failed: aggregate=$AggregatePasses complete=$ConfigCompletes fatals=$SimulationFatals"
    }
}

if (-not $SkipOoc) {
    # Keep OOC input sources independent from the XSim project.  Vivado may
    # regenerate/relocate files below a simulation project while the next
    # project is being created; OOC must never depend on that mutable tree.
    $OocSourceRoot = Join-Path $OocWorkResults 'src'
    foreach ($RelativePath in $SourceFiles) {
        $SourcePath = Join-Path $ProjectRoot $RelativePath
        $OocMirrorPath = Join-Path $OocSourceRoot $RelativePath
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            throw "Required OOC source does not exist: $SourcePath"
        }
        New-Item -ItemType Directory -Force `
            -Path (Split-Path -Parent $OocMirrorPath) | Out-Null
        Copy-Item -LiteralPath $SourcePath -Destination $OocMirrorPath -Force
        if (-not (Test-Path -LiteralPath $OocMirrorPath -PathType Leaf)) {
            throw "OOC source mirror failed: $OocMirrorPath"
        }
    }
    $MissingOocSources = @($SourceFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $OocSourceRoot $_) -PathType Leaf)
    })
    if ($MissingOocSources.Count -ne 0) {
        throw "OOC source audit failed: $($MissingOocSources -join ', ')"
    }
    $OocRtl = $RtlRelative | ForEach-Object {
        Convert-ToTclPath (Join-Path $OocSourceRoot $_)
    }
    $OocMem = Convert-ToTclPath (
        Join-Path $OocSourceRoot 'mem\exp_lut_q15.mem')
    $Xdc = Join-Path $OocWorkResults 'cats_r4_b4_cluster_ooc.xdc'
    $XdcText = @"
create_clock -name core_clk -period $ClockPeriodNs [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
# This is a B-owned contract wrapper, not a placed board top.  Its wide
# ready/valid buses have no package pin locations in OOC.  Timing every one of
# those pins creates tens of thousands of tight setup/hold checks and can make
# Vivado's router exhaust host memory.  Keep the 150 MHz internal clock-to-clock
# paths timed, and explicitly exclude the unconstrained contract I/O from the
# OOC timing graph.
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [get_ports -filter {DIRECTION == OUT}]
"@
    [IO.File]::WriteAllText(
        $Xdc, $XdcText, [Text.UTF8Encoding]::new($false))

    $OocProject = Join-Path $VivadoWorkRoot 'ooc_project'
    $OocRunRoot = Join-Path $VivadoWorkRoot 'ooc_run'
    New-Item -ItemType Directory -Path $OocRunRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $OocSourceRoot 'mem') `
        -Destination $OocRunRoot -Recurse
    $OocTcl = Join-Path $OocRunRoot 'run.tcl'
    $OocLog = Join-Path $OocRunRoot 'vivado.log'
    $OocText = @"
set ooc_project_dir {$(Convert-ToTclPath $OocProject)}
set ooc_project_xpr [file join `$ooc_project_dir b4_realip_ooc.xpr]
if {[catch {create_project b4_realip_ooc `$ooc_project_dir -part xczu15eg-ffvb1156-2-i} create_error]} {
    if {![file exists `$ooc_project_xpr]} {
        error "create_project failed without a project: `$create_error"
    }
    puts "CATS_R4_B4_OOC_CREATE_PROJECT_RECOVERED `$create_error"
    if {[llength [get_projects -quiet b4_realip_ooc]] == 0} {
        open_project `$ooc_project_xpr
    }
}
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
# The Active-HDL tclapp on this machine can make a partially-created project
# mark every add_files entry AutoDisabled.  Read the RTL directly into the
# current fileset so the HDL objects remain enabled even when create_project
# returned that recoverable tclapp error.
set_property source_mgmt_mode None [current_project]
foreach rtl_file [list $(($OocRtl | ForEach-Object { "{$_}" }) -join ' ')] {
    if {[string match "*.sv" `$rtl_file]} {
        read_verilog -sv `$rtl_file
    } else {
        read_verilog `$rtl_file
    }
}
if {[llength [get_files -quiet *exp_lut_q15.mem]] == 0} {
    add_files -norecurse {$OocMem}
    set mem_file [lindex [get_files -quiet *exp_lut_q15.mem] 0]
}
if {[llength [get_files -quiet *exp_lut_q15.mem]] != 0} {
    set_property file_type {Memory File} [get_files -quiet *exp_lut_q15.mem]
}
read_xdc {$(Convert-ToTclPath $Xdc)}
set_property top cats_r4_b4_softmax_pv_cluster [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -flatten_hierarchy none -top cats_r4_b4_softmax_pv_cluster -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {$(Convert-ToTclPath (Join-Path $OocWorkResults 'cats_r4_b4_softmax_pv_cluster_synth.dcp'))}
report_utilization -hierarchical -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'synthesis_utilization.rpt'))}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'synthesis_timing_summary.rpt'))}
set synthesis_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength `$synthesis_paths] == 0} {
    error "CATS-R4 B4 OOC synthesis returned no timing path"
}
set synthesis_worst_slack [get_property SLACK [lindex `$synthesis_paths 0]]
puts "CATS_R4_B4_REALIP_OOC_SYNTH_WNS=`$synthesis_worst_slack"
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force {$(Convert-ToTclPath (Join-Path $OocWorkResults 'cats_r4_b4_softmax_pv_cluster_ooc.dcp'))}
report_utilization -hierarchical -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'utilization.rpt'))}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'timing_summary.rpt'))}
report_timing -delay_type max -max_paths 20 -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'critical_paths.rpt'))}
report_route_status -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'route_status.rpt'))}
report_drc -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'drc.rpt'))}
report_power -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'power.rpt'))}
report_methodology -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'methodology.rpt'))}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength `$timing_paths] == 0} {
    error "CATS-R4 B4 OOC returned no timing path"
}
set worst_slack [get_property SLACK [lindex `$timing_paths 0]]
puts "CATS_R4_B4_REALIP_OOC_WNS=`$worst_slack"
if {`$worst_slack < 0.0} {
    puts "CATS_R4_B4_REALIP_OOC_FAIL_NEGATIVE_WNS"
} else {
    puts "CATS_R4_B4_REALIP_OOC_PASS"
}
close_project
"@
    [IO.File]::WriteAllText(
        $OocTcl, $OocText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $OocRunRoot -TclPath $OocTcl `
        -LogPath $OocLog
    Copy-Item -LiteralPath $OocTcl `
        -Destination (Join-Path $OocRoot 'run.tcl')
    Copy-Item -LiteralPath $OocLog `
        -Destination (Join-Path $OocRoot 'vivado.log')
    $OocArtifacts = @(
        'cats_r4_b4_cluster_ooc.xdc',
        'cats_r4_b4_softmax_pv_cluster_synth.dcp',
        'cats_r4_b4_softmax_pv_cluster_ooc.dcp',
        'synthesis_utilization.rpt',
        'synthesis_timing_summary.rpt',
        'utilization.rpt',
        'timing_summary.rpt',
        'critical_paths.rpt',
        'route_status.rpt',
        'drc.rpt',
        'power.rpt',
        'methodology.rpt'
    )
    foreach ($Name in $OocArtifacts) {
        Copy-Item -LiteralPath (Join-Path $OocWorkResults $Name) `
            -Destination (Join-Path $OocRoot $Name)
    }
    if (-not (Select-String -Path $OocLog `
            -Pattern '(?m)^CATS_R4_B4_REALIP_OOC_PASS\s*$')) {
        throw 'B4 real-IP OOC PASS marker missing'
    }
}

if ($SkipXsim) {
    Write-Host '[PASS] CATS-R4 B4 real-IP 150 MHz OOC implementation'
} elseif ($SkipOoc) {
    Write-Host '[PASS] CATS-R4 B4 real-IP 1/2/4-cluster XSim'
} else {
    Write-Host '[PASS] CATS-R4 B4 real-IP XSim and 150 MHz OOC implementation'
}
