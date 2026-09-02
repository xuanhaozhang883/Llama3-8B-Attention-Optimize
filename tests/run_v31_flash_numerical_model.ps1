param(
    [int]$Cases = 64,
    [int]$SequenceLength = 128,
    [int]$HeadDimension = 128,
    [int]$Tile = 4,
    [int]$AllowedMaxUlp = 1,
    [switch]$FullGqa,
    [string]$ResultPath = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ResultName = if ($FullGqa) {
    "v31_flash_full_gqa_numerical.json"
} else {
    "v31_flash_numerical_model.json"
}
$Result = if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    Join-Path $ProjectRoot "reports\$ResultName"
} else {
    [IO.Path]::GetFullPath($ResultPath)
}
$ModelArgs = @(
    "--cases", $Cases,
    "--length", $SequenceLength,
    "--dimension", $HeadDimension,
    "--tile", $Tile,
    "--json", $Result,
    "--require-reference-max-ulp", $AllowedMaxUlp
)
if ($FullGqa) {
    $ModelArgs += @("--full-board", "--rtl-exact-only")
}

& python (Join-Path $ProjectRoot "python\flash_attention_tile_model.py") `
    @ModelArgs
if ($LASTEXITCODE -ne 0) {
    throw "v3.1 FlashAttention numerical model failed"
}

Write-Host "[PASS] v3.1 numerical report: $Result"
