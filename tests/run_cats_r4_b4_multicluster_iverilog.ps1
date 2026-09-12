param(
    [ValidateSet(1, 2, 4)]
    [int]$Clusters = 1,
    [ValidateSet(0, 1)]
    [int]$Mode = 0,
    [ValidateRange(1, 32)]
    [int]$GlobalHeads = 32,
    [ValidateRange(1, 128)]
    [int]$RowsPerHead = 128,
    [uint32]$Seed = 3019898881,
    [string]$IcarusRoot = 'D:\iverilog\iverilog',
    [switch]$ProtocolModels,
    [switch]$ErrorRelease
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ($ErrorRelease -and $ProtocolModels) {
    throw 'ErrorRelease requires the real B2/B3 RTL, not ProtocolModels'
}
if ($ErrorRelease -and
    ($Clusters -ne 1 -or $GlobalHeads -ne 1 -or $RowsPerHead -ne 1)) {
    throw 'ErrorRelease requires Clusters=1, GlobalHeads=1, RowsPerHead=1'
}
$OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('cats_r4_b4_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'b4_multicluster.vvp'
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'

$Sources = @('rtl\core\bc\pv\cats_r4_b3_pv_controller.sv')
if ($ProtocolModels) {
    $Sources += @(
        'tb\tb_cats_r4_b4_b2_protocol_model.sv',
        'tb\tb_cats_r4_b4_b3_protocol_model.sv'
    )
} else {
    $Sources += @(
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
        'tb\tb_cats_r4_b3_fp32_mocks.sv',
        'rtl\core\bc\qk\fp32_to_bf16.v',
        'rtl\core\bc\pv\cats_r4_b3_pv_mac_32lane.sv',
        'rtl\core\bc\pv\cats_r4_b3_pv_normalize_32lane.sv',
        'rtl\core\bc\pv\cats_r4_b3_pv_32lane.sv'
    )
}
$Sources += @(
    'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv',
    'tb\tb_cats_r4_b4_c_weight_model.sv',
    'tb\tb_cats_r4_b4_multicluster.sv'
)
$SourcePaths = $Sources | ForEach-Object { Join-Path $ProjectRoot $_ }

try {
    & $Iverilog -g2012 -s tb_cats_r4_b4_multicluster `
        "-Ptb_cats_r4_b4_multicluster.CLUSTERS=$Clusters" `
        "-Ptb_cats_r4_b4_multicluster.GLOBAL_HEADS=$GlobalHeads" `
        "-Ptb_cats_r4_b4_multicluster.ROWS_PER_HEAD=$RowsPerHead" `
        "-Ptb_cats_r4_b4_multicluster.MODE=$Mode" `
        "-Ptb_cats_r4_b4_multicluster.SEED=$Seed" `
        "-Ptb_cats_r4_b4_multicluster.INJECT_SCORE_ERROR=$([int]$ErrorRelease.IsPresent)" `
        -o $Snapshot $SourcePaths
    if ($LASTEXITCODE -ne 0) {
        throw 'CATS-R4 B4 multicluster compile failed'
    }
    Push-Location $ProjectRoot
    try {
        & $Vvp $Snapshot
        if ($LASTEXITCODE -ne 0) {
            throw 'CATS-R4 B4 multicluster simulation failed'
        }
    } finally {
        Pop-Location
    }
    Write-Host "[PASS] CATS-R4 B4 clusters=$Clusters mode=$Mode heads=$GlobalHeads rows_per_head=$RowsPerHead seed=$Seed error_release=$($ErrorRelease.IsPresent)"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
