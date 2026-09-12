param([string]$IcarusRoot='C:\iverilog',[string]$OutputRoot='')
$ErrorActionPreference='Continue'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_single_cluster_'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot exists: $OutputRoot"}
New-Item -ItemType Directory -Path $OutputRoot|Out-Null
$iv=Join-Path $IcarusRoot 'bin\iverilog.exe';$vvp=Join-Path $IcarusRoot 'bin\vvp.exe'
if(-not (Test-Path -LiteralPath $iv) -or -not (Test-Path -LiteralPath $vvp)){throw "Icarus not found under $IcarusRoot"}
$src=@(
 'tb\tb_cats_r4_single_cluster_wrapper.sv',
 'rtl\core\cluster\cats_r4_single_cluster_wrapper.sv',
 'rtl\core\cluster\cats_r4_weight_slot_mem.sv',
 'rtl\core\bc\backend\cats_r4_weight_pv_wrapper.sv',
 'rtl\core\pv\cats_r4_pv_weight_v_product_adapter.sv',
 'rtl\core\pv\cats_r4_pv_fp32_accumulator.sv',
 'rtl\core\cluster\cats_r4_output_cdc_writer_candidate.sv',
 'rtl\core\cluster\cats_r4_output_reorder_cdc_writer_candidate.sv',
 'rtl\core\cluster\cats_r4_output_cdc.sv',
 'rtl\core\cluster\cats_r4_async_fifo.sv',
 'rtl\core\cluster\cats_r4_output_reorder_serializer.sv',
 'rtl\core\cluster\cats_r4_output_writer_64.sv',
 'rtl\core\cluster\cats_r4_abort_drain_controller.sv',
 'tb\tb_flash_fp32_mocks.sv'
)|ForEach-Object{Join-Path $Root $_}
$snap=Join-Path $OutputRoot 'single_cluster_wrapper.vvp'
$compileLog=Join-Path $OutputRoot 'iverilog_compile.log';$runLog=Join-Path $OutputRoot 'single_cluster_wrapper.log'
& $iv -g2012 -s tb_cats_r4_single_cluster_wrapper -o $snap $src *> $compileLog
if($LASTEXITCODE-ne 0){throw 'single-cluster Icarus compile failed'}
$o=& $vvp $snap 2>&1 | Tee-Object -FilePath $runLog
if($LASTEXITCODE-ne 0 -or -not (($o-join "`n").Contains('PASS: CATS-R4 single-cluster replay -> slot -> PV -> output CDC/DDR writer'))){throw 'single-cluster PASS marker missing'}
Write-Host "[PASS] CATS-R4 single-cluster replay -> slot -> PV -> output CDC/DDR writer; artifacts: $OutputRoot"