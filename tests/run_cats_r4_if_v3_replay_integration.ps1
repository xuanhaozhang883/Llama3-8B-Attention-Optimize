param(
    [string]$IcarusRoot = 'C:\iverilog',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_if_v3_replay_' + [guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot exists: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$ReplayRoot = Join-Path $OutputRoot 'replay'
$Snapshot = Join-Path $OutputRoot 'cats_r4_if_v3_replay_integration.vvp'

& python (Join-Path $ProjectRoot 'python\flash_attention_tile_model.py') `
    '--emit-cats-r4-if-v3-replay' $ReplayRoot
if ($LASTEXITCODE -ne 0) { throw "Golden replay generation failed: $LASTEXITCODE" }

$Icarus = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'
& $Icarus -g2012 -s tb_cats_r4_if_v3_replay_integration -o $Snapshot `
    (Join-Path $ProjectRoot 'tb\tb_cats_r4_if_v3_replay_integration.sv') `
    (Join-Path $ProjectRoot 'rtl\core\bc\softmax\cats_r4_if_v3_replay_adapter.sv') `
    (Join-Path $ProjectRoot 'rtl\core\cluster\cats_r4_weight_slot_mem.sv')
if ($LASTEXITCODE -ne 0) { throw "iverilog failed: $LASTEXITCODE" }

$Runtime = & $Vvp $Snapshot "+REPLAY_ROOT=$ReplayRoot" 2>&1
$Runtime | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0 -or -not (($Runtime -join "`n").Contains(
    'PASS: CATS-R4 A/software-B replay -> C IF_V3 weight lifecycle'))) {
    throw 'replay integration PASS marker missing'
}
Write-Host "[PASS] CATS-R4 IF_V3 replay integration; artifacts: $OutputRoot"
