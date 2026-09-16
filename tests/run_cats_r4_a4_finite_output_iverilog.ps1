param([string]$IcarusRoot='C:\Software\iverilog')
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Build=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_finite_output_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Build | Out-Null
try {
    $Vvp=Join-Path $Build 'sim.vvp'
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -s tb_cats_r4_a4_finite_output -o $Vvp `
      (Join-Path $Root 'tb\tb_cats_r4_a4_finite_output_model.sv') `
      (Join-Path $Root 'tb\tb_cats_r4_a4_finite_output.sv')
    if($LASTEXITCODE-ne 0){throw "A4 finite output compile failed: $LASTEXITCODE"}
    $Output=& (Join-Path $IcarusRoot 'bin\vvp.exe') $Vvp 2>&1
    $Output|ForEach-Object{Write-Host $_}
    if($LASTEXITCODE-ne 0){throw "A4 finite output simulation failed: $LASTEXITCODE"}
    $Marker='PASS A4 FINITE OUTPUT clusters=2 rows_per_cluster=512 chunks_per_spool=2048 shared_sink_bits=64 beats_per_chunk=8 local_full_isolation=1 halt=1 clear=1'
    if(([regex]::Matches(($Output-join"`n"),[regex]::Escape($Marker))).Count-ne 1){
        throw 'A4 finite output exact PASS marker mismatch'
    }
} finally {
    if(Test-Path -LiteralPath $Build){Remove-Item -LiteralPath $Build -Recurse -Force}
}
