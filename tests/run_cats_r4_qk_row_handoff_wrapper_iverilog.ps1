param([string]$IcarusRoot='C:\Software\iverilog',[string]$OutputRoot='')
$ErrorActionPreference='Stop'; $Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_row_wrap_'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot|Out-Null
$src=@('cats_r4_qk_row_assembler.sv','cats_r4_qk_ab_handoff.sv','cats_r4_qk_slot_lifecycle.sv','cats_r4_qk_row_handoff_wrapper.sv')|ForEach-Object{Join-Path $Root "rtl\core\bc\qk\$_"}
$snap=Join-Path $OutputRoot 'row_wrap.vvp'
& (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -s tb_cats_r4_qk_row_handoff_wrapper -o $snap $src (Join-Path $Root 'tb\tb_cats_r4_qk_row_handoff_wrapper.sv')
if($LASTEXITCODE-ne 0){throw "iverilog failed: $LASTEXITCODE"}
$out=& (Join-Path $IcarusRoot 'bin\vvp.exe') $snap 2>&1; $out|ForEach-Object{Write-Host $_}
if($LASTEXITCODE-ne 0-or-not(($out-join"`n").Contains('PASS: CATS-R4 integrated formatted row, A-to-B handoff, and final release'))){throw 'wrapper PASS missing'}
Write-Host '[PASS] CATS-R4 row handoff wrapper regression'
