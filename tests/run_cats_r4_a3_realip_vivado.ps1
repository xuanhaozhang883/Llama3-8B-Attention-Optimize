param(
    [string]$VivadoRoot = 'C:\Software\AMD\vivado25.2\2025.2\Vivado',
    [Parameter(Mandatory = $true)] [string]$OutputRoot,
    [double]$ClockPeriodNs = 6.666,
    [switch]$SkipXsim,
    [switch]$SkipOoc,
    [string]$ExistingIpProject,
    [int]$VivadoTimeoutSeconds = 5400,
    [int[]]$XsimModes = @(0, 1),
    [int[]]$XsimSeeds = @(7, 19, 73, 101)
)
$ErrorActionPreference='Stop'
if($SkipXsim-and$SkipOoc){throw 'SkipXsim and SkipOoc cannot both be selected'}
if($VivadoTimeoutSeconds-lt 60){throw 'VivadoTimeoutSeconds must be at least 60'}
if(-not $SkipXsim){
    if($XsimModes.Count-eq 0-or$XsimSeeds.Count-eq 0){throw 'XsimModes and XsimSeeds must not be empty'}
    foreach($Mode in $XsimModes){if($Mode-ne 0-and$Mode-ne 1){throw "Unsupported XSim mode: $Mode"}}
}
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Vivado=Join-Path $VivadoRoot 'bin\vivado.bat'
$CreateIpScript=Join-Path $ProjectRoot 'scripts\create_fp32_ips.tcl'
$OocFlow=Join-Path $ProjectRoot 'scripts\cats_r4_a3_compute_cluster_ooc.tcl'
foreach($Path in @($Vivado,$CreateIpScript,$OocFlow)){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Required path does not exist: $Path"}}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot must not already exist: $OutputRoot"}
New-Item -ItemType Directory -Path $OutputRoot|Out-Null
$XsimEvidence=Join-Path $OutputRoot 'xsim';$OocEvidence=Join-Path $OutputRoot 'ooc';$IpEvidence=Join-Path $OutputRoot 'ip_gen'
New-Item -ItemType Directory -Path $XsimEvidence,$OocEvidence,$IpEvidence|Out-Null

