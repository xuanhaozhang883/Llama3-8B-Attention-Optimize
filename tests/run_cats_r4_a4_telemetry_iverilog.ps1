$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$IcarusRoot='C:\Software\iverilog'
$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_telemetry_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
try {
    $Snapshot=Join-Path $OutputRoot 'telemetry.vvp'
    & (Join-Path $IcarusRoot 'bin\iverilog.exe') -g2012 -s tb_cats_r4_a4_telemetry -o $Snapshot `
      (Join-Path $ProjectRoot 'rtl\core\bc\integration\cats_r4_a4_telemetry.sv') `
      (Join-Path $ProjectRoot 'tb\tb_cats_r4_a4_telemetry.sv')
    if($LASTEXITCODE-ne 0){throw 'A4 telemetry compile failed'}
    $Runtime=& (Join-Path $IcarusRoot 'bin\vvp.exe') $Snapshot 2>&1
    $Runtime|ForEach-Object{Write-Host $_}
    if($LASTEXITCODE-ne 0-or-not(($Runtime-join"`n").Contains('PASS A4 TELEMETRY')))
        {throw 'A4 telemetry PASS marker missing'}
} finally {
    if(Test-Path -LiteralPath $OutputRoot){Remove-Item -LiteralPath $OutputRoot -Recurse -Force}
}

