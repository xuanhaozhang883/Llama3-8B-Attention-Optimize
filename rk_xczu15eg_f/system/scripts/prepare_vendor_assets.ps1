param(
    [Parameter(Mandatory = $true)]
    [string]$VendorRoot,

    [string]$OutputRoot = (
        Join-Path (Split-Path -Parent $PSScriptRoot) 'generated\vendor_cache'
    )
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fpgaArchive = Join-Path $VendorRoot `
    '3_source_code\RIGUKE-ZU15EG-FPGA-DEMO.zip'
$vitisArchive = Join-Path $VendorRoot `
    '3_source_code\RIGUKE-ZU15EG-VITIS-DEMO_V0.1.zip'
$factoryCandidates = @(
    Get-ChildItem -LiteralPath $VendorRoot -Recurse -File `
        -Filter 'vivado.zip'
)
if ($factoryCandidates.Count -ne 1) {
    throw (
        'Expected exactly one factory vivado.zip below VendorRoot; found ' +
        $factoryCandidates.Count
    )
}
$factoryArchive = $factoryCandidates[0].FullName

foreach ($archive in @($fpgaArchive, $vitisArchive, $factoryArchive)) {
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "Required vendor archive is missing: $archive"
    }
}

function Expand-ExactZipEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Entry,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $item = $zip.GetEntry($Entry)
        if ($null -eq $item) {
            throw "Archive entry is missing: $Entry"
        }
        $parent = Split-Path -Parent $Destination
        $null = New-Item -ItemType Directory -Path $parent -Force
        $inputStream = $item.Open()
        try {
            $outputStream = [System.IO.File]::Open(
                $Destination,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
            }
        }
        finally {
            $inputStream.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }
}

$assets = @(
    @{
        Archive = $vitisArchive
        Entry = 'RIGUKE-ZU15EG-VITIS-DEMO_V0.1/XCZU15EG_Base_Config.tcl'
        Relative = 'ps/XCZU15EG_Base_Config.tcl'
        Purpose = 'Vendor PS DDR/MIO/peripheral preset'
    },
    @{
        Archive = $fpgaArchive
        Entry = '10_DDR4_TEST/ddr4_test.srcs/sources_1/ip/ddr4/ddr4.xci'
        Relative = 'pl_ddr_native/ddr4.xci'
        Purpose = 'Vendor native-interface PL DDR4 controller'
    },
    @{
        Archive = $fpgaArchive
        Entry = '10_DDR4_TEST/ddr4_test.srcs/constrs_1/new/pin.xdc'
        Relative = 'pl_ddr_native/pin.xdc'
        Purpose = 'Vendor PL DDR4 test constraints'
    },
    @{
        Archive = $fpgaArchive
        Entry = '10_DDR4_TEST/ddr4_test.srcs/sources_1/new/top.v'
        Relative = 'pl_ddr_native/top.v'
        Purpose = 'Vendor PL DDR4 test top'
    },
    @{
        Archive = $fpgaArchive
        Entry = '10_DDR4_TEST/ddr4_test.srcs/sources_1/new/mem_test.v'
        Relative = 'pl_ddr_native/mem_test.v'
        Purpose = 'Vendor PL DDR4 test controller'
    },
    @{
        Archive = $fpgaArchive
        Entry = '10_DDR4_TEST/ddr4_test.srcs/sources_1/new/mem_burst.v'
        Relative = 'pl_ddr_native/mem_burst.v'
        Purpose = 'Vendor PL DDR4 burst generator/checker'
    },
    @{
        Archive = $factoryArchive
        Entry = 'vivado/IMAGE_15EG/IMAGE_15EG.srcs/sources_1/bd/IMAGE_15EG/ip/IMAGE_15EG_ddr4_0_0/IMAGE_15EG_ddr4_0_0.xci'
        Relative = 'pl_ddr_axi/IMAGE_15EG_ddr4_0_0.xci'
        Purpose = 'Factory AXI-enabled PL DDR4 controller'
    },
    @{
        Archive = $factoryArchive
        Entry = 'vivado/IMAGE_15EG/IMAGE_15EG.srcs/constrs_1/new/IMAGE_15EG.xdc'
        Relative = 'pl_ddr_axi/IMAGE_15EG_full_board.xdc'
        Purpose = 'Factory full-board constraints; audit source only'
    },
    @{
        Archive = $factoryArchive
        Entry = 'vivado/IMAGE_15EG/IMAGE_15EG.srcs/sources_1/bd/IMAGE_15EG/IMAGE_15EG.bd'
        Relative = 'reference/IMAGE_15EG.bd'
        Purpose = 'Factory PS plus AXI PL-DDR Block Design'
    },
    @{
        Archive = $factoryArchive
        Entry = 'vivado/IMAGE_15EG/IMAGE_15EG_wrapper.xsa'
        Relative = 'reference/IMAGE_15EG_wrapper.xsa'
        Purpose = 'Factory reference XSA'
    }
)

$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$manifestAssets = @()
foreach ($asset in $assets) {
    $destination = Join-Path $OutputRoot $asset.Relative
    Expand-ExactZipEntry -Archive $asset.Archive `
        -Entry $asset.Entry -Destination $destination
    $file = Get-Item -LiteralPath $destination
    $manifestAssets += [ordered]@{
        relative_path = $asset.Relative.Replace('\', '/')
        purpose = $asset.Purpose
        source_archive = $asset.Archive
        source_entry = $asset.Entry
        bytes = $file.Length
        sha256 = (Get-FileHash -Algorithm SHA256 `
            -LiteralPath $destination).Hash
    }
}

$archiveManifest = @()
foreach ($archive in @($fpgaArchive, $vitisArchive, $factoryArchive)) {
    $file = Get-Item -LiteralPath $archive
    $archiveManifest += [ordered]@{
        path = $archive
        bytes = $file.Length
        sha256 = (Get-FileHash -Algorithm SHA256 `
            -LiteralPath $archive).Hash
    }
}

$manifest = [ordered]@{
    schema_version = 1
    board = 'RK-XCZU15EG-F V1.0'
    target_part = 'xczu15eg-ffvb1156-2-i'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    redistribution_notice = (
        'Generated cache is local-only. Check vendor redistribution terms ' +
        'before publishing any extracted file.'
    )
    archives = $archiveManifest
    assets = $manifestAssets
}
$manifestPath = Join-Path $OutputRoot 'vendor_assets_manifest.json'
$manifest | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Output "RK_VENDOR_ASSETS_READY=$OutputRoot"
Write-Output "RK_VENDOR_MANIFEST=$manifestPath"
