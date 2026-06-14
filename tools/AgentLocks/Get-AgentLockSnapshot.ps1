<#
.SYNOPSIS
Prints a compact JSON snapshot of the active agent locks.

.DESCRIPTION
This is a read-only helper for humans and session hooks. It summarizes active,
expired-active, and recently closed locks without pasting full lock bodies.
#>
param(
    [string]$LockRoot = "Logs/AgentLocks",
    [int]$MaxLocks = 12
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "AgentLock.Common.ps1")

$repoRoot = Resolve-AgentLockRepositoryRoot
$lockRootPath = Resolve-AgentLockRoot -RepoRoot $repoRoot -LockRoot $LockRoot
$now = Get-Date

if (-not (Test-Path -LiteralPath $lockRootPath)) {
    [pscustomobject]@{
        ok = $true
        lockRoot = $lockRootPath
        activeCount = 0
        exclusiveActiveCount = 0
        expiredActiveCount = 0
        closedCount = 0
        exclusiveActive = @()
        active = @()
        expiredActive = @()
    } | ConvertTo-Json -Depth 6
    return
}

function ConvertTo-SnapshotLock {
    param($Lock)

    $updated = Get-AgentLockUpdatedAt -Lock $Lock
    $expires = Get-AgentLockExpiresAt -Lock $Lock
    [pscustomobject][ordered]@{
        file = [IO.Path]::GetFileName($Lock.path)
        agent = if ($Lock.PSObject.Properties.Name -contains "agent") { $Lock.agent } else { "" }
        threadId = if ($Lock.PSObject.Properties.Name -contains "threadId") { $Lock.threadId } else { "" }
        scope = if ($Lock.PSObject.Properties.Name -contains "scope") { $Lock.scope } else { "" }
        status = if ($Lock.PSObject.Properties.Name -contains "status") { $Lock.status } else { "" }
        mode = Get-AgentLockMode -Lock $Lock
        task = if ($Lock.PSObject.Properties.Name -contains "task") { $Lock.task } else { "" }
        updatedAt = if ($null -ne $updated) { $updated.ToString("o") } else { "" }
        expiresAt = if ($null -ne $expires) { $expires.ToString("o") } else { "" }
        ageMinutes = if ($null -ne $updated) { [int]($now - $updated).TotalMinutes } else { $null }
        expiredMinutes = if ($null -ne $expires -and $expires -le $now) { [int]($now - $expires).TotalMinutes } else { $null }
        files = if ($Lock.PSObject.Properties.Name -contains "files") { @($Lock.files | Select-Object -First 5) } else { @() }
    }
}

$locks = @(Get-ChildItem -LiteralPath $lockRootPath -File -Filter "*.md" |
    Where-Object { $_.Name -ne "README.md" } |
    ForEach-Object { Read-AgentLock -Path $_.FullName } |
    Where-Object { $null -ne $_ })

$active = @($locks | Where-Object { $_.status -eq "in_progress" -and -not (Test-AgentLockExpired -Lock $_ -Now $now) } | ForEach-Object { ConvertTo-SnapshotLock -Lock $_ } | Sort-Object updatedAt -Descending)
$expiredActive = @($locks | Where-Object { $_.status -eq "in_progress" -and (Test-AgentLockExpired -Lock $_ -Now $now) } | ForEach-Object { ConvertTo-SnapshotLock -Lock $_ } | Sort-Object expiredMinutes -Descending)
$closed = @($locks | Where-Object { $_.status -eq "completed" -or $_.status -eq "stale" })
$exclusiveActive = @($active | Where-Object { $_.mode -eq "exclusive" })

[pscustomobject][ordered]@{
    ok = $true
    lockRoot = $lockRootPath
    activeCount = $active.Count
    exclusiveActiveCount = $exclusiveActive.Count
    expiredActiveCount = $expiredActive.Count
    closedCount = $closed.Count
    exclusiveActive = @($exclusiveActive | Select-Object -First $MaxLocks)
    active = @($active | Select-Object -First $MaxLocks)
    expiredActive = @($expiredActive | Select-Object -First $MaxLocks)
} | ConvertTo-Json -Depth 7
