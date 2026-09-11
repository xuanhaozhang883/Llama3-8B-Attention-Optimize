param([string]$IcarusRoot = 'C:\iverilog', [string]$OutputRoot = '')
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_pv_output_'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot exists: $OutputRoot"}
New-Item -ItemType Directory -Path $OutputRoot|Out-Null
$iv=Join-Path $IcarusRoot 'bin\iverilog.exe'; $vvp=Join-Path $IcarusRoot 'bin\vvp.exe'
$cases=@(
 @{Name='pv_accumulator'; Top='tb_cats_r4_pv_fp32_accumulator'; Rtl=@('rtl\core\pv\cats_r4_pv_fp32_accumulator.sv','tb\tb_flash_fp32_mocks.sv'); Tb='tb\tb_cats_r4_pv_fp32_accumulator.sv'},
 @{Name='weight_pv_wrapper'; Top='tb_cats_r4_weight_pv_wrapper'; Rtl=@('rtl\core\bc\backend\cats_r4_weight_pv_wrapper.sv'); Tb='tb\tb_cats_r4_weight_pv_wrapper.sv'},
 @{Name='output_writer'; Top='tb_cats_r4_output_writer_64'; Rtl=@('rtl\core\cluster\cats_r4_output_writer_64.sv'); Tb='tb\tb_cats_r4_output_writer_64.sv'}
)
foreach($c in $cases){$snap=Join-Path $OutputRoot ($c.Name+'.vvp'); $src=@($c.Rtl|ForEach-Object{Join-Path $Root $_})+(Join-Path $Root $c.Tb); & $iv -g2012 -s $c.Top -o $snap $src; if($LASTEXITCODE-ne 0){throw "$($c.Name) compile failed"}; $o=& $vvp $snap 2>&1; $o|ForEach-Object{Write-Host $_}; if($LASTEXITCODE-ne 0 -or -not (($o-join "`n").Contains('PASS:'))){throw "$($c.Name) PASS marker missing"}}
Write-Host "[PASS] CATS-R4 PV/output candidate regressions; artifacts: $OutputRoot"
