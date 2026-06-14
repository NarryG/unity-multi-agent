<#
.SYNOPSIS
Marks a markdown coordination lock completed or stale.

.DESCRIPTION
Pass -Exclusive with the same -Scope used at acquire time to release the
single-agent exclusive lease at <lock-root>/exclusive.md. Use -Status stale
with a clear -Loop note when the goal is blocked or handed off rather than
finished.
#>
param(
    [string]$Scope = "",

    [Parameter(Mandatory = $true)]
    [string]$Agent,

    [ValidateSet("completed", "stale")]
    [string]$Status = "completed",

    [string]$Loop = "released lock",
    [string]$LockRoot = "Logs/AgentLocks",
    [switch]$UnityRunner,
    [switch]$Exclusive,
    [switch]$Keep,
    [switch]$Force,
    [string]$ForceReason = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "AgentLock.Common.ps1")

# Match Enter-AgentLock: -Scope is only required for scoped subsystem locks.
if ([string]::IsNullOrWhiteSpace($Scope)) {
    if ($Exclusive) { $Scope = "exclusive-session" }
    elseif ($UnityRunner) { $Scope = "unity-runner" }
    else { throw "-Scope is required for a scoped subsystem lock. Omit it only with -UnityRunner or -Exclusive." }
}

if ($Force -and [string]::IsNullOrWhiteSpace($ForceReason)) {
    throw "-Force requires -ForceReason so the closeout is auditable."
}

$repoRoot = Resolve-AgentLockRepositoryRoot
$lockRootPath = Resolve-AgentLockRoot -RepoRoot $repoRoot -LockRoot $LockRoot
$path = Get-AgentLockPath -LockRootPath $lockRootPath -Scope $Scope -UnityRunner:$UnityRunner -Exclusive:$Exclusive
$existing = Read-AgentLock -Path $path

if ($null -eq $existing) {
    Write-AgentLockReport -Report (New-AgentLockReport -Ok $true -Action "missing" -Path $path -Message "No lock file exists.") -Compact
    return
}

if ($existing.agent -ne $Agent -and -not $Force) {
    $report = New-AgentLockReport -Ok $false -Action "conflict" -Path $path -ExistingLock $existing -Message "Lock is owned by another agent. Use -Force with -ForceReason only after confirming recovery."
    Write-AgentLockReport -Report $report
    exit 2
}

if ($existing.agent -ne $Agent -and $Force) {
    $Loop = "$Loop; forced closeout: $ForceReason"
}

$now = Get-Date -Format o
$files = @()
if ($existing.PSObject.Properties.Name -contains "files") {
    $files = @($existing.files)
}

$subagent = ""
if ($existing.PSObject.Properties.Name -contains "subagent") {
    $subagent = $existing.subagent
}

$threadId = ""
if ($existing.PSObject.Properties.Name -contains "threadId") {
    $threadId = $existing.threadId
}

$keepLock = [bool]$Keep -or (Test-AgentLockKept -Lock $existing)
$mode = Get-AgentLockMode -Lock $existing
if (-not $DryRun) {
    Write-AgentLockFile -Path $path -Agent $existing.agent -Subagent $subagent -ThreadId $threadId -Scope $existing.scope -Task $existing.task -StartedAt $existing.startedAt -UpdatedAt $now -Status $Status -Mode $mode -Files $files -Loop $Loop -Keep:$keepLock
}

Write-AgentLockReport -Report (New-AgentLockReport -Ok $true -Action $Status -Path $path -ExistingLock $existing -Message "Lock marked $Status.") -Compact
