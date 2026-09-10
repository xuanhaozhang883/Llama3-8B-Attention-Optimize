param(
    [string]$IcarusRoot = 'C:\iverilog',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'
foreach ($Tool in @($Iverilog, $Vvp)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "Icarus tool not found: $Tool"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_c_unit_' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$ContractRoot = Join-Path $OutputRoot 'contract'
$ContractScript = Join-Path $PSScriptRoot 'run_cats_r4_c_contract_only.ps1'
& $ContractScript -IcarusRoot $IcarusRoot -OutputRoot $ContractRoot
if ($LASTEXITCODE -ne 0) {
    throw "C contract-only regression failed: $LASTEXITCODE"
}

$Cases = @(
    @{
        Name = 'async_fifo'; Top = 'tb_cats_r4_async_fifo'
        Sources = @('rtl\core\cluster\cats_r4_async_fifo.sv', 'tb\tb_cats_r4_async_fifo.sv')
        Marker = 'CATS-R4 async FIFO test: PASS'
    },
    @{
        Name = 'abort_drain'; Top = 'tb_cats_r4_abort_drain_controller'
        Sources = @(
            'rtl\core\cluster\cats_r4_abort_drain_controller.sv',
            'tb\tb_cats_r4_abort_drain_controller.sv'
        )
        Marker = 'PASS cats_r4_abort_drain_controller isolate/drain/clear/epoch/restart'
    },
    @{
        Name = 'axi_burst_splitter'; Top = 'tb_cats_r4_axi_burst_splitter'
        Sources = @('rtl\core\cluster\cats_r4_axi_burst_splitter.sv', 'tb\tb_cats_r4_axi_burst_splitter.sv')
        Marker = 'PASS cats_r4_axi_burst_splitter boundary/length/backpressure/error counters'
    },
    @{
        Name = 'cdc_reset'; Top = 'tb_cats_r4_cdc_reset'
        Sources = @(
            'rtl\core\cluster\cats_r4_reset_sync.sv',
            'rtl\core\cluster\cats_r4_reset_sequencer.sv',
            'rtl\core\cluster\cats_r4_gray_counter_snapshot.sv',
            'tb\tb_cats_r4_cdc_reset.sv'
        )
        Marker = 'PASS cats_r4_cdc_reset async-reset/ordered-release/gray-snapshot/backpressure'
    },
    @{
        Name = 'cluster_shell'; Top = 'tb_cats_r4_cluster_shell'
        Sources = @('rtl\core\cluster\cats_r4_cluster_shell.sv', 'tb\tb_cats_r4_cluster_shell.sv')
        Marker = 'PASS: cats_r4_cluster_shell contract smoke'
    },
    @{
        Name = 'dma_group_scheduler'; Top = 'tb_cats_r4_dma_group_scheduler'
        Sources = @(
            'rtl\core\cluster\cats_r4_axi_burst_splitter.sv',
            'rtl\core\cluster\cats_r4_dma_group_scheduler.sv',
            'tb\tb_cats_r4_dma_group_scheduler.sv'
        )
        Marker = 'PASS cats_r4_dma_group_scheduler prefetch/barrier/random-latency/error-stop'
    },
    @{
        Name = 'output_cdc'; Top = 'tb_cats_r4_output_cdc'
        Sources = @(
            'rtl\core\cluster\cats_r4_async_fifo.sv',
            'rtl\core\cluster\cats_r4_output_cdc.sv',
            'tb\tb_cats_r4_output_cdc.sv'
        )
        Marker = 'PASS cats_r4_output_cdc rows=4096+12 full/backpressure/wrap/reset payload-tag atomic'
    },
    @{
        Name = 'output_reorder'; Top = 'tb_cats_r4_output_reorder_serializer'
        Sources = @(
            'rtl\core\cluster\cats_r4_output_reorder_serializer.sv',
            'tb\tb_cats_r4_output_reorder_serializer.sv'
        )
        Marker = 'PASS: output reorder/serializer canonical order, stalls, counters'
    },
    @{
        Name = 'q_slab_dma'; Top = 'tb_cats_r4_q_slab_dma_controller'
        Sources = @(
            'rtl\core\cluster\cats_r4_axi_burst_splitter.sv',
            'rtl\core\cluster\cats_r4_q_slab_dma_controller.sv',
            'tb\tb_cats_r4_q_slab_dma_controller.sv'
        )
        Marker = 'PASS CATS_R4_IF_V2 Q DMA 256 descriptors/131072 beats/512 bursts'
    },
    @{
        Name = 'qkv_banked_mem'; Top = 'tb_cats_r4_qkv_banked_mem'
        Sources = @('rtl\core\cluster\cats_r4_qkv_banked_mem.sv', 'tb\tb_cats_r4_qkv_banked_mem.sv')
        Marker = 'PASS: CATS_R4_IF_V2 Q/KV ownership, 32 slabs, N+2/II1'
    },
    @{
        Name = 'slot_bank'; Top = 'tb_cats_r4_slot_bank'
        Sources = @('rtl\core\cluster\cats_r4_slot_bank.sv', 'tb\tb_cats_r4_slot_bank.sv')
        Marker = 'PASS cats_r4_slot_bank collision/owner/backpressure'
    },
    @{
        Name = 'weight_slot_mem'; Top = 'tb_cats_r4_weight_slot_mem'
        Sources = @(
            'rtl\core\cluster\cats_r4_weight_slot_mem.sv',
            'tb\tb_cats_r4_weight_slot_mem.sv'
        )
        Marker = 'PASS CATS_R4_IF_V3 weight slots rows=4096 writes=524288 reads=524288 N+2'
    }
)

foreach ($Case in $Cases) {
    $Image = Join-Path $OutputRoot ($Case.Name + '.vvp')
    $CompileLog = Join-Path $OutputRoot ($Case.Name + '.compile.log')
    $RuntimeLog = Join-Path $OutputRoot ($Case.Name + '.runtime.log')
    $Sources = $Case.Sources | ForEach-Object { Join-Path $ProjectRoot $_ }

    $CompileExit = 0
    try {
        $ErrorActionPreference = 'Continue'
        & $Iverilog -g2012 -Wall -s $Case.Top -o $Image @Sources 2>&1 |
            Tee-Object -FilePath $CompileLog | Out-Host
        $CompileExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($CompileExit -ne 0) {
        throw "$($Case.Name) compile failed: $CompileExit"
    }
    $RuntimeExit = 0
    try {
        $ErrorActionPreference = 'Continue'
        & $Vvp $Image 2>&1 | Tee-Object -FilePath $RuntimeLog | Out-Host
        $RuntimeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($RuntimeExit -ne 0) {
        throw "$($Case.Name) runtime failed: $RuntimeExit"
    }
    $Runtime = Get-Content -Raw -LiteralPath $RuntimeLog
    if (-not $Runtime.Contains($Case.Marker) -or $Runtime.Contains('FAIL:')) {
        throw "$($Case.Name) did not produce a clean PASS marker"
    }
}

Write-Host '[PASS] CATS-R4 C unit suite: 15 protocol/memory/DMA/CDC/output/reset/v3-weight cases'
Write-Host "[INFO] Logs: $OutputRoot"
