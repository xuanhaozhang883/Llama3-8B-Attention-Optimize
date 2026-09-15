param(
    [ValidateSet(1,2,4)] [int]$Clusters = 1,
    [ValidateSet(0,1)] [int]$Mode = 0,
    [uint32]$Seed = 3019898881,
    [ValidateSet('Model','A3Baseline','Unit','FullProtocol','RealIp','Ooc','All')]
    [string]$Suite = 'Model',
    [string]$OutputRoot,
    [ValidateRange(60,86400)] [int]$TimeoutSeconds = 3600,
    [string]$PythonExe = 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
    [string]$IcarusRoot = 'C:\Software\iverilog'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('cats_r4_a4_' + [guid]::NewGuid().ToString('N'))
} else {
    $OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
    if (Test-Path -LiteralPath $OutputRoot) {
        throw "OutputRoot must not already exist: $OutputRoot"
    }
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$Stdout = Join-Path $OutputRoot 'stdout.log'
$Stderr = Join-Path $OutputRoot 'stderr.log'
$SourceManifestPath = Join-Path $OutputRoot 'source_manifest.json'
$ProcessPath = Join-Path $OutputRoot 'process.json'
$StatusPath = Join-Path $OutputRoot 'run_status.json'
$ChildScript = Join-Path $OutputRoot 'run_suite.ps1'
$Started = [DateTime]::UtcNow
$Status = 'FAILED'
$ExitCode = $null
$TimedOut = $false
$ProcessId = $null

function Write-JsonFile([string]$Path, [object]$Value) {
    $Text = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $Text + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-TrackedSourceHashes {
    $RelativeFiles = @(
        & git -C $ProjectRoot ls-files -- 'rtl/**' 'tb/**' 'python/**' 'tests/**' 'scripts/**' 'mem/**' 'docs/CATS_R4_*'
    )
    $Entries = @()
    foreach ($Relative in $RelativeFiles) {
        $Path = Join-Path $ProjectRoot $Relative
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $Entries += [ordered]@{
                path = $Relative.Replace('\','/')
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
            }
        }
    }
    return $Entries
}

try {
    foreach ($Required in @($PythonExe, (Join-Path $ProjectRoot 'python\cats_r4_a4_scaling_model.py'))) {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) {
            throw "Required path does not exist: $Required"
        }
    }

    $Head = (& git -C $ProjectRoot rev-parse HEAD).Trim()
    $HeadTree = (& git -C $ProjectRoot rev-parse 'HEAD^{tree}').Trim()
    $Branch = (& git -C $ProjectRoot branch --show-current).Trim()
    $DirtyLines = @(& git -C $ProjectRoot status --porcelain=v1)
    $PythonVersion = (& $PythonExe --version 2>&1 | Out-String).Trim()
    $IverilogExe = Join-Path $IcarusRoot 'bin\iverilog.exe'
    $IverilogVersion = if (Test-Path -LiteralPath $IverilogExe) {
        (& $IverilogExe -V 2>&1 | Select-Object -First 1 | Out-String).Trim()
    } else { 'unavailable' }
    Write-JsonFile $SourceManifestPath ([ordered]@{
        schema = 'cats-r4-a4-source-manifest-v1'
        generated_utc = $Started.ToString('o')
        git = [ordered]@{
            branch = $Branch
            head = $Head
            head_tree = $HeadTree
            dirty = ($DirtyLines.Count -ne 0)
            status = $DirtyLines
        }
        configuration = [ordered]@{
            clusters = $Clusters
            mode = $Mode
            seed = [uint64]$Seed
            suite = $Suite
            timeout_seconds = $TimeoutSeconds
        }
        tools = [ordered]@{
            python = $PythonVersion
            iverilog = $IverilogVersion
        }
        files = @(Get-TrackedSourceHashes)
    })

    if ($Suite -eq 'Model') {
        $ModelOutput = Join-Path $OutputRoot 'model.json'
        $TestModel = Join-Path $ProjectRoot 'tests\test_cats_r4_a4_scaling_model.py'
        $TestReadiness = Join-Path $ProjectRoot 'tests\test_check_cats_r4_a4_readiness.py'
        $ModelScript = Join-Path $ProjectRoot 'python\cats_r4_a4_scaling_model.py'
        $ChildText = @"
`$ErrorActionPreference = 'Stop'
& '$PythonExe' '$TestModel'
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
& '$PythonExe' '$TestReadiness'
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
& '$PythonExe' '$ModelScript' | Set-Content -LiteralPath '$ModelOutput' -Encoding utf8
exit `$LASTEXITCODE
"@
    } elseif ($Suite -eq 'A3Baseline') {
        if ($Clusters -ne 1) { throw 'A3Baseline requires Clusters=1' }
        $A3Runner = Join-Path $ProjectRoot 'tests\run_cats_r4_a3_full_protocol_iverilog.ps1'
        $A3Output = Join-Path $OutputRoot 'a3_full_protocol'
        $ChildText = @"
`$ErrorActionPreference = 'Stop'
& '$A3Runner' -IcarusRoot '$IcarusRoot' -Mode $Mode -Seed $Seed -TimeoutSeconds $TimeoutSeconds -OutputRoot '$A3Output'
exit `$LASTEXITCODE
"@
    } else {
        $StageName = $Suite.ToLowerInvariant()
        $StageRunner = Join-Path $ProjectRoot "tests\run_cats_r4_a4_${StageName}.ps1"
        if (-not (Test-Path -LiteralPath $StageRunner -PathType Leaf)) {
            throw "A4 suite '$Suite' is not implemented yet; missing $StageRunner"
        }
        $StageOutput = Join-Path $OutputRoot $StageName
        $ChildText = @"
`$ErrorActionPreference = 'Stop'
& '$StageRunner' -Clusters $Clusters -Mode $Mode -Seed $Seed -TimeoutSeconds $TimeoutSeconds -OutputRoot '$StageOutput'
exit `$LASTEXITCODE
"@
    }

    [IO.File]::WriteAllText($ChildScript, $ChildText, [Text.UTF8Encoding]::new($false))
    $Process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ChildScript) `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden `
        -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    $ProcessId = $Process.Id
    Write-JsonFile $ProcessPath ([ordered]@{
        pid = $ProcessId
        started_utc = $Started.ToString('o')
        stage = $Suite
        stdout = $Stdout
        stderr = $Stderr
        checkpoint = $StatusPath
    })

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        $TimedOut = $true
        try { $Process.Kill($true) } catch { $Process.Kill() }
        $Process.WaitForExit()
    }
    $Process.Refresh()
    $ExitCode = $Process.ExitCode
    if ($TimedOut) { throw "A4 suite timed out after $TimeoutSeconds seconds" }
    if ($ExitCode -ne 0) { throw "A4 suite failed with exit code $ExitCode" }
    $Status = 'PASS'
} catch {
    $Failure = $_.Exception.Message
    Write-Error $Failure -ErrorAction Continue
} finally {
    $Ended = [DateTime]::UtcNow
    $Evidence = @()
    foreach ($Path in @($Stdout, $Stderr, $SourceManifestPath, (Join-Path $OutputRoot 'model.json'))) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $Evidence += [ordered]@{
                path = [IO.Path]::GetRelativePath($OutputRoot, $Path).Replace('\','/')
                bytes = (Get-Item -LiteralPath $Path).Length
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
            }
        }
    }
    Write-JsonFile $StatusPath ([ordered]@{
        schema = 'cats-r4-a4-run-status-v1'
        status = $Status
        suite = $Suite
        clusters = $Clusters
        mode = $Mode
        seed = [uint64]$Seed
        pid = $ProcessId
        exit_code = $ExitCode
        timed_out = $TimedOut
        started_utc = $Started.ToString('o')
        ended_utc = $Ended.ToString('o')
        runtime_seconds = ($Ended - $Started).TotalSeconds
        error = $Failure
        evidence = $Evidence
    })
    Write-Host "EVIDENCE_DIR=$OutputRoot"
}

if ($Status -ne 'PASS') { exit 1 }
Write-Host "PASS CATS-R4 A4 suite=$Suite clusters=$Clusters mode=$Mode seed=$Seed"
