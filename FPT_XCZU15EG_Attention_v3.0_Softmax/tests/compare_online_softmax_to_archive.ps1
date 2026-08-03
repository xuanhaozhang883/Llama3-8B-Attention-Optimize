param(
    [string]$VivadoRoot = "D:\Vitis\2025.2\Vivado",
    [string]$BaselineArchive = ""
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BaselineArchive)) {
    $BaselineArchive = "$ProjectRoot.zip"
}
if (-not (Test-Path -LiteralPath $BaselineArchive -PathType Leaf)) {
    throw "Baseline source archive not found: $BaselineArchive"
}

$ArchiveRootName = Split-Path -Leaf $ProjectRoot
$ExtractRoot = Join-Path $ProjectRoot ".Xil\baseline_archive"
$BaselineRoot = Join-Path $ExtractRoot $ArchiveRootName
$DeliveredBaselineRoot = Join-Path $ExtractRoot "FPT_XCZU15EG_Attention_v2.6_Causal_DualTile"
$Testbench = Join-Path $ProjectRoot "tb\tb_softmax_equivalence_full_rows.sv"
$Xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$Xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$Xsim = Join-Path $VivadoRoot "bin\xsim.bat"
$ExpectedBaselineHash = "f82a506f0c45d4f849cf5de011edf84a28dcb0d241d3b1372bc7d6ad753c87af"

foreach ($Tool in @($Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "Vivado Simulator tool not found: $Tool"
    }
}

if (Test-Path -LiteralPath (Join-Path $DeliveredBaselineRoot "rtl\core\bc\softmax\softmax_bf16.sv")) {
    $BaselineRoot = $DeliveredBaselineRoot
} else {
    New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
    $ArchiveMembers = @(
        "$ArchiveRootName/rtl/core/bc/softmax/exp_lut.sv",
        "$ArchiveRootName/rtl/core/bc/softmax/unsigned_restoring_divider.sv",
        "$ArchiveRootName/rtl/core/bc/softmax/softmax_bf16.sv",
        "$ArchiveRootName/mem/exp_lut_q15.mem"
    )
    & tar -xf $BaselineArchive -C $ExtractRoot @ArchiveMembers
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract the archived baseline Softmax"
    }
}

$BaselineSoftmax = Join-Path $BaselineRoot "rtl\core\bc\softmax\softmax_bf16.sv"
$BaselineHash = (Get-FileHash -LiteralPath $BaselineSoftmax -Algorithm SHA256).Hash.ToLowerInvariant()
if ($BaselineHash -ne $ExpectedBaselineHash) {
    throw "Archived baseline Softmax hash mismatch: $BaselineHash"
}

$ArchivedLut = Join-Path $BaselineRoot "mem\exp_lut_q15.mem"
$CurrentLut = Join-Path $ProjectRoot "mem\exp_lut_q15.mem"
if ((Get-FileHash -LiteralPath $ArchivedLut -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $CurrentLut -Algorithm SHA256).Hash) {
    throw "Archived and current EXP LUT files differ"
}

function Invoke-VectorSimulation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SourceRoot
    )

    $SimulationRoot = Join-Path $ProjectRoot ".Xil\xsim_archive_compare_$Name"
    New-Item -ItemType Directory -Force -Path $SimulationRoot | Out-Null
    $MemLink = Join-Path $SimulationRoot "mem"
    if (-not (Test-Path -LiteralPath $MemLink)) {
        New-Item -ItemType Junction -Path $MemLink -Target (Join-Path $ProjectRoot "mem") | Out-Null
    }

    $Sources = @(
        (Join-Path $SourceRoot "rtl\core\bc\softmax\exp_lut.sv"),
        (Join-Path $SourceRoot "rtl\core\bc\softmax\unsigned_restoring_divider.sv"),
        (Join-Path $SourceRoot "rtl\core\bc\softmax\softmax_bf16.sv"),
        $Testbench
    )

    Push-Location $SimulationRoot
    try {
        & $Xvlog --sv --nolog @Sources | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado compilation failed for $Name"
        }
        & $Xelab --nolog tb_softmax_equivalence_full_rows -s eq_sim | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado elaboration failed for $Name"
        }
        $Output = & $Xsim eq_sim --runall --nolog 2>&1
        if (($LASTEXITCODE -ne 0) -or (($Output -join "`n") -notmatch "EQ_FULL_TEST: PASS")) {
            $Output | Write-Host
            throw "Vivado simulation failed for $Name"
        }
        return @($Output | Where-Object { $_ -match "^EQ_FULL r=" })
    } finally {
        Pop-Location
    }
}

$BaselineVectors = @(Invoke-VectorSimulation -Name "baseline" -SourceRoot $BaselineRoot)
$OnlineVectors = @(Invoke-VectorSimulation -Name "online" -SourceRoot $ProjectRoot)
if (($BaselineVectors.Count -ne 1024) -or ($OnlineVectors.Count -ne 1024)) {
    throw "Unexpected vector count: baseline=$($BaselineVectors.Count), online=$($OnlineVectors.Count)"
}

$Difference = Compare-Object `
    -ReferenceObject $BaselineVectors `
    -DifferenceObject $OnlineVectors `
    -SyncWindow 0
if ($Difference) {
    $Difference | Select-Object -First 30 | Format-Table | Out-Host
    throw "Online Softmax output differs from the archived baseline"
}

Write-Host "[PASS] 1024/1024 full-row Vivado XSIM outputs are bit-exact against the archived Softmax."
