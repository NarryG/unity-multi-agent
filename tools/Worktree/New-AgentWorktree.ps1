<#
.SYNOPSIS
Creates an agent branch/worktree and a starter handoff stub.

.DESCRIPTION
Launcher for code-only or planning-ready agent slices that need their own
Unity instance / checkout. It creates a new git branch from the chosen
integration base, places it in a separate worktree, and writes an ignored
handoff file with the claim metadata an agent should copy into the project's
work queue before editing.

The launcher intentionally does not acquire resource locks. Use the
.agents/tools/AgentLocks scripts before touching the shared Unity Editor,
serialized assets, packages, project settings, or other shared resources --
including from inside the new worktree.

Use a short Windows worktree root such as D:\w\<task> to stay under the path
length limit, or enable `git config core.longpaths true`.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z0-9._/-]+$")]
    [string]$Branch,

    [Parameter(Mandatory = $true)]
    [string]$WorktreePath,

    [Parameter(Mandatory = $true)]
    [string]$Lane,

    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [Parameter(Mandatory = $true)]
    [string[]]$ExpectedTouchPoints,

    [Parameter(Mandatory = $true)]
    [ValidateSet("none", "read-only", "validation", "authoring")]
    [string]$UnityAccess,

    [string]$StoryId = "",
    [string]$AgentId = $env:USERNAME,
    [string]$BaseRef = "main",
    [string]$HandoffRoot = "Logs/AgentHandoffs",
    [switch]$AllowDirtyBase,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RepositoryRoot {
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        throw "Run this script from inside the git repository."
    }

    return (Resolve-Path -LiteralPath $root.Trim()).Path
}

function ConvertTo-SafePathSegment {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "unassigned"
    }

    return ([regex]::Replace($Value, "[^A-Za-z0-9._-]", "_")).Trim("_")
}

function Get-AbsolutePath {
    param([string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Assert-GitRefExists {
    param([string]$Ref)

    & git rev-parse --verify --quiet $Ref | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Base ref '$Ref' does not exist. Choose a current integration base."
    }
}

function Assert-BranchDoesNotExist {
    param([string]$Name)

    & git rev-parse --verify --quiet "refs/heads/$Name" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        throw "Branch '$Name' already exists. Use a fresh branch for one coherent slice."
    }
}

function Assert-WorktreePathIsAvailable {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "Worktree path '$Path' already exists and is not empty."
        }
    }
}

function Assert-WorktreePathCanHoldTrackedFiles {
    param(
        [string]$Path,
        [string]$Ref
    )

    $isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if (-not $isWindowsPlatform) {
        return
    }

    $longPaths = (& git config --bool core.longpaths 2>$null)
    if ($LASTEXITCODE -eq 0 -and $longPaths -eq "true") {
        return
    }

    $paths = @(& git ls-tree -r --name-only $Ref)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect tracked paths in '$Ref'."
    }

    $longestPath = $paths |
        Sort-Object { (Join-Path $Path $_).Length } -Descending |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($longestPath)) {
        return
    }

    $fullLength = (Join-Path $Path $longestPath).Length
    if ($fullLength -ge 248) {
        throw "Worktree path is too long for this repo on Windows without git core.longpaths=true. Longest checkout path would be $fullLength characters: '$longestPath'. Choose a shorter path such as 'D:\w\<task>' or enable long paths explicitly."
    }
}

function Get-PorcelainStatus {
    return @(& git status --porcelain=v1)
}

