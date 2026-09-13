param(
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'
$OwnOutput = [string]::IsNullOrWhiteSpace($OutputRoot)
if ($OwnOutput) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_qk_score_slot_mem_' + [guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}

try {
    New-Item -ItemType Directory -Path $OutputRoot | Out-Null
    $Snapshot = Join-Path $OutputRoot 'score_slot_mem.vvp'
    $RtlSource = Join-Path $ProjectRoot `
        'rtl\core\bc\qk\cats_r4_qk_score_slot_mem.sv'
    $Sources = @()
    if (Test-Path -LiteralPath $RtlSource) { $Sources += $RtlSource }
    $Sources += Join-Path $ProjectRoot 'tb\tb_cats_r4_qk_score_slot_mem.sv'
    & $Iverilog -g2012 -Wall -s tb_cats_r4_qk_score_slot_mem `
        -o $Snapshot $Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }

    $Runtime = & $Vvp $Snapshot 2>&1
    $Runtime | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or
        -not (($Runtime -join [Environment]::NewLine).Contains(
            'PASS: CATS-R4 three-slot score memory'))) {
        throw 'score slot memory PASS marker missing'
    }
    Write-Host '[PASS] CATS-R4 three-slot score memory Icarus regression'
} finally {
    if ($OwnOutput -and (Test-Path -LiteralPath $OutputRoot)) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
