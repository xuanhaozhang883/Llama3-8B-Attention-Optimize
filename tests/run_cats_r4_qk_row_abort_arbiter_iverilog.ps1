param([string]$IcarusRoot='C:\Software\iverilog',[string]$OutputRoot='')
$ErrorActionPreference='Stop';$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path([IO.Path]::GetTempPath())('cats_r4_abort_arb_'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot|Out-Null;$snap=Join-Path $OutputRoot 'abort.vvp'
& (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -s tb_cats_r4_qk_row_abort_arbiter -o $snap (Join-Path $Root 'rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv') (Join-Path $Root 'tb\tb_cats_r4_qk_row_abort_arbiter.sv')
if($LASTEXITCODE-ne 0){throw "iverilog failed: $LASTEXITCODE"};$out=&(Join-Path $IcarusRoot 'bin\vvp.exe')$snap 2>&1;$out|%{Write-Host $_}
if($LASTEXITCODE-ne 0-or-not(($out-join"`n").Contains('PASS: CATS-R4 row abort arbiter preserves stalled payload and source order'))){throw 'abort arbiter PASS missing'}
