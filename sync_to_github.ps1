# sync_to_github.ps1
# Run in repository root: .\sync_to_github.ps1 [-Auto]
# -Auto: non-interactive mode, use default commit message and will not auto force-push

param(
    [switch]$Auto
)

Set-StrictMode -Version Latest

# If needed, set to your repo path; normally run from repo root
$RepoPath = ""
if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
  Set-Location $RepoPath
}

# 确认在 git 仓库
# ensure we are at repo root
if (-not (Test-Path .git)) {
  Write-Host "Not a git repository root. Please cd to repo root and retry." -ForegroundColor Red
  exit 1
}

# 获取当前分支
$currentBranch = (& git rev-parse --abbrev-ref HEAD) 2>$null
# validate branch
if ($LASTEXITCODE -ne 0 -or -not $currentBranch) {
  Write-Host "Failed to determine current branch." -ForegroundColor Red
  exit 1
}
Write-Host "Current branch: $currentBranch"

# 确认 origin 是否存在
$originUrl = (& git remote get-url origin) 2>$null
# origin check
if ($LASTEXITCODE -ne 0) {
  Write-Host "Remote 'origin' not found." -ForegroundColor Yellow
  if ($Auto) {
    Write-Host "Non-interactive mode: origin not found, exiting." -ForegroundColor Red
    exit 1
  }
  $add = Read-Host "Enter remote URL to add (e.g. https://github.com/you/repo.git), leave empty to cancel:"
  if ([string]::IsNullOrWhiteSpace($add)) { Write-Host "Cancelled." ; exit 1 }
  & git remote add origin $add
  if ($LASTEXITCODE -ne 0) { Write-Host "Failed to add remote." -ForegroundColor Red; exit 1 }
  $originUrl = (& git remote get-url origin)
  Write-Host "Added origin: $originUrl"
} else {
  Write-Host "origin: $originUrl"
}

# fetch 最新
Write-Host "`nFetching origin..."
& git fetch origin
# fetch
if ($LASTEXITCODE -ne 0) { Write-Host "git fetch failed" -ForegroundColor Red; exit 1 }

# 暂存并提交本地改动（如果有）
Write-Host "`nStaging all changes..."
& git add .
# stage
if ($LASTEXITCODE -ne 0) { Write-Host "git add failed" -ForegroundColor Red; exit 1 }

# 检查是否需要提交（是否有 staged 变更）
& git diff --cached --quiet
$stagedHasChanges = $LASTEXITCODE -ne 0
if ($stagedHasChanges) {
  $defaultMsg = "chore: sync local workspace at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  if ($Auto) {
    $msg = $defaultMsg
    Write-Host "Auto commit message: $msg"
  } else {
    $msg = Read-Host "Enter commit message (enter to use default): $defaultMsg"
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $defaultMsg }
  }
  & git commit -m "$msg"
  if ($LASTEXITCODE -ne 0) { Write-Host "git commit failed" -ForegroundColor Red; exit 1 }
  Write-Host "Committed: $msg"
} else {
  Write-Host "No changes to commit."
}

# 展示本地 vs 远端 提前/落后情况
Write-Host "`nLocal vs origin summary:"
& git fetch origin
& git status --branch --porcelain

# 尝试 rebase origin/<branch>
Write-Host "`nAttempting to rebase origin/$currentBranch onto local..."
& git rebase origin/$currentBranch
if ($LASTEXITCODE -eq 0) {
  Write-Host "rebase succeeded." -ForegroundColor Green
} else {
  Write-Host "rebase failed, possible conflicts." -ForegroundColor Yellow
  Write-Host "Open conflict files in your editor and resolve, then run:" 
  Write-Host "  git add <resolved-files>"
  Write-Host "  git rebase --continue"
  Write-Host "After successful rebase, run: git push origin $currentBranch"
  exit 1
}

# 推送
Write-Host "`nAttempting to push to origin/$currentBranch ..."
& git push origin $currentBranch
if ($LASTEXITCODE -eq 0) {
  Write-Host "Push succeeded" -ForegroundColor Green
  exit 0
}

Write-Host "Normal push was rejected or failed." -ForegroundColor Yellow
if ($Auto) {
  Write-Host "Non-interactive mode will not force-push. Please inspect and decide about --force-with-lease." -ForegroundColor Yellow
  exit 1
}

$yn = Read-Host "Use 'git push --force-with-lease origin $currentBranch' to overwrite remote with local (this will rewrite remote history)? [y/N]"
if ($yn -match '^[Yy]') {
  & git push --force-with-lease origin $currentBranch
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Force push succeeded (--force-with-lease)" -ForegroundColor Green
    exit 0
  } else {
    Write-Host "Force push failed, check remote status or network." -ForegroundColor Red
    exit 1
  }
} else {
  Write-Host "Force push cancelled. Inspect and merge remote changes manually." -ForegroundColor Yellow
  exit 1
}
