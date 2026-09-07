param(
    [string]$IcarusRoot = 'C:\iverilog',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'
foreach ($Path in @($Iverilog, $Vvp)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Icarus tool not found: $Path"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) 'cats_r4_c_contract_only'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "OutputRoot must not already exist: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

function Invoke-IcarusCase {
    param(
        [string]$Name,
        [string]$Top,
        [string[]]$Sources,
        [string[]]$Defines = @()
    )
    $SavedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $Image = Join-Path $OutputRoot ($Name + '.vvp')
    $CompileLog = Join-Path $OutputRoot ($Name + '.compile.log')
    $RuntimeLog = Join-Path $OutputRoot ($Name + '.runtime.log')
    $Args = @('-g2012', '-Wall')
    foreach ($Define in $Defines) { $Args += ('-D' + $Define) }
    $Args += @('-s', $Top, '-o', $Image)
    $Args += $Sources | ForEach-Object { Join-Path $ProjectRoot $_ }
    & $Iverilog @Args 2>&1 | Tee-Object -FilePath $CompileLog | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Name compile failed: $LASTEXITCODE" }
    & $Vvp $Image 2>&1 | Tee-Object -FilePath $RuntimeLog | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Name runtime failed: $LASTEXITCODE" }
    $Result = Get-Content -Raw -LiteralPath $RuntimeLog
    $ErrorActionPreference = $SavedErrorActionPreference
    return $Result
}

$BridgeLog = Invoke-IcarusCase `
    -Name 'qkv_axi_bank_bridge_protocol' `
    -Top 'tb_cats_r4_qkv_axi_bank_bridge' `
    -Defines @('CATS_R4_PROTOCOL_ONLY') `
    -Sources @(
        'rtl\core\cluster\cats_r4_qkv_axi_bank_bridge.sv',
        'tb\tb_cats_r4_qkv_axi_bank_bridge.sv'
    )
if (-not $BridgeLog.Contains('TOKEN_MISMATCH_GATE_DONE') -or
    -not $BridgeLog.Contains('PASS: CATS-R4 AXI/core bank bridge descriptors and counters')) {
    throw 'bridge contract-only PASS markers missing'
}

$BridgeReadbackLog = Invoke-IcarusCase `
    -Name 'qkv_axi_bank_bridge_readback' `
    -Top 'tb_cats_r4_qkv_axi_bank_bridge' `
    -Sources @(
        'tb\xpm_memory_sdpram_model.sv',
        'rtl\core\cluster\cats_r4_qkv_axi_bank_bridge.sv',
        'tb\tb_cats_r4_qkv_axi_bank_bridge.sv'
    )
if (-not $BridgeReadbackLog.Contains('PASS: CATS-R4 AXI/core bank bridge descriptors, counters, and readback')) {
    throw 'bridge readback PASS marker missing'
}

$BankLog = Invoke-IcarusCase `
    -Name 'qkv_banked_mem_mapping' `
    -Top 'tb_cats_r4_axi64_qkv_banked_mem' `
    -Sources @(
        'rtl\core\cluster\cats_r4_axi64_qkv_banked_mem.sv',
        'tb\tb_cats_r4_axi64_qkv_banked_mem.sv'
    )
if (-not $BankLog.Contains('PASS CATS_R4 AXI64 Q/K/V dual-clock bank expansion')) {
    throw 'bank mapping PASS marker missing'
}

Write-Host '[PASS] CATS-R4 C contract-only protocol, reset/token, and bank mapping checks'
