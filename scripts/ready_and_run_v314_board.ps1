[CmdletBinding()]
param(
    [string]$Root = 'D:\fpt_gui\v314',
    [string]$Port = '',
    [string]$XsctPath = 'E:\vivado_25_2\2025.2\Vitis\bin\xsct.bat',
    [string]$PythonPath = 'python',
    [int]$TimeoutSeconds = 300,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing required file: $Path"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actual -ne $Expected) {
        throw "SHA-256 mismatch: $Path`nExpected: $Expected`nActual:   $actual"
    }
    Write-Host "[PASS] SHA-256 $([IO.Path]::GetFileName($Path)) = $actual"
}

function Start-XsctProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )
    Start-Process -FilePath $XsctPath -ArgumentList $Arguments `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
}

$artifactDir = Join-Path $Root 'artifacts'
$toolDir = Join-Path $Root 'tools'
$logDir = Join-Path $Root 'logs'
$bit = Join-Path $artifactDir 'fpt_attention_board_v314_qk4_causal_bypass.bit'
$xsa = Join-Path $artifactDir 'fpt_attention_board_v314_qk4_causal_bypass.xsa'
$elf = Join-Path $artifactDir 'fpt_attention_test.elf'
$psuInit = Join-Path $artifactDir 'psu_init.tcl'
$probeScript = Join-Path $toolDir 'probe_board_xsct.tcl'
$runScript = Join-Path $toolDir 'run_on_board_no_gtr_xsct.tcl'
$projectConfig = Join-Path $toolDir 'project_config.tcl'
$signoffScript = Join-Path $toolDir 'signoff_v31_board_log.py'

Write-Host '============================================================'
Write-Host 'FPT v3.1.4 board package preflight'
Write-Host "Root: $Root"
Write-Host '============================================================'

if (-not (Test-Path -LiteralPath $XsctPath -PathType Leaf)) {
    throw "XSCT 2025.2 not found: $XsctPath"
}
foreach ($requiredTool in @($probeScript, $runScript, $projectConfig, $signoffScript)) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        throw "Missing board-package tool: $requiredTool"
    }
}

Assert-FileHash $bit '1C2B74DD7E2FA31C0EBE4AA991BC3B278A837525987A3BA975ACAD601B0A83D5'
Assert-FileHash $xsa 'DD878BF6AC48D33F61BD7E504B550B29B869476253AD7DB6325F793A8E86A2EB'
Assert-FileHash $elf 'EA4FBEDAC06227F71B7C5B2A2F858EE3AA8E6511EDCCE8A34AAB38D3720E39A8'
Assert-FileHash $psuInit '45DD3395F99B90C0C705BDBA9D74D999A0ECDBD8542924407C4C5C575E904EDF'

if ($PrepareOnly) {
    Write-Host '[PASS] Offline preparation is complete; no board operation was attempted.'
    return
}

if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$probeOut = Join-Path $logDir "probe_$stamp.stdout.log"
$probeErr = Join-Path $logDir "probe_$stamp.stderr.log"
$probe = Start-XsctProcess -Arguments @($probeScript) -StdoutPath $probeOut -StderrPath $probeErr
$probe.WaitForExit()
$probeText = ((Get-Content -LiteralPath $probeOut -Raw -ErrorAction SilentlyContinue) +
    (Get-Content -LiteralPath $probeErr -Raw -ErrorAction SilentlyContinue))
Write-Host $probeText
if ($probe.ExitCode -ne 0 -or $probeText -notmatch '\[PASS\] At least one JTAG target is visible') {
    throw 'JTAG probe failed. Connect board power and JTAG, select JTAG boot mode, then retry.'
}

$availablePorts = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
if (-not $Port) {
    if ($availablePorts.Count -ne 1) {
        throw "Specify -Port when the system has zero or multiple serial ports. Available: $($availablePorts -join ', ')"
    }
    $Port = $availablePorts[0]
}
if ($availablePorts -notcontains $Port) {
    throw "Serial port $Port is not present. Available: $($availablePorts -join ', ')"
}

$uartLog = Join-Path $logDir "v314_board_$stamp.log"
$xsctOut = Join-Path $logDir "download_$stamp.stdout.log"
$xsctErr = Join-Path $logDir "download_$stamp.stderr.log"
$signoffJson = Join-Path $logDir "v314_board_signoff_$stamp.json"
$signoffMd = Join-Path $logDir "v314_board_signoff_$stamp.md"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($uartLog, $false, $utf8)
$writer.AutoFlush = $true
$serial = [System.IO.Ports.SerialPort]::new(
    $Port, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One)
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.ReadTimeout = 100
$serialText = [System.Text.StringBuilder]::new()
$download = $null

try {
    $serial.Open()
    Write-Host "[PASS] Capturing $Port at 115200 8N1 -> $uartLog"
    $download = Start-XsctProcess `
        -Arguments @($runScript, $psuInit, $elf, $bit) `
        -StdoutPath $xsctOut -StderrPath $xsctErr
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $finalPass = '[PASS] v3.1 FlashAttention ten-run correctness and profiling passed'

    while ([DateTime]::UtcNow -lt $deadline) {
        $chunk = $serial.ReadExisting()
        if ($chunk.Length -gt 0) {
            $writer.Write($chunk)
            [Console]::Write($chunk)
            [void]$serialText.Append($chunk)
        } else {
            Start-Sleep -Milliseconds 50
        }
        $captured = $serialText.ToString()
        if ($captured.Contains($finalPass)) {
            Start-Sleep -Milliseconds 500
            $tail = $serial.ReadExisting()
            if ($tail.Length -gt 0) {
                $writer.Write($tail)
                [Console]::Write($tail)
                [void]$serialText.Append($tail)
            }
            break
        }
        if ($captured.Contains('[FAIL]')) {
            throw 'The board application reported [FAIL]; raw UART output was preserved.'
        }
        if ($download.HasExited -and $download.ExitCode -ne 0) {
            throw "XSCT download failed with exit code $($download.ExitCode)."
        }
    }
    if (-not $serialText.ToString().Contains($finalPass)) {
        throw "Timed out after $TimeoutSeconds seconds waiting for the final PASS marker."
    }
} finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
    $writer.Dispose()
    if ($null -ne $download) {
        if (-not $download.HasExited) { $download.WaitForExit(10000) | Out-Null }
        if ($download.HasExited) {
            $downloadText = ((Get-Content -LiteralPath $xsctOut -Raw -ErrorAction SilentlyContinue) +
                (Get-Content -LiteralPath $xsctErr -Raw -ErrorAction SilentlyContinue))
            Write-Host $downloadText
        }
    }
}

& $PythonPath $signoffScript $uartLog --profile v314-causal-bypass `
    --json $signoffJson --markdown $signoffMd
if ($LASTEXITCODE -ne 0) {
    throw "Board log signoff failed with exit code $LASTEXITCODE."
}
$logHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $uartLog).Hash
Write-Host '============================================================'
Write-Host '[PASS] v3.1.4 board download, ten-run test, and signoff passed'
Write-Host "UART log: $uartLog"
Write-Host "Log SHA-256: $logHash"
Write-Host "Signoff JSON: $signoffJson"
Write-Host "Signoff Markdown: $signoffMd"
Write-Host '============================================================'
