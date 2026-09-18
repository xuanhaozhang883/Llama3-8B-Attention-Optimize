$ErrorActionPreference = 'Stop'

$outputRoot = Join-Path $PSScriptRoot 'output'
$manifest = Join-Path $outputRoot 'D_OUTPUT_SHA256_MANIFEST_2026-09-12.json'
$files = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File |
    Where-Object { $_.FullName -ne $manifest } |
    Sort-Object FullName)

$entries = foreach ($file in $files) {
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($outputRoot, $file.FullName).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

$document = [ordered]@{
    schema = 'cats-r4-d-output-manifest/v2'
    generated = '2026-09-12'
    hash_algorithm = 'SHA-256'
    self_excluded = $true
    file_count = $files.Count
    files = @($entries)
}

$document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding utf8
Write-Output "D/output manifest files=$($files.Count)"
