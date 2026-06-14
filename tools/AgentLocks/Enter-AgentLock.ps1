<#
.SYNOPSIS
Creates or refreshes a markdown coordination lock under the lock root (default: Logs/AgentLocks).

.DESCRIPTION
Use this for the lightweight coordination locks documented in
.agents/docs/MultiAgentWorkflow.md. It reuses a stable filename derived from
-Scope and refuses to overwrite another in-progress owner unless -Force is
supplied.

Use -Exclusive for a single-agent repo-wide lease. It refuses to start while
another active agent owns any lock, blocks new scoped locks from other agents
until the exclusive owner releases it, and replaces routine subsystem/proof
lock churn for that owner.

Use -UnityRunner for the single shared "drive Unity" lease (tests, Play Mode
proof, AssetDatabase refresh, serialization checks, project-file regeneration).
#>
param(
    [string]$Scope = "",

    [Parameter(Mandatory = $true)]
    [string]$Agent,

    [Parameter(Mandatory = $true)]
    [string]$Task,

    [string]$Subagent = "",
    [string]$ThreadId = "",
    [string[]]$Files = @(),
    [string]$Loop = "claiming lock",
    [string]$LockRoot = "Logs/AgentLocks",
    [ValidateRange(1, 1440)]
    [int]$TtlMinutes = 30,
    [switch]$UnityRunner,
    [switch]$Exclusive,
    [switch]$Keep,
    [switch]$Force,
    [string]$ForceReason = "",
    [string]$File = "",
    [string[]]$ArgumentList = @(),
    [ValidateRange(5, 3600)]
    [int]$RefreshSeconds = 60,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "AgentLock.Common.ps1")

# -Scope is only required for a scoped subsystem lock. The unity-runner and
# exclusive leases have fixed filenames, so default their scope label here
# instead of forcing callers to pass one (which would otherwise make
# PowerShell prompt for the missing mandatory parameter and hang).
if ([string]::IsNullOrWhiteSpace($Scope)) {
    if ($Exclusive) { $Scope = "exclusive-session" }
    elseif ($UnityRunner) { $Scope = "unity-runner" }
    else { throw "-Scope is required for a scoped subsystem lock. Omit it only with -UnityRunner or -Exclusive." }
}

if ($Force -and [string]::IsNullOrWhiteSpace($ForceReason)) {
    throw "-Force requires -ForceReason so the takeover is auditable."
}

$repoRoot = Resolve-AgentLockRepositoryRoot
$lockRootPath = Resolve-AgentLockRoot -RepoRoot $repoRoot -LockRoot $LockRoot
$path = Get-AgentLockPath -LockRootPath $lockRootPath -Scope $Scope -UnityRunner:$UnityRunner -Exclusive:$Exclusive
$existing = Read-AgentLock -Path $path

if ($UnityRunner -and -not $PSBoundParameters.ContainsKey("TtlMinutes")) {
    $TtlMinutes = 5
}

$nowDate = Get-Date
$now = $nowDate.ToString("o")
$expiresAt = $nowDate.AddMinutes($TtlMinutes).ToString("o")

$startedAt = $now
if ($null -ne $existing -and ($existing.PSObject.Properties.Name -contains "startedAt") -and -not [string]::IsNullOrWhiteSpace($existing.startedAt)) {
    $startedAt = $existing.startedAt
}

$mode = if ($Exclusive) { "exclusive" } else { "shared" }
$activeLocks = @(Get-ActiveAgentLocks -LockRootPath $lockRootPath -Now $nowDate)
$activeOtherLocks = @($activeLocks | Where-Object { $_.path -ne $path -and $_.agent -ne $Agent })
$activeForeignExclusiveLocks = @($activeLocks | Where-Object { $_.agent -ne $Agent -and (Test-AgentLockExclusive -Lock $_) })
$activeSameOwnerExclusiveLocks = @($activeLocks | Where-Object { $_.agent -eq $Agent -and (Test-AgentLockExclusive -Lock $_) })

if ($Exclusive -and $activeOtherLocks.Count -gt 0) {
    $report = New-AgentLockReport -Ok $false -Action "exclusive-conflict" -Path $path -Message "Exclusive mode requires no active locks owned by other agents. Wait for those locks to release or coordinate closeout before taking exclusive ownership." -ExistingLock $activeOtherLocks[0]
    Write-AgentLockReport -Report $report
    exit 2
}

if (-not $Exclusive -and $activeForeignExclusiveLocks.Count -gt 0 -and -not $Force) {
    $report = New-AgentLockReport -Ok $false -Action "exclusive-owner-conflict" -Path $path -Message "Another agent holds the exclusive lock. Wait for that owner to release exclusive mode before acquiring scoped locks." -ExistingLock $activeForeignExclusiveLocks[0]
    Write-AgentLockReport -Report $report
    exit 2
}

