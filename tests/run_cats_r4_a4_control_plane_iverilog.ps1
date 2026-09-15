param([string]$IcarusRoot='C:\Software\iverilog')
$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_control_plane_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
try {
    $Snapshot=Join-Path $OutputRoot 'control_plane.vvp'
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -s tb_cats_r4_a4_control_plane -o $Snapshot `
      (Join-Path $ProjectRoot 'rtl\core\bc\integration\cats_r4_a4_txn_fanout.sv') `
      (Join-Path $ProjectRoot 'rtl\core\bc\integration\cats_r4_a4_group_job_adapter.sv') `
      (Join-Path $ProjectRoot 'tb\tb_cats_r4_a4_control_plane.sv')
    if($LASTEXITCODE-ne 0){throw 'A4 control-plane compile failed'}
    $Runtime=& (Join-Path $IcarusRoot 'bin\vvp.exe') $Snapshot 2>&1
    $Runtime|ForEach-Object{Write-Host $_}
    if($LASTEXITCODE-ne 0-or-not(($Runtime-join"`n").Contains('PASS A4 CONTROL PLANE')))
        {throw 'A4 control-plane PASS marker missing'}
} finally {
    if(Test-Path -LiteralPath $OutputRoot){Remove-Item -LiteralPath $OutputRoot -Recurse -Force}
}
