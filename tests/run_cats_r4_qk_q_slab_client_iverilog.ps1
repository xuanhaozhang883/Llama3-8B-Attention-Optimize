param([string]$IcarusRoot = 'C:\Software\iverilog', [string]$OutputRoot = '')
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_q_slab_client_' + [guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'q_slab_client.vvp'
& (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 `
    -s tb_cats_r4_qk_q_slab_client -o $Snapshot `
    (Join-Path $ProjectRoot 'rtl\core\bc\qk\cats_r4_qk_q_slab_client.sv') `
    (Join-Path $ProjectRoot 'tb\tb_cats_r4_qk_q_slab_client.sv')
if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }
$Runtime = & (Join-Path $IcarusRoot 'bin\vvp.exe') $Snapshot 2>&1
$Runtime | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0 -or -not (($Runtime -join "`n").Contains(
    'PASS: CATS-R4 A Q-slab full lifecycle slabs=256 engine_jobs=6144'))) {
    throw 'Q-slab client PASS marker missing'
}
Write-Host '[PASS] CATS-R4 A Q-slab client Icarus regression'