# Generated projects use an ASCII-only root. APPDATA is redirected for every
# batch invocation, so the user's Vivado tclapp manifest remains untouched.
# The caller receives only copied evidence.  Every live Vivado project stays
# in a unique system-temporary directory and is removed even on failure.
$WorkRoot=Join-Path ([IO.Path]::GetTempPath()) ('a3v_'+[guid]::NewGuid().ToString('N'))
function Copy-FailureEvidence([string]$Category='failure'){
    $FailureEvidence=Join-Path $OutputRoot $Category
    New-Item -ItemType Directory -Force -Path $FailureEvidence|Out-Null
    if(Test-Path -LiteralPath $WorkRoot){
        Get-ChildItem -LiteralPath $WorkRoot -Recurse -File|Where-Object{$_.Extension-in @('.log','.rpt','.dcp','.xdc','.tcl')}|ForEach-Object{
            $Relative=$_.FullName.Substring($WorkRoot.Length).TrimStart('\','/')
            $Destination=Join-Path $FailureEvidence $Relative
            New-Item -ItemType Directory -Force -Path(Split-Path -Parent $Destination)|Out-Null
            try{Copy-Item -LiteralPath $_.FullName -Destination $Destination -Force}catch{Write-Warning "Could not preserve active Vivado evidence $($_.FullName): $_"}
        }
    }
}
try {
$SourceRoot=Join-Path $WorkRoot 'src';New-Item -ItemType Directory -Path $SourceRoot|Out-Null
$RtlRelative=@(
 'rtl\core\bc\qk\bf16_to_fp32.v','rtl\core\bc\qk\fp32_to_bf16.v','rtl\core\bc\qk\fp32_mul_ip.v','rtl\core\bc\qk\fp32_add_ip.v',
 'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv','rtl\core\bc\qk\cats_r4_qk_32lane_fp32_service.sv','rtl\core\bc\qk\cats_r4_qk_32lane_engine.sv',
 'rtl\core\bc\qk\cats_r4_qk_q_slab_client.sv','rtl\core\bc\qk\cats_r4_qk_score_formatter.sv','rtl\core\bc\qk\cats_r4_qk_row_assembler.sv',
 'rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv','rtl\core\bc\qk\cats_r4_qk_slot_lifecycle.sv','rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv',
 'rtl\core\bc\qk\cats_r4_qk_row_handoff_wrapper.sv','rtl\core\bc\qk\cats_r4_qk_a2_row_pipeline.sv','rtl\core\bc\qk\cats_r4_qk_score_slot_mem.sv',
 'rtl\core\bc\integration\cats_r4_a3_row_frontend.sv','rtl\core\bc\softmax\exp_lut.sv','rtl\core\bc\softmax\unsigned_restoring_divider.sv',
 'rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv','rtl\core\bc\softmax\cats_r4_b2_compatibility_core_adapter.sv',
 'rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv','rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv','rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv',
 'rtl\core\bc\softmax\cats_r4_row_softmax_accuracy.sv','rtl\core\bc\softmax\cats_r4_b2_locking_arbiter.sv','rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv',
 'rtl\core\bc\softmax\cats_r4_b2_shared_stager_v3_wrapper.sv','rtl\core\bc\pv\cats_r4_b3_pv_controller.sv','rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
 'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv','rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv','rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv',
 'rtl\core\bc\integration\cats_r4_a3_error_join.sv','rtl\core\bc\integration\cats_r4_a3_compute_cluster.sv')
$SupportRelative=@('scripts\create_fp32_ips.tcl','scripts\cats_r4_a3_compute_cluster_ooc.tcl','mem\exp_lut_q15.mem','tb\tb_cats_r4_b4_c_weight_model.sv','tb\tb_cats_r4_a3_compute_cluster.sv')
foreach($Relative in @($RtlRelative+$SupportRelative)){$Source=Join-Path $ProjectRoot $Relative;if(-not(Test-Path -LiteralPath $Source -PathType Leaf)){throw "Required source does not exist: $Source"};$Destination=Join-Path $SourceRoot $Relative;New-Item -ItemType Directory -Force -Path(Split-Path -Parent $Destination)|Out-Null;Copy-Item -LiteralPath $Source -Destination $Destination}
function TclPath([string]$Path){$Path.Replace('\','/')}
function Invoke-Vivado([string]$RunRoot,[string]$Tcl,[string]$Log){
    $SavedAppData=$env:APPDATA;$SavedLocalUserData=$env:XILINX_LOCAL_USER_DATA;$SavedTclLibPath=$env:TCLLIBPATH
    $env:APPDATA=Join-Path $RunRoot '.vivado_appdata';$env:XILINX_LOCAL_USER_DATA='no';$env:TCLLIBPATH=(Join-Path $VivadoRoot 'data\XilinxTclStore\support\appinit').Replace('\','/')
    New-Item -ItemType Directory -Force -Path $env:APPDATA|Out-Null
    $StderrLog="$Log.stderr.log"
    try{
        $Process=Start-Process -FilePath $Vivado -ArgumentList @('-mode','batch','-nojournal','-nolog','-source',$Tcl) -WorkingDirectory $RunRoot -RedirectStandardOutput $Log -RedirectStandardError $StderrLog -WindowStyle Hidden -PassThru
        $Deadline=[DateTime]::UtcNow.AddSeconds($VivadoTimeoutSeconds)
        while(-not $Process.WaitForExit(1000)){
            if([DateTime]::UtcNow-ge$Deadline){
                Copy-FailureEvidence 'failure\timeout_snapshot'
                try{$Process.Kill($true)}catch{$Process.Kill()}
                $Process.WaitForExit()
                Copy-FailureEvidence 'failure\timeout_final'
                throw "Vivado timed out after $VivadoTimeoutSeconds seconds: $Tcl"
            }
        }
        if((Test-Path -LiteralPath $StderrLog)-and(Get-Item -LiteralPath $StderrLog).Length-gt 0){Add-Content -LiteralPath $Log -Value(Get-Content -Raw -LiteralPath $StderrLog)}
        if($Process.ExitCode-ne 0){throw "Vivado failed with exit code $($Process.ExitCode)"}
    }finally{
        $env:APPDATA=$SavedAppData;$env:XILINX_LOCAL_USER_DATA=$SavedLocalUserData;$env:TCLLIBPATH=$SavedTclLibPath
    }
}

$IpProject=Join-Path $WorkRoot 'ip_project'
if($ExistingIpProject){$ExistingIpProject=[IO.Path]::GetFullPath($ExistingIpProject);if(-not(Test-Path -LiteralPath $ExistingIpProject -PathType Container)){throw "ExistingIpProject does not exist: $ExistingIpProject"};Copy-Item -LiteralPath $ExistingIpProject -Destination $IpProject -Recurse}else{$IpRun=Join-Path $WorkRoot 'ip_run';New-Item -ItemType Directory -Path $IpRun|Out-Null;$IpTcl=Join-Path $IpRun 'run.tcl';$IpLog=Join-Path $IpRun 'vivado.log';$IpText=@"
create_project a3_fp32_ip_gen {$(TclPath $IpProject)} -part xczu15eg-ffvb1156-2-i
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source {$(TclPath (Join-Path $SourceRoot 'scripts\create_fp32_ips.tcl'))}
set ip_runs {}
foreach ip_obj [get_ips floating_point_0 floating_point_1 floating_point_2] { set xci [get_files -quiet `$ip_obj.xci]; lappend ip_runs [create_ip_run `$xci] }
launch_runs `$ip_runs -jobs 3
foreach ip_run `$ip_runs { wait_on_run `$ip_run; if {[get_property PROGRESS [get_runs `$ip_run]] ne "100%"} { error "IP synthesis incomplete: `$ip_run" } }
puts "CATS_R4_A3_FP32_IP_GENERATION_PASS"
close_project
"@;[IO.File]::WriteAllText($IpTcl,$IpText,[Text.UTF8Encoding]::new($false));Invoke-Vivado $IpRun $IpTcl $IpLog;Copy-Item $IpTcl,$IpLog -Destination $IpEvidence}
$Xci=0..2|ForEach-Object{$Name="floating_point_$($_)";$Matches=@(Get-ChildItem -LiteralPath $IpProject -Recurse -Filter "$Name.xci"|Where-Object{$_.Directory.Name-eq$Name});if($Matches.Count-ne 1){throw "Expected one $Name XCI, got $($Matches.Count)"};$Matches[0].FullName}
$Rtl=$RtlRelative|ForEach-Object{TclPath(Join-Path $SourceRoot $_)}

if(-not$SkipXsim){$Run=Join-Path $WorkRoot 'xsim_run';New-Item -ItemType Directory -Path $Run|Out-Null;$Tcl=Join-Path $Run 'run.tcl';$Log=Join-Path $Run 'vivado.log';$Tb=@('tb\tb_cats_r4_b4_c_weight_model.sv','tb\tb_cats_r4_a3_compute_cluster.sv')|ForEach-Object{TclPath(Join-Path $SourceRoot $_)};$Mem=TclPath(Join-Path $SourceRoot 'mem\exp_lut_q15.mem');$ModeList=$XsimModes-join' ';$SeedList=$XsimSeeds-join' ';$ExpectedConfigs=$XsimModes.Count*$XsimSeeds.Count;$Text=@"
create_project a3_realip_xsim {$(TclPath (Join-Path $WorkRoot 'xsim_project'))} -part xczu15eg-ffvb1156-2-i
foreach xci [list $(($Xci|ForEach-Object{'{'+(TclPath $_)+'}'})-join' ')] { read_ip `$xci }
generate_target simulation [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {$(($Rtl|ForEach-Object{'{'+$_+'}'})-join' ')}
add_files -fileset sim_1 -norecurse {$(($Tb|ForEach-Object{'{'+$_+'}'})-join' ')}
add_files -fileset sim_1 -norecurse {$Mem}
set_property file_type {Memory File} [get_files -all {$Mem}]
set_property verilog_define {CATS_R4_REAL_IP} [get_filesets sim_1]
set_property top tb_cats_r4_a3_compute_cluster [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
foreach mode {$ModeList} { foreach seed {$SeedList} { set inject_reset [expr {`$mode == 0 && `$seed == 7}]; set inject_abort [expr {`$mode == 1 && `$seed == 19}]; set_property generic "MODE=`$mode ROWS=16 SEED=`$seed INJECT_RESET=`$inject_reset INJECT_ABORT=`$inject_abort EXP_LUT_FILE=$Mem" [get_filesets sim_1]; launch_simulation -simset sim_1 -mode behavioral; run all; close_sim; puts "CATS_R4_A3_REALIP_XSIM_CONFIG_COMPLETE mode=`$mode seed=`$seed reset=`$inject_reset abort=`$inject_abort" } }
puts "CATS_R4_A3_REALIP_XSIM_COMPLETE"
close_project
"@;[IO.File]::WriteAllText($Tcl,$Text,[Text.UTF8Encoding]::new($false));Invoke-Vivado $Run $Tcl $Log;Copy-Item $Tcl,$Log -Destination $XsimEvidence;$Content=Get-Content -Raw $Log;$Passes=([regex]::Matches($Content,'(?m)^PASS A3 REPRESENTATIVE REAL IP .*REAL_IP=1 EVIDENCE_LEVEL=REPRESENTATIVE_REAL_IP_XSIM\r?$')).Count;$Completes=([regex]::Matches($Content,'(?m)^CATS_R4_A3_REALIP_XSIM_CONFIG_COMPLETE')).Count;$Fatals=([regex]::Matches($Content,'(?im)^\s*(Fatal:|FATAL:)')).Count;if($Passes-ne$ExpectedConfigs-or$Completes-ne$ExpectedConfigs-or$Fatals-ne 0-or-not$Content.Contains('CATS_R4_A3_REALIP_XSIM_COMPLETE')){throw "A3 real-IP XSim closure failed: pass=$Passes complete=$Completes expected=$ExpectedConfigs fatals=$Fatals"}}

if(-not$SkipOoc){$Run=Join-Path $WorkRoot 'ooc_run';$Results=Join-Path $WorkRoot 'ooc_results';New-Item -ItemType Directory -Path $Run,$Results|Out-Null;$Xdc=Join-Path $Results 'cats_r4_a3_compute_cluster_ooc.xdc';$XdcText=@"
create_clock -name core_clk -period $ClockPeriodNs [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
# Package-less OOC contract: constrain all top-level synchronous I/O with a
# small virtual board budget while preserving every internal clock path.
set ooc_inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -max 0.100 -clock core_clk `$ooc_inputs
set_input_delay -min 0.000 -clock core_clk `$ooc_inputs
set_output_delay -max 0.100 -clock core_clk [all_outputs]
set_output_delay -min 0.000 -clock core_clk [all_outputs]
"@;[IO.File]::WriteAllText($Xdc,$XdcText,[Text.UTF8Encoding]::new($false));$Tcl=Join-Path $Run 'run.tcl';$Log=Join-Path $Run 'vivado.log';$Vars=@{a3_project_dir=Join-Path $WorkRoot 'ooc_project';a3_part='xczu15eg-ffvb1156-2-i';a3_top='cats_r4_a3_compute_cluster';a3_clock_period=$ClockPeriodNs;a3_xdc=$Xdc;a3_exp_lut_file=Join-Path $SourceRoot 'mem\exp_lut_q15.mem';a3_synth_dcp=Join-Path $Results 'cats_r4_a3_compute_cluster_synth.dcp';a3_route_dcp=Join-Path $Results 'cats_r4_a3_compute_cluster_ooc.dcp';a3_synth_utilization=Join-Path $Results 'synthesis_utilization.rpt';a3_synth_timing=Join-Path $Results 'synthesis_timing_summary.rpt';a3_utilization=Join-Path $Results 'utilization.rpt';a3_timing=Join-Path $Results 'timing_summary.rpt';a3_critical_paths=Join-Path $Results 'critical_paths.rpt';a3_route_status=Join-Path $Results 'route_status.rpt';a3_drc=Join-Path $Results 'drc.rpt';a3_methodology=Join-Path $Results 'methodology.rpt';a3_power=Join-Path $Results 'power.rpt';a3_check_timing=Join-Path $Results 'check_timing.rpt'};$Lines=@();foreach($K in $Vars.Keys){$Lines+="set $K {$(TclPath([string]$Vars[$K]))}"};$Lines+="set a3_rtl_files [list $(($Rtl|ForEach-Object{'{'+$_+'}'})-join' ')]";$Lines+="set a3_xci_files [list $(($Xci|ForEach-Object{'{'+(TclPath $_)+'}'})-join' ')]";$Lines+="source {$(TclPath(Join-Path $SourceRoot 'scripts\cats_r4_a3_compute_cluster_ooc.tcl'))}";[IO.File]::WriteAllLines($Tcl,$Lines,[Text.UTF8Encoding]::new($false));Invoke-Vivado $Run $Tcl $Log;Copy-Item $Tcl,$Log,$Xdc -Destination $OocEvidence;Get-ChildItem -LiteralPath $Results -File|Where-Object{$_.FullName-ne$Xdc}|Copy-Item -Destination $OocEvidence;$Content=Get-Content -Raw $Log;if(-not$Content.Contains('CATS_R4_A3_REALIP_OOC_PASS')-or-not$Content.Contains('CATS_R4_A3_REALIP_OOC_TNS=0')){throw 'A3 real-IP OOC PASS/TNS marker missing'};$Timing=Get-Content -Raw(Join-Path $Results 'timing_summary.rpt');if(-not$Timing.Contains('All user specified timing constraints are met.')){throw 'A3 OOC timing constraints are not met'};$Route=Get-Content -Raw(Join-Path $Results 'route_status.rpt');if($Route-notmatch'(?i)fully routed|routing is complete'){throw 'A3 OOC route is incomplete'};$Drc=Get-Content -Raw(Join-Path $Results 'drc.rpt');if($Drc-match'(?im)^\s*ERROR'){throw 'A3 OOC DRC report contains errors'}}
if($SkipXsim){Write-Host '[PASS] CATS-R4 A3 real-IP 150 MHz OOC implementation'}elseif($SkipOoc){Write-Host '[PASS] CATS-R4 A3 representative real-IP XSim'}else{Write-Host '[PASS] CATS-R4 A3 representative real-IP XSim and 150 MHz OOC implementation'}
} catch {
    Copy-FailureEvidence
    throw
} finally {
    if(Test-Path -LiteralPath $WorkRoot){
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force
    }
}
