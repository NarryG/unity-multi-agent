Set-StrictMode -Version Latest

# Shared library for the Unity multi-agent lock scripts.
#
# These coordination locks let multiple agent sessions safely share one
# checkout and one Unity Editor. Live lock files are short-lived markdown
# leases under the lock root (default: Logs/AgentLocks). Nothing here is
# project-specific; override -LockRoot if you want a different location.

function Resolve-AgentLockRepositoryRoot {
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

    throw "Could not find the repository root from the current directory."
}

function Resolve-AgentLockRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$LockRoot = "Logs/AgentLocks"
    )

    if ([System.IO.Path]::IsPathRooted($LockRoot)) {
        return $LockRoot
    }

    return (Join-Path $RepoRoot $LockRoot)
}

function ConvertTo-AgentLockSlug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope
    )

    $slug = $Scope.Trim().ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Scope '$Scope' cannot be converted to a lock filename."
    }

    return $slug
}

function Get-AgentLockPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockRootPath,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [switch]$Exclusive,

        [switch]$UnityRunner
    )

    $slug = ConvertTo-AgentLockSlug -Scope $Scope
    if ($Exclusive) {
        return (Join-Path $LockRootPath "exclusive.md")
    }

    if ($UnityRunner -or $slug -eq "unity-runner") {
        return (Join-Path $LockRootPath "unity-runner.md")
    }

    return (Join-Path $LockRootPath "subsystem-$slug.md")
}

function Read-AgentLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $lines = Get-Content -LiteralPath $Path
    $lock = [ordered]@{
        path = $Path
        raw = $lines
        files = @()
    }

    $inFiles = $false
    foreach ($line in $lines) {
        if ($line -match "^files:\s*$") {
            $inFiles = $true
            continue
        }

        if ($inFiles) {
            if ($line -match "^\s*-\s+(.+?)\s*$") {
                $lock.files += $Matches[1]
                continue
            }

            if ($line -match "^[A-Za-z][A-Za-z0-9_-]*:") {
                $inFiles = $false
            }
        }

        if ($line -match "^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$") {
            $lock[$Matches[1]] = $Matches[2]
        }
    }

    return [pscustomobject]$lock
}

function Test-AgentLockKept {
    param(
        [Parameter(Mandatory = $true)]
        $Lock
    )

    return ($Lock.PSObject.Properties.Name -contains "keep") -and ($Lock.keep -match "^(true|yes|1)$")
}

function Get-AgentLockMode {
    param(
        [Parameter(Mandatory = $true)]
        $Lock
    )

    if (($Lock.PSObject.Properties.Name -contains "mode") -and -not [string]::IsNullOrWhiteSpace($Lock.mode)) {
        return $Lock.mode
    }

    if (($Lock.PSObject.Properties.Name -contains "exclusive") -and ($Lock.exclusive -match "^(true|yes|1)$")) {
        return "exclusive"
    }

    return "shared"
}

function Test-AgentLockExclusive {
    param(
        [Parameter(Mandatory = $true)]
        $Lock
    )

    return (Get-AgentLockMode -Lock $Lock) -eq "exclusive"
}

function Get-ActiveAgentLocks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockRootPath,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    if (-not (Test-Path -LiteralPath $LockRootPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $LockRootPath -File -Filter "*.md" |
        Where-Object { $_.Name -ne "README.md" } |
        ForEach-Object { Read-AgentLock -Path $_.FullName } |
        Where-Object { $null -ne $_ -and $_.status -eq "in_progress" -and -not (Test-AgentLockExpired -Lock $_ -Now $Now) })
}

function Get-AgentLockUpdatedAt {
    param(
        [Parameter(Mandatory = $true)]
        $Lock
    )

    if ($Lock.PSObject.Properties.Name -contains "updatedAt") {
        $updated = [datetime]::MinValue
        if ([datetime]::TryParse($Lock.updatedAt, [ref]$updated)) {
            return $updated
        }
    }

    if (($Lock.PSObject.Properties.Name -contains "path") -and (Test-Path -LiteralPath $Lock.path)) {
        return (Get-Item -LiteralPath $Lock.path).LastWriteTime
    }

    return $null
}

