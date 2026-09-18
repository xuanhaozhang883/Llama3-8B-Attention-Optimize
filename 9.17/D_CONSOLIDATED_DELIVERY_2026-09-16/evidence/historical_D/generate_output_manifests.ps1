$ErrorActionPreference = 'Stop'

$dRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $PSScriptRoot 'output'
$d3Root = Join-Path $outputRoot 'D3_COMPLETE_BRANCH_ABLATION_2026-09-10'
$innerManifest = Join-Path $d3Root 'manifests\D3_DELIVERY_SHA256_2026-09-10.txt'
$outerManifest = Join-Path $outputRoot 'D_OUTPUT_SHA256_MANIFEST_2026-09-10.json'

$innerFiles = @(Get-ChildItem -LiteralPath $d3Root -Recurse -File |
    Where-Object { $_.FullName -ne $innerManifest } |
    Sort-Object FullName)
$innerLines = @(
    'schema=cats-r4-d3-delivery-sha256/v1'
    'generated=2026-09-10'
    'hash_algorithm=SHA-256'
    'self_excluded=true'
    "file_count=$($innerFiles.Count)"
)
foreach ($file in $innerFiles) {
    $relative = [System.IO.Path]::GetRelativePath($d3Root, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $innerLines += "$hash  $($file.Length)  $relative"
}
$innerLines | Set-Content -LiteralPath $innerManifest -Encoding utf8

$outerFiles = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File |
    Where-Object { $_.FullName -ne $outerManifest } |
    Sort-Object FullName)
$entries = foreach ($file in $outerFiles) {
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($outputRoot, $file.FullName).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}
$document = [ordered]@{
    schema = 'cats-r4-d-output-manifest/v1'
    generated = '2026-09-10'
    hash_algorithm = 'SHA-256'
    self_excluded = $true
    file_count = $outerFiles.Count
    files = @($entries)
}
$document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outerManifest -Encoding utf8

Write-Output "D3 manifest files=$($innerFiles.Count)"
Write-Output "D/output manifest files=$($outerFiles.Count)"
