param([string]$IcarusRoot = 'C:\iverilog', [string]$OutputRoot = '')
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_pv_vcache_'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot exists: $OutputRoot"}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$iv=Join-Path $IcarusRoot 'bin\iverilog.exe'; $vvp=Join-Path $IcarusRoot 'bin\vvp.exe'
if(!(Test-Path $iv) -or !(Test-Path $vvp)){throw "Icarus not found under $IcarusRoot"}
$snap=Join-Path $OutputRoot 'pv_vcache_to_context.vvp'
$src=@(
  'rtl\core\bc\backend\bf16_v_cache.sv',
  'rtl\core\pv\cats_r4_pv_weight_v_product_adapter.sv',
  'rtl\core\pv\cats_r4_pv_fp32_accumulator.sv',
  'tb\tb_flash_fp32_mocks.sv',
  'tb\tb_cats_r4_pv_vcache_to_context.sv'
) | ForEach-Object { Join-Path $Root $_ }
& $iv -g2012 -s tb_cats_r4_pv_vcache_to_context -o $snap $src
if($LASTEXITCODE -ne 0){throw 'V-cache PV integration compile failed'}
$out=& $vvp $snap 2>&1
$out | ForEach-Object { Write-Host $_ }
if($LASTEXITCODE -ne 0 -or -not (($out -join "`n").Contains('PASS: CATS-R4 real BF16 V-cache'))){throw 'V-cache PV integration PASS marker missing'}
Write-Host "[PASS] CATS-R4 real V-cache -> PV -> context Golden gate; artifacts: $OutputRoot"