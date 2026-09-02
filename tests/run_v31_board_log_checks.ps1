param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

& python (Join-Path $ProjectRoot "tests\test_v31_board_log_signoff.py")
if ($LASTEXITCODE -ne 0) {
    throw "v3.1 board-log signoff unit checks failed"
}

Write-Host "[PASS] v3.1 board-log signoff checks passed."
