<#
.SYNOPSIS
Deletes completed or stale markdown locks after a retention window.

.DESCRIPTION
Never deletes in-progress locks. By default, completed and stale locks older
than 6 hours are deleted so stale lock bodies do not keep surfacing in agent
searches. Locks with `keep: true` are reported and preserved. Use
-MarkExpiredActiveStale to turn expired in-progress locks stale after an
additional grace window.
#>
param(
    [string]$LockRoot = "Logs/AgentLocks",
    [ValidateRange(1, 8760)]
    [int]$RetentionHours = 6,
    [ValidateRange(1, 10080)]
    [int]$ExpiredActiveGraceMinutes = 240,
    [switch]$MarkExpiredActiveStale,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "AgentLock.Common.ps1")

$repoRoot = Resolve-AgentLockRepositoryRoot
$lockRootPath = Resolve-AgentLockRoot -RepoRoot $repoRoot -LockRoot $LockRoot
$now = Get-Date
$cutoff = $now.AddHours(-1 * $RetentionHours)

if (-not (Test-Path -LiteralPath $lockRootPath)) {
    throw "Lock root does not exist: $lockRootPath"
}

$reports = @()
$lockFiles = Get-ChildItem -LiteralPath $lockRootPath -File -Filter "*.md" |
    Where-Object { $_.Name -ne "README.md" }

foreach ($file in $lockFiles) {
    $lock = Read-AgentLock -Path $file.FullName
    if ($null -eq $lock) {
        continue
    }

    $status = ""
    if ($lock.PSObject.Properties.Name -contains "status") {
        $status = $lock.status
    }

    if ($status -eq "in_progress") {
        if (Test-AgentLockExpired -Lock $lock -Now $now) {
            $expiresAt = Get-AgentLockExpiresAt -Lock $lock
            $staleEligible = ($null -ne $expiresAt) -and ($expiresAt.AddMinutes($ExpiredActiveGraceMinutes) -le $now)

            if ($MarkExpiredActiveStale -and $staleEligible -and -not (Test-AgentLockKept -Lock $lock)) {
                if (-not $DryRun) {
                    $files = @()
                    if ($lock.PSObject.Properties.Name -contains "files") {
                        $files = @($lock.files)
                    }

                    $subagent = ""
                    if ($lock.PSObject.Properties.Name -contains "subagent") {
                        $subagent = $lock.subagent
                    }

                    $threadId = ""
                    if ($lock.PSObject.Properties.Name -contains "threadId") {
                        $threadId = $lock.threadId
                    }

                    $mode = Get-AgentLockMode -Lock $lock

                    Write-AgentLockFile `
                        -Path $file.FullName `
                        -Agent $lock.agent `
                        -Subagent $subagent `
                        -ThreadId $threadId `
                        -Scope $lock.scope `
                        -Task $lock.task `
                        -StartedAt $lock.startedAt `
                        -UpdatedAt $now.ToString("o") `
                        -Status "stale" `
                        -Mode $mode `
                        -Files $files `
                        -Loop "Marked stale by Clear-CompletedLocks after TTL plus $ExpiredActiveGraceMinutes minute grace."
                }

                $reports += New-AgentLockReport -Ok $true -Action "mark-expired-active-stale" -Path $file.FullName -ExistingLock $lock -Message "Expired in-progress lock exceeded the $ExpiredActiveGraceMinutes minute grace window and was marked stale."
                continue
            }

            $reports += New-AgentLockReport -Ok $true -Action "keep-expired-active" -Path $file.FullName -ExistingLock $lock -Message "In-progress lock TTL has expired; refresh if this thread is active, or rerun cleanup with -MarkExpiredActiveStale after confirming it is dead."
            continue
        }

        $reports += New-AgentLockReport -Ok $true -Action "keep-active" -Path $file.FullName -ExistingLock $lock -Message "In-progress locks are never pruned."
        continue
    }

    if ($status -ne "completed" -and $status -ne "stale") {
        $reports += New-AgentLockReport -Ok $true -Action "skip-unknown" -Path $file.FullName -ExistingLock $lock -Message "Unknown status '$status' was not pruned."
        continue
    }

    if (Test-AgentLockKept -Lock $lock) {
        $reports += New-AgentLockReport -Ok $true -Action "keep-marked" -Path $file.FullName -ExistingLock $lock -Message "Lock has keep: true."
        continue
    }

    $updated = Get-AgentLockUpdatedAt -Lock $lock
    if ($null -eq $updated) {
        $reports += New-AgentLockReport -Ok $true -Action "skip-unparsed-date" -Path $file.FullName -ExistingLock $lock -Message "updatedAt could not be parsed."
        continue
    }

    if ($updated -gt $cutoff) {
        $reports += New-AgentLockReport -Ok $true -Action "keep-recent" -Path $file.FullName -ExistingLock $lock -Message "Lock is newer than retention cutoff."
        continue
    }

    if (-not $DryRun) {
        Remove-Item -LiteralPath $file.FullName -Force
    }

    $reports += New-AgentLockReport -Ok $true -Action "prune" -Path $file.FullName -ExistingLock $lock -Message "Deleted lock older than $RetentionHours hours."
}

[pscustomobject][ordered]@{
    ok = $true
    dryRun = [bool]$DryRun
    action = "clear-completed"
    lockRoot = $lockRootPath
    retentionHours = $RetentionHours
    expiredActiveGraceMinutes = $ExpiredActiveGraceMinutes
    markExpiredActiveStale = [bool]$MarkExpiredActiveStale
    cutoff = $cutoff.ToString("o")
    locks = $reports
} | ConvertTo-Json -Depth 8
