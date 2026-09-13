param(
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'
foreach ($Path in @($Iverilog, $Vvp)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Icarus tool not found: $Path"
    }
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_compute_frontend_routing_' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$RelativeSources = @(
    'rtl\core\bc\qk\bf16_to_fp32.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'tb\tb_qk_fp32_mocks.sv',
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
    'tb\tb_cats_r4_compute_frontend_routing.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }

foreach ($Clusters in @(1, 2, 4)) {
    $Snapshot = Join-Path $OutputRoot ("routing_${Clusters}c.vvp")
    $CompileLog = Join-Path $OutputRoot ("routing_${Clusters}c_compile.log")
    $SavedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Iverilog -g2012 -s tb_cats_r4_compute_frontend_routing `
            "-Ptb_cats_r4_compute_frontend_routing.CLUSTERS=$Clusters" `
            -o $Snapshot @RelativeSources 2>&1 |
            Tee-Object -FilePath $CompileLog
    } finally {
        $ErrorActionPreference = $SavedErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) { throw "Icarus compile failed for CLUSTERS=$Clusters" }
    $Runtime = & $Vvp $Snapshot 2>&1 |
        Tee-Object -FilePath (Join-Path $OutputRoot ("routing_${Clusters}c_runtime.log"))
    if ($LASTEXITCODE -ne 0 -or
        -not (($Runtime -join [Environment]::NewLine).Contains(
            "PASS: CATS-R4 compute frontend static group routing CLUSTERS=$Clusters"))) {
        throw "routing PASS marker missing for CLUSTERS=$Clusters"
    }
}
Write-Host '[PASS] CATS-R4 compute frontend static 1/2/4-cluster routing regression'
