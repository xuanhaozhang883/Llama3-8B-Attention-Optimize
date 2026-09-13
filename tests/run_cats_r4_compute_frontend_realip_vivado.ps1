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
New-Item -ItemType Directory -Path $IpRoot, $XsimRoot, $OocRoot | Out-Null

# Vivado 2025.2 can fail in generated-IP flows when its project/source path
# contains non-ASCII characters. Mirror only the declared A sources into an
# isolated ASCII temporary tree; retained evidence is copied to OutputRoot.
$VivadoWorkRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('a_frontend_vivado_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$VivadoSourceRoot = Join-Path $VivadoWorkRoot 'src'
$OocWorkResults = Join-Path $VivadoWorkRoot 'ooc_results'
New-Item -ItemType Directory -Path $VivadoSourceRoot, $OocWorkResults | Out-Null

$SourceFiles = @(
    'scripts\create_fp32_ips.tcl',
    'rtl\core\bc\qk\bf16_to_fp32.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\qk\fp32_mul_ip.v',
    'rtl\core\bc\qk\fp32_add_ip.v',
    'rtl\core\bc\qk\cats_r4_qk_score_formatter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_assembler.sv',
    'rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv',
    'rtl\core\bc\qk\cats_r4_qk_slot_lifecycle.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_handoff_wrapper.sv',
    'rtl\core\bc\qk\cats_r4_qk_a2_row_pipeline.sv',
    'rtl\core\bc\qk\cats_r4_qk_q_slab_client.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_fp32_service.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_engine.sv',
    'rtl\core\cluster\cats_r4_compute_frontend.sv',
    'tb\tb_cats_r4_compute_frontend_e2e.sv'
)
foreach ($RelativePath in $SourceFiles) {
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Source missing: $SourcePath"
    }
    $MirrorPath = Join-Path $VivadoSourceRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $MirrorPath) |
        Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $MirrorPath
}

