param([string]$IcarusRoot='C:\iverilog',[string]$OutputRoot='')
$ErrorActionPreference='Stop';$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_weight_pv_mem_'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot exists: $OutputRoot"};New-Item -ItemType Directory -Path $OutputRoot|Out-Null
$Replay=Join-Path $OutputRoot 'replay';$Snap=Join-Path $OutputRoot 'weight_pv_mem.vvp'
& python (Join-Path $Root 'python\flash_attention_tile_model.py') --emit-cats-r4-if-v3-replay $Replay;if($LASTEXITCODE-ne 0){throw 'replay generation failed'}
$iv=Join-Path $IcarusRoot 'bin\iverilog.exe';$vvp=Join-Path $IcarusRoot 'bin\vvp.exe'
& $iv -g2012 -s tb_cats_r4_weight_pv_mem_integration -o $Snap (Join-Path $Root 'tb\tb_cats_r4_weight_pv_mem_integration.sv') (Join-Path $Root 'rtl\core\bc\softmax\cats_r4_if_v3_replay_adapter.sv') (Join-Path $Root 'rtl\core\cluster\cats_r4_weight_slot_mem.sv') (Join-Path $Root 'rtl\core\bc\backend\cats_r4_weight_pv_wrapper.sv');if($LASTEXITCODE-ne 0){throw 'iverilog failed'}
$o=& $vvp $Snap "+REPLAY_ROOT=$Replay" 2>&1;$o|ForEach-Object{Write-Host $_};if($LASTEXITCODE-ne 0 -or -not (($o-join "`n").Contains('PASS: CATS-R4 replay -> weight slot -> PV wrapper -> release'))){throw 'integration PASS marker missing'}
Write-Host "[PASS] CATS-R4 replay/weight/PV-memory integration; artifacts: $OutputRoot"