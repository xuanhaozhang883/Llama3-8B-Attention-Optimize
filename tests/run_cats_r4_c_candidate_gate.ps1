param([string]$IcarusRoot='C:\iverilog',[string]$VivadoRoot='', [string]$OutputRoot='')
$ErrorActionPreference='Stop';$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_c_gate_'+[guid]::NewGuid().ToString('N'))};New-Item -ItemType Directory -Path $OutputRoot|Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\run_cats_r4_pv_output_candidates_iverilog.ps1') -IcarusRoot $IcarusRoot -OutputRoot (Join-Path $OutputRoot 'pv_output');if($LASTEXITCODE-ne 0){throw 'PV/output Icarus gate failed'}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\run_cats_r4_weight_pv_mem_integration.ps1') -IcarusRoot $IcarusRoot -OutputRoot (Join-Path $OutputRoot 'weight_pv_mem');if($LASTEXITCODE-ne 0){throw 'weight/PV memory Icarus gate failed'}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\\run_cats_r4_pv_vcache_to_context.ps1') -IcarusRoot $IcarusRoot -OutputRoot (Join-Path $OutputRoot 'pv_vcache_to_context');if($LASTEXITCODE-ne 0){throw 'V-cache PV context Icarus gate failed'}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\\run_cats_r4_single_cluster_wrapper.ps1') -IcarusRoot $IcarusRoot -OutputRoot (Join-Path $OutputRoot 'single_cluster_wrapper');if($LASTEXITCODE-ne 0){throw 'single-cluster wrapper Icarus gate failed'}
if(-not [string]::IsNullOrWhiteSpace($VivadoRoot)){
 $xvlog=Join-Path $VivadoRoot 'bin\xvlog.bat';$vroot=Join-Path $OutputRoot 'vivado';New-Item -ItemType Directory -Path $vroot|Out-Null
 $src=@('rtl\core\bc\backend\cats_r4_weight_pv_wrapper.sv','rtl\core\pv\cats_r4_pv_weight_v_product_adapter.sv','rtl\core\pv\cats_r4_pv_fp32_accumulator.sv','rtl\core\cluster\cats_r4_output_writer_64.sv','rtl\core\cluster\cats_r4_context_output_chain_candidate.sv','rtl\core\cluster\cats_r4_output_cdc_writer_candidate.sv','rtl\core\cluster\cats_r4_output_cdc.sv','rtl\core\cluster\cats_r4_async_fifo.sv','rtl\core\cluster\cats_r4_output_reorder_serializer.sv','rtl\core\pv\pv_fp32_mul_ip.sv','rtl\core\pv\pv_fp32_add_ip.sv')|ForEach-Object{Join-Path $Root $_}
 & $xvlog -sv -work xil_defaultlib @src; if($LASTEXITCODE-ne 0){throw 'Vivado xvlog candidate gate failed'};Write-Host '[PASS] Vivado xvlog C candidate gate'
}else{Write-Host '[INFO] VivadoRoot not supplied; Icarus integration gates passed, Vivado OOC deferred'}
Write-Host "[PASS] CATS-R4 C candidate integration gate; artifacts: $OutputRoot"
