Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# UserPromptSubmit hook for both Claude Code and Codex.
#
# It cleans up old closed locks, then injects a compact summary of the current
# Logs/AgentLocks state into the agent's context so a session starts aware of
# what other agents are holding. Output uses the shared hook contract:
#   { "hookSpecificOutput": { "hookEventName": "UserPromptSubmit",
#                             "additionalContext": "<text>" } }
#
# Resolve the tool paths relative to this script so the hook works regardless of
# where the package was installed (default install puts it at
# <project>/.agents/hooks/AgentLockContext.ps1 with tools at
# <project>/.agents/tools/AgentLocks).

function Write-AdditionalContext {
    param([string]$Text)

    [pscustomobject]@{
        hookSpecificOutput = [pscustomobject]@{
            hookEventName = "UserPromptSubmit"
            additionalContext = $Text
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

function Resolve-RepoRoot {
    # Prefer git; fall back to walking up for a Unity project or .git marker.
    try {
        $gitRoot = (& git rev-parse --show-toplevel 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($gitRoot)) {
            return $gitRoot.Trim()
        }
    }
    catch {
        # ignore and fall back
    }

    $current = (Get-Location).ProviderPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ((Test-Path -LiteralPath (Join-Path $current ".git")) -or
            (Test-Path -LiteralPath (Join-Path $current "ProjectSettings\ProjectVersion.txt"))) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if ($parent -eq $current) {
            break
        }

        $current = $parent
    }

    return $null
}

# Drain stdin so the calling harness is not blocked (we do not need the prompt).
$raw = [Console]::In.ReadToEnd()
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $null = $raw
}

$repoRoot = Resolve-RepoRoot
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    exit 0
}

$lockRoot = Join-Path $repoRoot "Logs/AgentLocks"
if (-not (Test-Path -LiteralPath $lockRoot)) {
    exit 0
}

$toolsRoot = Join-Path $repoRoot ".agents/tools/AgentLocks"
$cleanupScript = Join-Path $toolsRoot "Clear-CompletedLocks.ps1"
$snapshotScript = Join-Path $toolsRoot "Get-AgentLockSnapshot.ps1"
if (-not (Test-Path -LiteralPath $cleanupScript) -or -not (Test-Path -LiteralPath $snapshotScript)) {
    exit 0
}

$cleanup = $null
try {
    $cleanupJson = & $cleanupScript -RetentionHours 6 -ExpiredActiveGraceMinutes 240 -MarkExpiredActiveStale
    $cleanup = $cleanupJson | ConvertFrom-Json
}
catch {
    Write-AdditionalContext -Text "Agent lock cleanup hook failed: $($_.Exception.Message). Continue cautiously and inspect Logs/AgentLocks before editing shared files."
    exit 0
}

$snapshot = $null
try {
    $snapshotJson = & $snapshotScript -MaxLocks 8
    $snapshot = $snapshotJson | ConvertFrom-Json
}
catch {
    Write-AdditionalContext -Text "Agent lock snapshot hook failed: $($_.Exception.Message). Continue cautiously and inspect Logs/AgentLocks before editing shared files."
    exit 0
}

$notableCleanup = @()
if ($null -ne $cleanup -and $cleanup.PSObject.Properties.Name -contains "locks") {
    $notableCleanup = @($cleanup.locks | Where-Object {
        $_.action -eq "prune" -or $_.action -eq "mark-expired-active-stale"
    })
}

$expired = @()
if ($null -ne $snapshot -and $snapshot.PSObject.Properties.Name -contains "expiredActive") {
    $expired = @($snapshot.expiredActive)
}

$active = @()
if ($null -ne $snapshot -and $snapshot.PSObject.Properties.Name -contains "active") {
    $active = @($snapshot.active)
}

$exclusiveActive = @()
if ($null -ne $snapshot -and $snapshot.PSObject.Properties.Name -contains "exclusiveActive") {
    $exclusiveActive = @($snapshot.exclusiveActive)
}

$ordinaryActive = @($active | Where-Object {
    $mode = if ($_.PSObject.Properties.Name -contains "mode") { [string]$_.mode } else { "" }
    $file = if ($_.PSObject.Properties.Name -contains "file") { [string]$_.file } else { "" }
    $mode -ne "exclusive" -and $file -ne "exclusive.md"
})

if ($notableCleanup.Count -eq 0 -and $expired.Count -eq 0 -and $exclusiveActive.Count -eq 0 -and $ordinaryActive.Count -eq 0) {
    exit 0
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Agent lock context:")

if ($notableCleanup.Count -gt 0) {
    $marked = @($notableCleanup | Where-Object { $_.action -eq "mark-expired-active-stale" }).Count
    $pruned = @($notableCleanup | Where-Object { $_.action -eq "prune" }).Count
    $parts = @()
    if ($marked -gt 0) { $parts += "marked $marked expired active lock(s) stale" }
    if ($pruned -gt 0) { $parts += "deleted $pruned closed lock(s)" }
    $lines.Add("- Cleanup: $($parts -join '; ').")
}

if ($expired.Count -gt 0) {
    $lines.Add("- Expired active locks still need review or owner refresh:")
    foreach ($lock in $expired | Select-Object -First 5) {
        $lines.Add("  - $($lock.file): $($lock.agent), scope=$($lock.scope), expiredMinutes=$($lock.expiredMinutes)")
    }
}

if ($exclusiveActive.Count -gt 0) {
    $lines.Add("- Exclusive single-agent lease active. It replaces routine subsystem/proof/Unity-runner locks for its owner; other agents should wait or coordinate before editing/running Unity:")
    foreach ($lock in $exclusiveActive | Select-Object -First 3) {
        $lines.Add("  - $($lock.file): $($lock.agent), scope=$($lock.scope), expiresAt=$($lock.expiresAt)")
    }
}

if ($ordinaryActive.Count -gt 0) {
    $lines.Add("- Active non-exclusive locks exist. Before editing overlapping files or running Unity, refresh/re-acquire your own matching lock or wait/coordinate:")
    foreach ($lock in $ordinaryActive | Select-Object -First 5) {
        $lines.Add("  - $($lock.file): $($lock.agent), scope=$($lock.scope), expiresAt=$($lock.expiresAt)")
    }
}

Write-AdditionalContext -Text ($lines -join [Environment]::NewLine)