if (-not $Exclusive -and $activeSameOwnerExclusiveLocks.Count -gt 0) {
    $exclusiveLock = $activeSameOwnerExclusiveLocks[0]
    Write-Warning ("Agent '{0}' already owns active exclusive lock '{1}'. Routine scoped locks are unnecessary in exclusive mode; refresh exclusive.md instead unless this is a real handoff to another owner." -f $Agent, [IO.Path]::GetFileName($exclusiveLock.path))
}

if ($null -ne $existing -and $existing.status -eq "in_progress" -and $existing.agent -ne $Agent -and -not $Force) {
    $isExpired = Test-AgentLockExpired -Lock $existing -Now $nowDate
    $message = "Lock is in progress for another agent. Wait/retry or rerun with -Force after confirming takeover is appropriate."
    $action = "conflict"
    if ($isExpired) {
        $message = "Lock is in progress but its TTL has expired. Review the scope, then rerun with -Force and -ForceReason if takeover is appropriate."
        $action = "expired-conflict"
    }

    $report = New-AgentLockReport -Ok $false -Action $action -Path $path -ExistingLock $existing -Message $message
    Write-AgentLockReport -Report $report
    exit 2
}

if ($null -ne $existing -and $existing.status -eq "in_progress" -and $existing.agent -ne $Agent -and $Force) {
    $Loop = "$Loop; forced takeover: $ForceReason"
}

$effectiveThreadId = $ThreadId
if ([string]::IsNullOrWhiteSpace($effectiveThreadId) -and $null -ne $existing -and ($existing.PSObject.Properties.Name -contains "threadId")) {
    $effectiveThreadId = $existing.threadId
}

if (-not $DryRun) {
    Write-AgentLockFile -Path $path -Agent $Agent -Subagent $Subagent -ThreadId $effectiveThreadId -Scope $Scope -Task $Task -StartedAt $startedAt -UpdatedAt $now -Status "in_progress" -TtlMinutes $TtlMinutes -ExpiresAt $expiresAt -Mode $mode -Files $Files -Loop $Loop -Keep:([bool]$Keep)
}

$action = "enter"
if ($null -ne $existing -and $existing.agent -eq $Agent -and $existing.status -eq "in_progress") {
    $action = "refresh"
    if ($Exclusive) {
        $action = "refresh-exclusive"
    }
}
elseif ($Exclusive) {
    $action = "enter-exclusive"
}

$enterReport = New-AgentLockReport -Ok $true -Action $action -Path $path -ExistingLock $existing -Message "Lock is in progress until $expiresAt." -ExpiresAt $expiresAt
Write-AgentLockReport -Report $enterReport -Compact

if ([string]::IsNullOrWhiteSpace($File)) {
    return
}

if ($DryRun) {
    return
}

$resolvedFile = $File
if (-not [IO.Path]::IsPathRooted($resolvedFile)) {
    $resolvedFile = Join-Path (Get-Location).ProviderPath $resolvedFile
}
if (-not (Test-Path -LiteralPath $resolvedFile -PathType Leaf)) {
    throw "Command file '$File' was not found."
}

$process = $null
$exitCode = 1
try {
    $childArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedFile)
    $childArguments += $ArgumentList
    $process = Start-Process -FilePath "powershell" -ArgumentList $childArguments -NoNewWindow -PassThru

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $RefreshSeconds
        if (-not $process.HasExited) {
            $refreshNowDate = Get-Date
            $refreshNow = $refreshNowDate.ToString("o")
            $refreshExpiresAt = $refreshNowDate.AddMinutes($TtlMinutes).ToString("o")
            Write-AgentLockFile -Path $path -Agent $Agent -Subagent $Subagent -ThreadId $effectiveThreadId -Scope $Scope -Task $Task -StartedAt $startedAt -UpdatedAt $refreshNow -Status "in_progress" -TtlMinutes $TtlMinutes -ExpiresAt $refreshExpiresAt -Mode $mode -Files $Files -Loop "Refreshing lock while command is still running" -Keep:([bool]$Keep)
            $process.Refresh()
        }
    }

    $exitCode = $process.ExitCode
}
finally {
    try {
        $closeNow = Get-Date -Format o
        Write-AgentLockFile -Path $path -Agent $Agent -Subagent $Subagent -ThreadId $effectiveThreadId -Scope $Scope -Task $Task -StartedAt $startedAt -UpdatedAt $closeNow -Status "completed" -Mode $mode -Files $Files -Loop "Released after locked command exited" -Keep:([bool]$Keep)
        Write-AgentLockReport -Report (New-AgentLockReport -Ok $true -Action "completed" -Path $path -Message "Lock marked completed after command exit.") -Compact
    }
    catch {
        Write-Warning "[Enter-AgentLock] Failed to release lock after command exit: $($_.Exception.Message)"
        if ($exitCode -eq 0) {
            $exitCode = 1
        }
    }
}

exit $exitCode
