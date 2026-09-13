param(
    [string]$VivadoRoot = 'C:\Software\AMD\vivado25.2\2025.2\Vivado',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Rtl = Join-Path $ProjectRoot `
    'rtl\core\bc\qk\cats_r4_qk_score_slot_mem.sv'
$Vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
$OwnOutput = [string]::IsNullOrWhiteSpace($OutputRoot)
if ($OwnOutput) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_qk_score_slot_mem_ooc_' + [guid]::NewGuid().ToString('N'))
}
foreach ($RequiredPath in @($Rtl, $Vivado)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required path does not exist: $RequiredPath"
    }
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}

try {
    New-Item -ItemType Directory -Path $OutputRoot | Out-Null
    $RtlTcl = $Rtl.Replace('\', '/')
    $TclStoreTcl = (Join-Path $VivadoRoot 'data\XilinxTclStore').Replace('\', '/')
    $Tcl = @'
lappend auto_path {__TCLSTORE__/support/appinit}
foreach app_dir [glob -nocomplain -types d {__TCLSTORE__/tclapp/*/*}] {
    lappend auto_path $app_dir
}
read_verilog -sv {__RTL__}
synth_design -mode out_of_context -flatten_hierarchy none \
    -top cats_r4_qk_score_slot_mem -part xczu15eg-ffvb1156-2-i
report_utilization -file score_slot_mem_utilization.rpt
check_timing -verbose -file score_slot_mem_check_timing.rpt
puts "SCORE_SLOT_MEM_BANKED_OOC_PASS"
'@
    $Tcl = $Tcl.Replace('__RTL__', $RtlTcl)
    $Tcl = $Tcl.Replace('__TCLSTORE__', $TclStoreTcl)
    $TclPath = Join-Path $OutputRoot 'run_score_slot_mem_ooc.tcl'
    [IO.File]::WriteAllText(
        $TclPath, $Tcl, [Text.UTF8Encoding]::new($false))

    Push-Location $OutputRoot
    try {
        $VivadoLog = & $Vivado -mode batch -nojournal -nolog `
            -source $TclPath 2>&1
        [IO.File]::WriteAllLines(
            (Join-Path $OutputRoot 'vivado_ooc.log'),
            [string[]]$VivadoLog,
            [Text.UTF8Encoding]::new($false))
        if ($LASTEXITCODE -ne 0) {
            $VivadoLog | Select-Object -Last 80 | ForEach-Object { Write-Host $_ }
            throw "Vivado OOC failed: $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    $JoinedLog = $VivadoLog -join [Environment]::NewLine
    if (-not $JoinedLog.Contains('SCORE_SLOT_MEM_BANKED_OOC_PASS')) {
        throw 'score slot memory OOC PASS marker missing'
    }
    if ($JoinedLog -match '(?i)multiple.driver') {
        throw 'score slot memory OOC reported multiple-driver storage'
    }
    if ($JoinedLog -match '(?i)(ram_style.*ignored|not inferred as ram)') {
        throw 'score slot memory OOC did not honor distributed-RAM banking'
    }
    $Utilization = [IO.File]::ReadAllText(
        (Join-Path $OutputRoot 'score_slot_mem_utilization.rpt'))
    $LutRamMatch = [regex]::Match(
        $Utilization, '\|\s+LUT as Memory\s+\|\s+([1-9][0-9]*)\s+\|')
    if (-not $LutRamMatch.Success) {
        throw 'score slot memory OOC inferred no LUT memory'
    }
    Write-Host (('[PASS] CATS-R4 banked score memory Vivado OOC synthesis ' +
        'LUT-as-memory={0}') -f $LutRamMatch.Groups[1].Value)
} finally {
    if ($OwnOutput -and (Test-Path -LiteralPath $OutputRoot)) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
