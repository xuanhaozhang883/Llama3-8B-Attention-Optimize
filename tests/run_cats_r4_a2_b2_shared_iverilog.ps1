param(
    [string]$IcarusRoot = "D:\iverilog\iverilog"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("cats_r4_a2_b2_shared_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Iverilog = Join-Path $IcarusRoot "bin\iverilog.exe"
$Vvp = Join-Path $IcarusRoot "bin\vvp.exe"

$Sources = @(
    "rtl\core\bc\qk\cats_r4_qk_ab_handoff.sv",
    "rtl\core\bc\softmax\exp_lut.sv",
    "rtl\core\bc\softmax\unsigned_restoring_divider.sv",
    "rtl\core\bc\softmax\cats_r4_row_softmax_compatibility.sv",
    "rtl\core\bc\softmax\cats_r4_b2_compatibility_core_adapter.sv",
    "rtl\core\bc\softmax\cats_r4_accuracy_exp_fixed.sv",
    "rtl\core\bc\softmax\cats_r4_fp32_positive_add.sv",
    "rtl\core\bc\softmax\cats_r4_fp32_row_reciprocal.sv",
    "rtl\core\bc\softmax\cats_r4_row_softmax_accuracy.sv",
    "rtl\core\bc\softmax\cats_r4_b2_locking_arbiter.sv",
    "rtl\core\bc\softmax\cats_r4_b2_weight_stager.sv",
    "rtl\core\bc\softmax\cats_r4_b2_shared_stager_v3_wrapper.sv",
    "tb\tb_cats_r4_a2_b2_compatibility_integration.sv"
) | ForEach-Object { Join-Path $ProjectRoot $_ }

try {
    foreach ($Mode in 0, 1) {
        $Snapshot = Join-Path $OutputRoot "a2_b2_shared_mode_$Mode.vvp"
        $Defines = @("-DCATS_R4_SHARED_INTEGRATION")
        if ($Mode -eq 1) {
            $Defines += "-DCATS_R4_ACCURACY_INTEGRATION"
        }
        & $Iverilog -g2012 $Defines `
            -s tb_cats_r4_a2_b2_compatibility_integration `
            -o $Snapshot $Sources
        if ($LASTEXITCODE -ne 0) {
            throw "CATS-R4 A2-to-B2 shared wrapper compile failed mode $Mode"
        }

        Push-Location $ProjectRoot
        try {
            & $Vvp $Snapshot
            if ($LASTEXITCODE -ne 0) {
                throw "CATS-R4 A2-to-B2 shared wrapper simulation failed mode $Mode"
            }
        } finally {
            Pop-Location
        }
    }

    Write-Host "[PASS] CATS-R4 actual A2 handoff to shared B2 wrapper modes 0/1"
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
