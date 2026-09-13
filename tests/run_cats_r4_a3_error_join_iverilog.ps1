param(
    [string]$IcarusRoot = 'C:\Software\iverilog',
    [string]$OutputRoot = ''
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_a3_error_join_' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'a3_error_join.vvp'
$Sources = @()
$JoinSource = Join-Path $ProjectRoot `
    'rtl\core\bc\integration\cats_r4_a3_error_join.sv'
if (Test-Path -LiteralPath $JoinSource) { $Sources += $JoinSource }
$Sources += Join-Path $ProjectRoot 'tb\tb_cats_r4_a3_error_join.sv'
try {
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 `
        -s tb_cats_r4_a3_error_join -o $Snapshot @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }
    $Runtime = & (Join-Path $IcarusRoot 'bin\vvp.exe') $Snapshot 2>&1
    $Runtime | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (($Runtime -join "`n").Contains(
        'PASS: CATS-R4 A3 buffered error join'))) {
        throw 'A3 error join PASS marker missing'
    }
    Write-Host '[PASS] CATS-R4 A3 buffered error join Icarus regression'
} finally {
    if (Test-Path -LiteralPath $OutputRoot) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