function New-HandoffMarkdown {
    param(
        [string]$RepoRoot,
        [string]$HandoffPath,
        [string]$ResolvedWorktreePath
    )

    $timestamp = (Get-Date).ToString("o")
    $touchPoints = ($ExpectedTouchPoints | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    $story = if ([string]::IsNullOrWhiteSpace($StoryId)) { "unassigned" } else { $StoryId }
    $content = @"
# Agent Handoff

agent: $AgentId
story: $story
branch: $Branch
worktree: $ResolvedWorktreePath
base: $BaseRef
lane: $Lane
domain: $Domain
unityAccess: $UnityAccess
createdAt: $timestamp

## Expected Touch Points

$touchPoints

## Before Editing

- Update your work queue / story card with Owner, Branch, Worktree, Resources, Proof, and Claimed Touch Points.
- Inspect Logs/AgentLocks/ in this worktree and acquire required leases before editing shared or serialized resources.
- Do not claim Unity/editor validation, packages, project settings, or serialized assets unless the task explicitly grants that resource and the matching lock is held.
- Keep the branch to one coherent slice.

## Closeout

- Record proof in the story card or a linked artifact.
- Run `git diff --check`.
- Commit only files for this slice.
- See .agents/docs/AgentHandoffFormat.md for the full closeout handoff shape.
"@

    $handoffDirectory = Split-Path -Parent $HandoffPath
    New-Item -ItemType Directory -Force -Path $handoffDirectory | Out-Null
    $content | Set-Content -LiteralPath $HandoffPath -Encoding UTF8
}

$repoRoot = Resolve-RepositoryRoot
Push-Location $repoRoot
try {
    Assert-GitRefExists -Ref $BaseRef
    Assert-BranchDoesNotExist -Name $Branch

    $resolvedWorktreePath = Get-AbsolutePath -Path $WorktreePath
    Assert-WorktreePathIsAvailable -Path $resolvedWorktreePath
    Assert-WorktreePathCanHoldTrackedFiles -Path $resolvedWorktreePath -Ref $BaseRef

    $status = @(Get-PorcelainStatus)
    if ($status.Count -gt 0 -and -not $AllowDirtyBase) {
        throw "Base worktree is dirty. Commit, stash, or rerun with -AllowDirtyBase after explicitly accepting the risk."
    }

    $safeBranch = ConvertTo-SafePathSegment -Value $Branch
    $safeStory = ConvertTo-SafePathSegment -Value $StoryId
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $handoffRootPath = if ([IO.Path]::IsPathRooted($HandoffRoot)) {
        $HandoffRoot
    } else {
        Join-Path $repoRoot $HandoffRoot
    }
    $handoffPath = Join-Path $handoffRootPath (Join-Path $safeBranch "$timestamp-$safeStory.md")

    $summary = [ordered]@{
        ok = $true
        dryRun = [bool]$DryRun
        branch = $Branch
        worktree = $resolvedWorktreePath
        baseRef = $BaseRef
        lane = $Lane
        domain = $Domain
        unityAccess = $UnityAccess
        expectedTouchPoints = @($ExpectedTouchPoints)
        handoffPath = $handoffPath
        nextActions = @(
            "Update your work queue with Owner, Branch, Worktree, Resources, Proof, and Claimed Touch Points.",
            "Inspect Logs/AgentLocks inside the new worktree and acquire required leases before editing.",
            "Do not touch Unity serialized assets or serialized resources unless the task grants them and the lock is held."
        )
    }

    if ($DryRun) {
        [Console]::Error.WriteLine("[New-AgentWorktree] Dry run only. No branch, worktree, or handoff file was created.")
        $summary | ConvertTo-Json -Depth 6
        return
    }

    # Capture git's chatter ("Preparing worktree", "HEAD is now at ...") so it
    # goes to stderr instead of polluting the JSON summary on stdout.
    $gitOutput = & git worktree add -b $Branch $resolvedWorktreePath $BaseRef 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed for branch '$Branch'. $gitOutput"
    }
    foreach ($line in $gitOutput) { [Console]::Error.WriteLine([string]$line) }

    New-HandoffMarkdown -RepoRoot $repoRoot -HandoffPath $handoffPath -ResolvedWorktreePath $resolvedWorktreePath
    [Console]::Error.WriteLine("[New-AgentWorktree] Created branch '$Branch' at '$resolvedWorktreePath'.")
    [Console]::Error.WriteLine("[New-AgentWorktree] Wrote handoff '$handoffPath'.")
    $summary | ConvertTo-Json -Depth 6
}
finally {
    Pop-Location
}
