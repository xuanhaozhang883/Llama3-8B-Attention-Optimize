param(
    [string]$VivadoRoot = 'C:\Software\AMD\vivado25.2\2025.2\Vivado',
    [string]$OutputRoot = ''
)
$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot=Join-Path ([IO.Path]::GetTempPath()) `
        ('cats_r4_a2_row_pipeline_'+[guid]::NewGuid().ToString('N'))
}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw "OutputRoot exists: $OutputRoot"}
New-Item -ItemType Directory -Path $OutputRoot|Out-Null
$Sources=@(
    'tb\tb_qk_fp32_mocks.sv',
    'rtl\core\bc\qk\fp32_to_bf16.v',
    'rtl\core\bc\qk\cats_r4_qk_score_formatter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_assembler.sv',
    'rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv',
    'rtl\core\bc\qk\cats_r4_qk_slot_lifecycle.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_abort_arbiter.sv',
    'rtl\core\bc\qk\cats_r4_qk_row_handoff_wrapper.sv',
    'rtl\core\bc\qk\cats_r4_qk_a2_row_pipeline.sv',
    'tb\tb_cats_r4_qk_a2_row_pipeline.sv'
)|ForEach-Object{Join-Path $ProjectRoot $_}
Push-Location $OutputRoot
try {
    & (Join-Path $VivadoRoot 'bin\xvlog.bat') -sv @Sources
    if($LASTEXITCODE-ne 0){throw "xvlog failed: $LASTEXITCODE"}
    & (Join-Path $VivadoRoot 'bin\xelab.bat') tb_cats_r4_qk_a2_row_pipeline -s a2_row_pipeline
    if($LASTEXITCODE-ne 0){throw "xelab failed: $LASTEXITCODE"}
    $Runtime=& (Join-Path $VivadoRoot 'bin\xsim.bat') a2_row_pipeline -runall 2>&1
    $Runtime|ForEach-Object{Write-Host $_}
    if($LASTEXITCODE-ne 0-or-not(($Runtime-join "`n").Contains(
        'PASS: CATS-R4 A2 raw FP32 through BF16 RNE row/max A-to-B pipeline'))) {
        throw 'A2 row pipeline PASS marker missing'
    }
} finally {Pop-Location}
Write-Host '[PASS] CATS-R4 A2 raw-score row handoff XSim regression'