function Get-AgentLockExpiresAt {
    param(
        [Parameter(Mandatory = $true)]
        $Lock
    )

    if ($Lock.PSObject.Properties.Name -contains "expiresAt") {
        $expires = [datetime]::MinValue
        if ([datetime]::TryParse($Lock.expiresAt, [ref]$expires)) {
            return $expires
        }
    }

    return $null
}

function Test-AgentLockExpired {
    param(
        [Parameter(Mandatory = $true)]
        $Lock,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    $expires = Get-AgentLockExpiresAt -Lock $Lock
    return ($null -ne $expires) -and ($expires -le $Now)
}

function Write-AgentLockFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Agent,

        [string]$Subagent = "",

        [string]$ThreadId = "",

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$Task,

        [Parameter(Mandatory = $true)]
        [string]$StartedAt,

        [Parameter(Mandatory = $true)]
        [string]$UpdatedAt,

        [Parameter(Mandatory = $true)]
        [ValidateSet("in_progress", "completed", "stale")]
        [string]$Status,

        [ValidateRange(1, 1440)]
        [int]$TtlMinutes = 30,

        [string]$ExpiresAt = "",

        [ValidateSet("shared", "exclusive")]
        [string]$Mode = "shared",

        [string[]]$Files = @(),

        [string]$Loop = "",

        [bool]$Keep = $false
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Agent Lock")
    $lines.Add("agent: $Agent")
    if (-not [string]::IsNullOrWhiteSpace($Subagent)) {
        $lines.Add("subagent: $Subagent")
    }
    if (-not [string]::IsNullOrWhiteSpace($ThreadId)) {
        $lines.Add("threadId: $ThreadId")
    }
    $lines.Add("scope: $Scope")
    $lines.Add("task: $Task")
    $lines.Add("startedAt: $StartedAt")
    $lines.Add("updatedAt: $UpdatedAt")
    $lines.Add("status: $Status")
    $lines.Add("mode: $Mode")
    if ($Status -eq "in_progress") {
        $lines.Add("ttlMinutes: $TtlMinutes")
        $lines.Add("expiresAt: $ExpiresAt")
    }
    if ($Keep) {
        $lines.Add("keep: true")
    }
    $lines.Add("files:")
    foreach ($file in $Files) {
        if (-not [string]::IsNullOrWhiteSpace($file)) {
            $lines.Add("- $file")
        }
    }
    $lines.Add("loop: $Loop")

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function New-AgentLockReport {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Ok,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Message = "",

        [string]$ExpiresAt = "",

        $ExistingLock = $null
    )

    $report = [ordered]@{
        ok = $Ok
        action = $Action
        path = $Path
        message = $Message
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpiresAt)) {
        $report.expiresAt = $ExpiresAt
    }

    if ($null -ne $ExistingLock) {
        $report.existing = [ordered]@{
            agent = $ExistingLock.agent
            threadId = if ($ExistingLock.PSObject.Properties.Name -contains "threadId") { $ExistingLock.threadId } else { "" }
            scope = $ExistingLock.scope
            status = $ExistingLock.status
            mode = Get-AgentLockMode -Lock $ExistingLock
            updatedAt = $ExistingLock.updatedAt
            expiresAt = if ($ExistingLock.PSObject.Properties.Name -contains "expiresAt") { $ExistingLock.expiresAt } else { "" }
            task = $ExistingLock.task
        }
    }

    return [pscustomobject]$report
}

function Format-AgentLockReportLine {
    param(
        [Parameter(Mandatory = $true)]
        $Report
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("lock")
    $parts.Add($Report.action)
    $parts.Add($(if ($Report.ok) { "ok" } else { "blocked" }))

    if ($Report.PSObject.Properties.Name -contains "path") {
        $file = [IO.Path]::GetFileName($Report.path)
        if (-not [string]::IsNullOrWhiteSpace($file)) {
            $parts.Add("file=$file")
        }
    }

    if (($Report.PSObject.Properties.Name -contains "expiresAt") -and -not [string]::IsNullOrWhiteSpace($Report.expiresAt)) {
        $parts.Add("expiresAt=$($Report.expiresAt)")
    }

    return ($parts -join " ")
}

function Write-AgentLockReport {
    param(
        [Parameter(Mandatory = $true)]
        $Report,

        [switch]$Compact
    )

    if ($Compact -and $Report.ok) {
        Format-AgentLockReportLine -Report $Report
        return
    }

    $Report | ConvertTo-Json -Depth 6
}
