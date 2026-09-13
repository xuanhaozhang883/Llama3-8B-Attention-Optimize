param(
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = ''
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_a3_row_frontend_' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'a3_row_frontend.vvp'
$Sources = @(
    'rtl\core\bc\qk\cats_r4_qk_row_assembler.sv',
    'rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv',
    'rtl\core\bc\qk\cats_r4_qk_slot_lifecycle.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_handoff_wrapper.sv',
    'rtl\core\bc\qk\cats_r4_qk_a2_row_pipeline.sv',
    'rtl\core\bc\qk\cats_r4_qk_score_slot_mem.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }
$FrontendSource = Join-Path $ProjectRoot `
    'rtl\core\bc\integration\cats_r4_a3_row_frontend.sv'
if (Test-Path -LiteralPath $FrontendSource) { $Sources += $FrontendSource }
$Sources += Join-Path $ProjectRoot 'tb\tb_cats_r4_a3_row_frontend.sv'
try {
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 `
        -s tb_cats_r4_a3_row_frontend -o $Snapshot @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }
    $Runtime = & (Join-Path $IcarusRoot 'bin\vvp.exe') $Snapshot 2>&1
    $Runtime | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (($Runtime -join "`n").Contains(
        'PASS: CATS-R4 A3 row frontend physical slots, release gating, stalls, and counters'))) {
        throw 'A3 row frontend PASS marker missing'
    }
    Write-Host '[PASS] CATS-R4 A3 row frontend Icarus regression'
} finally {
    if (Test-Path -LiteralPath $OutputRoot) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