function Convert-ToTclPath([string]$Path) {
    return $Path.Replace('\', '/')
}

function Invoke-Vivado {
    param([string]$Root, [string]$TclPath, [string]$LogPath)
    # Vivado's user-level Tcl app manifest on this machine contains a stale
    # Active-HDL entry.  Give each isolated batch run a fresh APPDATA tree and
    # temporarily move only that known manifest; restore it in finally.
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
    $SavedErrorActionPreference = $ErrorActionPreference
    $VivadoExitCode = 1
    try {
        # Vivado writes informational Common 17-354 lines to stderr during
        # startup on this installation. Windows PowerShell otherwise promotes
        # the first stderr record to a terminating NativeCommandError and
        # interrupts a healthy batch run before Tcl executes.
        $ErrorActionPreference = 'Continue'
        & $Vivado -mode batch -nojournal -nolog -source $TclPath 2>&1 |
            Tee-Object -FilePath $LogPath
        $VivadoExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $SavedErrorActionPreference
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
    if ($VivadoExitCode -ne 0) {
        throw "Vivado failed with exit code $VivadoExitCode"
    }
}

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
create_project a_frontend_fp32_ip_gen {$(Convert-ToTclPath $IpProject)} -part xczu15eg-ffvb1156-2-i
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source {$(Convert-ToTclPath (Join-Path $VivadoSourceRoot 'scripts\create_fp32_ips.tcl'))}
set ip_runs {}
foreach ip_obj [get_ips floating_point_0 floating_point_1 floating_point_2] {
    set xci_file [get_files -quiet `$ip_obj.xci]
    lappend ip_runs [create_ip_run `$xci_file]
}
launch_runs `$ip_runs -jobs 3
foreach ip_run `$ip_runs {
    wait_on_run `$ip_run
    if {[get_property PROGRESS [get_runs `$ip_run]] ne "100%"} {
        error "IP synthesis did not complete: `$ip_run"
    }
}
puts "CATS_R4_A_FRONTEND_FP32_IP_GENERATION_PASS"
close_project
"@
    [IO.File]::WriteAllText(
        $CreateIpTcl, $CreateIpTclText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $IpRunRoot -TclPath $CreateIpTcl -LogPath $CreateIpLog
    Copy-Item -LiteralPath $CreateIpTcl `
        -Destination (Join-Path $IpRoot 'generate.tcl')
    Copy-Item -LiteralPath $CreateIpLog `
        -Destination (Join-Path $IpRoot 'vivado.log')
    if (-not (Select-String -LiteralPath $CreateIpLog `
            -Pattern 'CATS_R4_A_FRONTEND_FP32_IP_GENERATION_PASS')) {
        throw 'FP32 IP generation PASS marker missing'
    }
} else {
    [IO.File]::WriteAllText(
        (Join-Path $IpRoot 'REUSED_IP_PROJECT.txt'),
        "Reused pre-generated Vivado IP project for iterative validation:`r`n$IpProject`r`n",
        [Text.UTF8Encoding]::new($false))
}

$IpBase = Join-Path $IpProject `
    'a_frontend_fp32_ip_gen.srcs\sources_1\ip'
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

$RtlRelative = $SourceFiles | Where-Object {
    ($_ -ne 'scripts\create_fp32_ips.tcl') -and
    ($_ -ne 'tb\tb_cats_r4_compute_frontend_e2e.sv')
}
$Rtl = $RtlRelative | ForEach-Object {
    Convert-ToTclPath (Join-Path $VivadoSourceRoot $_)
}
$RtlTcl = ($Rtl | ForEach-Object { "{$_}" }) -join ' '
$Tb = Convert-ToTclPath (
    Join-Path $VivadoSourceRoot 'tb\tb_cats_r4_compute_frontend_e2e.sv')

if (-not $SkipXsim) {
    $XsimRunRoot = Join-Path $VivadoWorkRoot 'xsim_run'
    $XsimProject = Join-Path $VivadoWorkRoot 'xsim_project'
    New-Item -ItemType Directory -Path $XsimRunRoot | Out-Null
    $XsimTcl = Join-Path $XsimRunRoot 'run.tcl'
    $XsimLog = Join-Path $XsimRunRoot 'vivado.log'
    $XsimText = @"
create_project a_frontend_realip_xsim {$(Convert-ToTclPath $XsimProject)} -part xczu15eg-ffvb1156-2-i
set_property target_simulator XSim [current_project]
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target simulation [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$RtlTcl}
add_files -fileset sim_1 -norecurse {$Tb}
set_property top tb_cats_r4_compute_frontend_e2e [get_filesets sim_1]
set_property generic {CLUSTERS=1 HEAD_DIM=4 TOTAL_JOBS=1 RANDOM_STALL=1 INJECT_NEGATIVE=0 RESET_MIDRUN=0} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
puts "CATS_R4_A_FRONTEND_REALIP_XSIM_PASS"
close_project
"@
    [IO.File]::WriteAllText(
        $XsimTcl, $XsimText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $XsimRunRoot -TclPath $XsimTcl -LogPath $XsimLog
    Copy-Item -LiteralPath $XsimTcl -Destination (Join-Path $XsimRoot 'run.tcl')
    Copy-Item -LiteralPath $XsimLog -Destination (Join-Path $XsimRoot 'vivado.log')
    $XsimTextResult = Get-Content -LiteralPath $XsimLog -Raw
    if (-not $XsimTextResult.Contains(
            'PASS: CATS-R4 frontend end-to-end CLUSTERS=1 jobs=1 rows=16 observed_scores=136 counter_scores=136 aborts=0') -or
        -not $XsimTextResult.Contains('CATS_R4_A_FRONTEND_REALIP_XSIM_PASS')) {
        throw 'frontend real-IP XSim PASS marker missing'
    }
}

if (-not $SkipOoc) {
    $Xdc = Join-Path $OocWorkResults 'cats_r4_compute_frontend_ooc.xdc'
    $XdcText = @"
create_clock -name core_clk -period $ClockPeriodNs [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
set_input_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -clock core_clk -min 0.200 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == OUT}]
# This OOC boundary has no downstream hold requirement to model.  A negative
# output minimum delay would describe an external capture window and creates
# artificial hold failures for fast combinational outputs in an isolated
# frontend.  Keep the min delay explicit at zero until the production shell
# supplies its real interface timing constraint.
set_output_delay -clock core_clk -min 0.000 [get_ports -filter {DIRECTION == OUT}]
"@
    [IO.File]::WriteAllText(
        $Xdc, $XdcText, [Text.UTF8Encoding]::new($false))

    $OocRunRoot = Join-Path $VivadoWorkRoot 'ooc_run'
    $OocProject = Join-Path $VivadoWorkRoot 'ooc_project'
    New-Item -ItemType Directory -Path $OocRunRoot | Out-Null
    $OocTcl = Join-Path $OocRunRoot 'run.tcl'
    $OocLog = Join-Path $OocRunRoot 'vivado.log'
    $OocText = @"
create_project a_frontend_realip_ooc {$(Convert-ToTclPath $OocProject)} -part xczu15eg-ffvb1156-2-i
read_ip {$($XciTcl[0])}
read_ip {$($XciTcl[1])}
read_ip {$($XciTcl[2])}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$RtlTcl}
read_xdc {$(Convert-ToTclPath $Xdc)}
set_property top cats_r4_compute_frontend [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -flatten_hierarchy none -top cats_r4_compute_frontend -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {$(Convert-ToTclPath (Join-Path $OocWorkResults 'cats_r4_compute_frontend_ooc.dcp'))}
report_utilization -hierarchical -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'utilization.rpt'))}
report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'timing_summary.rpt'))}
report_cdc -details -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'cdc.rpt'))}
report_clock_interaction -delay_type min_max -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'clock_interaction.rpt'))}
set check_timing_text [check_timing -verbose -return_string]
set check_timing_file [open {$(Convert-ToTclPath (Join-Path $OocWorkResults 'check_timing.rpt'))} w]
puts `$check_timing_file `$check_timing_text
close `$check_timing_file
report_methodology -file {$(Convert-ToTclPath (Join-Path $OocWorkResults 'methodology.rpt'))}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength `$timing_paths] == 0} {
    error "frontend OOC returned no timing path"
}
set worst_slack [get_property SLACK [lindex `$timing_paths 0]]
puts "CATS_R4_A_FRONTEND_REALIP_OOC_WNS=`$worst_slack"
if {`$worst_slack < 0.0} {
    error "CATS_R4_A_FRONTEND_REALIP_OOC_NEGATIVE_WNS"
}
puts "CATS_R4_A_FRONTEND_REALIP_OOC_PASS"
close_project
"@
    [IO.File]::WriteAllText(
        $OocTcl, $OocText, [Text.UTF8Encoding]::new($false))
    Invoke-Vivado -Root $OocRunRoot -TclPath $OocTcl -LogPath $OocLog
    Copy-Item -LiteralPath $OocTcl -Destination (Join-Path $OocRoot 'run.tcl')
    Copy-Item -LiteralPath $OocLog -Destination (Join-Path $OocRoot 'vivado.log')
    foreach ($Name in @(
            'cats_r4_compute_frontend_ooc.xdc',
            'cats_r4_compute_frontend_ooc.dcp',
            'utilization.rpt',
            'timing_summary.rpt',
            'cdc.rpt',
            'clock_interaction.rpt',
            'check_timing.rpt',
            'methodology.rpt')) {
        Copy-Item -LiteralPath (Join-Path $OocWorkResults $Name) `
            -Destination (Join-Path $OocRoot $Name)
    }
    $OocTextResult = Get-Content -LiteralPath $OocLog -Raw
    if (-not $OocTextResult.Contains('CATS_R4_A_FRONTEND_REALIP_OOC_PASS')) {
        throw 'frontend real-IP OOC PASS marker missing'
    }
    $TimingText = Get-Content -LiteralPath `
        (Join-Path $OocRoot 'timing_summary.rpt') -Raw
    if (-not $TimingText.Contains('Setup :            0  Failing Endpoints')) {
        throw 'frontend OOC setup timing has failing endpoints'
    }
    if (-not $TimingText.Contains('Hold  :            0  Failing Endpoints')) {
        throw 'frontend OOC hold timing has failing endpoints'
    }
}

if ($SkipXsim) {
    Write-Host '[PASS] CATS-R4 A frontend real-IP 150 MHz OOC/timing/CDC'
} elseif ($SkipOoc) {
    Write-Host '[PASS] CATS-R4 A frontend real-IP XSim'
} else {
    Write-Host '[PASS] CATS-R4 A frontend real-IP XSim and 150 MHz OOC/timing/CDC'
}
