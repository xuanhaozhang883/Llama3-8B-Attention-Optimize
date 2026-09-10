param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoRoot,

    [string]$OutputRoot = '',

    [double]$ClockPeriodNs = 6.666
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
$Xvlog = Join-Path $VivadoRoot 'bin\xvlog.bat'
$Xelab = Join-Path $VivadoRoot 'bin\xelab.bat'
$Xsim = Join-Path $VivadoRoot 'bin\xsim.bat'
foreach ($Tool in @($Vivado, $Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "Vivado tool not found: $Tool"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'cats_r4_c_vivado_' + [guid]::NewGuid().ToString('N')
    )
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

function Invoke-Checked {
    param(
        [string]$Tool,
        [string[]]$Arguments,
        [string]$Label,
        [string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $Tool @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Label failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Assert-CleanOocReports {
    param(
        [string]$CaseRoot,
        [string]$Label
    )

    $TimingPath = Join-Path $CaseRoot 'timing_summary.rpt'
    $CheckTimingPath = Join-Path $CaseRoot 'check_timing.rpt'
    $MethodologyPath = Join-Path $CaseRoot 'methodology.rpt'
    foreach ($Path in @($TimingPath, $CheckTimingPath, $MethodologyPath)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "$Label did not generate required report: $Path"
        }
    }

    $Timing = Get-Content -LiteralPath $TimingPath -Raw
    if (-not $Timing.Contains('All user specified timing constraints are met.')) {
        throw "$Label timing report does not show a clean timing result"
    }

    $CheckTiming = Get-Content -LiteralPath $CheckTimingPath -Raw
    if ($CheckTiming -match 'checking\s+\S+\s+\([1-9][0-9]*\)') {
        throw "$Label check_timing report contains nonzero findings"
    }

    $Methodology = Get-Content -LiteralPath $MethodologyPath -Raw
    if (-not $Methodology.Contains('Checks found: 0')) {
        throw "$Label methodology report contains findings"
    }
}

function Assert-NoCriticalCdc {
    param(
        [string]$CaseRoot,
        [string]$Label
    )

    $CdcPath = Join-Path $CaseRoot 'cdc.rpt'
    if (-not (Test-Path -LiteralPath $CdcPath -PathType Leaf)) {
        throw "$Label did not generate required CDC report: $CdcPath"
    }
    $Cdc = Get-Content -LiteralPath $CdcPath -Raw
    if ($Cdc -match 'CDC-[0-9]+\s+Critical\s+[1-9][0-9]*') {
        throw "$Label CDC report contains critical crossings"
    }
}

$SimulationRoot = Join-Path $OutputRoot 'real_xpm_runtime'
$SimulationScript = Join-Path $PSScriptRoot 'run_cats_r4_qkv_axi_bank_bridge_vivado.ps1'
& $SimulationScript -VivadoRoot $VivadoRoot -OutputRoot $SimulationRoot
if ($LASTEXITCODE -ne 0) {
    throw "C real-XPM runtime checks failed: $LASTEXITCODE"
}

$WeightRuntimeRoot = Join-Path $OutputRoot 'weight_slot_runtime'
New-Item -ItemType Directory -Path $WeightRuntimeRoot | Out-Null
$WeightRtl = Join-Path $ProjectRoot 'rtl\core\cluster\cats_r4_weight_slot_mem.sv'
$WeightTb = Join-Path $ProjectRoot 'tb\tb_cats_r4_weight_slot_mem.sv'
Invoke-Checked -Tool $Xvlog -Arguments @(
    '-sv', $WeightRtl, $WeightTb
) -Label 'IF_V3 weight-slot xvlog' -WorkingDirectory $WeightRuntimeRoot
Invoke-Checked -Tool $Xelab -Arguments @(
    'tb_cats_r4_weight_slot_mem', '-O3', '-s', 'weight_slot_runtime_sim'
) -Label 'IF_V3 weight-slot xelab' -WorkingDirectory $WeightRuntimeRoot
Invoke-Checked -Tool $Xsim -Arguments @(
    'weight_slot_runtime_sim', '-runall'
) -Label 'IF_V3 weight-slot xsim' -WorkingDirectory $WeightRuntimeRoot
$WeightRuntimeLog = Get-Content -LiteralPath (
    Join-Path $WeightRuntimeRoot 'xsim.log'
) -Raw
if (-not $WeightRuntimeLog.Contains(
        'PASS CATS_R4_IF_V3 weight slots rows=4096 writes=524288 reads=524288 N+2'
    ) -or $WeightRuntimeLog.Contains('FAIL:')) {
    throw 'IF_V3 weight-slot XSim completed without a clean full-workload PASS'
}

$OocCases = @(
    @{
        Label = 'QKV AXI bank bridge'
        Name = 'qkv_axi_bank_bridge_ooc'
        Script = 'scripts\cats_r4_qkv_axi_bank_bridge_ooc.tcl'
    },
    @{
        Label = 'Q-slab DMA'
        Name = 'q_slab_dma_ooc'
        Script = 'scripts\cats_r4_q_slab_dma_ooc.tcl'
    },
    @{
        Label = 'IF_V3 weight-slot memory service'
        Name = 'weight_slot_mem_ooc'
        Script = 'scripts\cats_r4_weight_slot_mem_ooc.tcl'
    },
    @{
        Label = 'output CDC'
        Name = 'output_cdc_ooc'
        Script = 'scripts\cats_r4_output_cdc_ooc.tcl'
    },
    @{
        Label = 'abort/drain controller'
        Name = 'abort_drain_ooc'
        Script = 'scripts\cats_r4_abort_drain_ooc.tcl'
    }
)

foreach ($Case in $OocCases) {
    $CaseRoot = Join-Path $OutputRoot $Case.Name
    New-Item -ItemType Directory -Path $CaseRoot | Out-Null
    $TclScript = Join-Path $ProjectRoot $Case.Script
    Invoke-Checked -Tool $Vivado -Arguments @(
        '-mode', 'batch', '-source', $TclScript,
        '-tclargs', $ProjectRoot, $CaseRoot, $ClockPeriodNs.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
    ) -Label $Case.Label -WorkingDirectory $CaseRoot
    Assert-CleanOocReports -CaseRoot $CaseRoot -Label $Case.Label
    if ($Case.Name -in @('output_cdc_ooc', 'abort_drain_ooc')) {
        Assert-NoCriticalCdc -CaseRoot $CaseRoot -Label $Case.Label
    }
}

Write-Host '[PASS] CATS-R4 C Vivado suite: two vendor runtimes and five clean 150 MHz OOC gates'
Write-Host "[INFO] Logs and reports: $OutputRoot"
