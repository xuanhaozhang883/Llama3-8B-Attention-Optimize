param(
    [string]$IcarusRoot = 'C:\iverilog',
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
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) 'cats_r4_qk_32lane_engine_iverilog'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$Sources = @(
    'tb\tb_qk_fp32_mocks.sv',
    'rtl\core\bc\qk\bf16_to_fp32.v',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\qk\cats_r4_qk_32lane_scheduler.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_fp32_service.sv',
    'rtl\core\bc\qk\cats_r4_qk_32lane_engine.sv',
    'tb\tb_cats_r4_qk_32lane_engine.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }
$Snapshot = Join-Path $OutputRoot 'engine_sim.vvp'
$SavedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $Iverilog -g2012 -s tb_cats_r4_qk_32lane_engine -o $Snapshot @Sources 2>&1 |
        Tee-Object -FilePath (Join-Path $OutputRoot 'compile.log')
} finally {
    $ErrorActionPreference = $SavedErrorActionPreference
}
if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }

$Runtime = & $Vvp $Snapshot 2>&1 |
    Tee-Object -FilePath (Join-Path $OutputRoot 'runtime.log')
if ($LASTEXITCODE -ne 0) { throw "vvp failed: $LASTEXITCODE" }
if (-not (($Runtime -join [Environment]::NewLine).Contains(
    'PASS: CATS-R4 integrated scheduler/FP32 service/score FIFO'))) {
    throw 'engine PASS marker missing'
}

Write-Host '[PASS] CATS-R4 integrated QK engine Icarus protocol/numeric checkpoint'
