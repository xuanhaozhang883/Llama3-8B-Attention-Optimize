param([string]$IcarusRoot='C:\Software\iverilog')
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Build=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_drain_stress_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Build|Out-Null
try{
  $Vvp=Join-Path $Build 'sim.vvp'
  & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -s tb_cats_r4_a4_drain_stress -o $Vvp `
    (Join-Path $Root 'tb\tb_cats_r4_a4_untagged_sidecars.sv') `
    (Join-Path $Root 'tb\tb_cats_r4_a4_drain_stress.sv')
  if($LASTEXITCODE-ne 0){throw "A4 drain stress compile failed: $LASTEXITCODE"}
  $Output=& (Join-Path $IcarusRoot 'bin\vvp.exe') $Vvp 2>&1
  $Output|ForEach-Object{Write-Host $_}
  if($LASTEXITCODE-ne 0){throw "A4 drain stress simulation failed: $LASTEXITCODE"}
  $Marker='PASS A4 DRAIN STRESS channels=Q/K/V clusters=2 accepted=7 late_dropped=6 delivered=1 halt_blocks_new=1 exact_drain_gate=1 clear_after_empty=1'
  if(([regex]::Matches(($Output-join"`n"),[regex]::Escape($Marker))).Count-ne 1){
    throw 'A4 drain stress exact PASS marker mismatch'
  }
}finally{if(Test-Path -LiteralPath $Build){Remove-Item -LiteralPath $Build -Recurse -Force}}
