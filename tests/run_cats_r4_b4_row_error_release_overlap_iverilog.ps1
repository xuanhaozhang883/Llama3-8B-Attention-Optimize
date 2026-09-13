param(
    [string]$IcarusRoot = 'D:\iverilog\iverilog'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('cats_r4_b4_error_overlap_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$Snapshot = Join-Path $OutputRoot 'b4_error_overlap.vvp'
$Iverilog = Join-Path $IcarusRoot 'bin\iverilog.exe'
$Vvp = Join-Path $IcarusRoot 'bin\vvp.exe'
$Sources = @(
    'rtl\core\bc\pv\cats_r4_b3_pv_controller.sv',
    'tb\tb_cats_r4_b4_b2_protocol_model.sv',
    'tb\tb_cats_r4_b4_b3_protocol_model.sv',
    'rtl\core\bc\integration\cats_r4_b4_softmax_pv_cluster.sv',
    'tb\tb_cats_r4_b4_row_error_release_overlap.sv'
) | ForEach-Object { Join-Path $ProjectRoot $_ }

try {
    & $Iverilog -g2012 -s tb_cats_r4_b4_row_error_release_overlap `
        -o $Snapshot $Sources
    if ($LASTEXITCODE -ne 0) {
        throw 'CATS-R4 B4 row-error/release overlap compile failed'
    }
    & $Vvp $Snapshot
    if ($LASTEXITCODE -ne 0) {
        throw 'CATS-R4 B4 row-error/release overlap simulation failed'
    }
    Write-Host '[PASS] CATS-R4 B4 row-error/release overlap handshake regression'
} finally {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
