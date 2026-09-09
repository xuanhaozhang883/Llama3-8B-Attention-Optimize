param(
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_qk_row_assembler_' + [guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$Sources = @(
    (Join-Path $ProjectRoot 'rtl\core\bc\qk\cats_r4_qk_row_assembler.sv'),
    (Join-Path $ProjectRoot 'tb\tb_cats_r4_qk_row_assembler.sv')
)
$Snapshot = Join-Path $OutputRoot 'row_assembler.vvp'

& $Iverilog -g2012 -s tb_cats_r4_qk_row_assembler -o $Snapshot $Sources
if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }

$Runtime = & $Vvp $Snapshot 2>&1
$Runtime | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0 -or
    -not (($Runtime -join [Environment]::NewLine).Contains(
        'PASS: CATS-R4 row assembler causal masks, BF16 max, and row backpressure'))) {
    throw 'row assembler PASS marker missing'
}

Write-Host '[PASS] CATS-R4 QK row assembler Icarus regression'
