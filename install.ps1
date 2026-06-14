<#
.SYNOPSIS
Installs the Unity multi-agent coordination kit into a target Unity project.

.DESCRIPTION
Copies the skills, tools, hooks, and docs from this package into a target
project and wires the lock-context hook into both Claude Code (.claude/
settings.json) and Codex (.codex/hooks.json). Re-running is safe: copies are
overwritten and hook entries are de-duplicated.

Layout created in the target project:
  .agents/tools/      lock + delegation + worktree scripts
  .agents/hooks/      AgentLockContext.ps1 (UserPromptSubmit hook)
  .agents/docs/       MultiAgentWorkflow.md, UnitySafety.md, AgentHandoffFormat.md
  .agents/skills/     skills (for Codex / AGENTS.md harnesses)
  .claude/skills/     same skills (for Claude Code)
  .claude/settings.json, .codex/hooks.json   hook wiring (merged)
  .agents/AGENTS.coordination.md             guidance block to merge into AGENTS.md
  Logs/AgentLocks/README.md                  lock-root readme

Run this with PowerShell 7+ (pwsh).

.EXAMPLE
pwsh -File .\install.ps1 -TargetProject D:\Unity\MyGame
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetProject,

    [switch]$SkipDelegation,
    [switch]$SkipWorktrees,
    [switch]$SkipLaneTemplate,
    [switch]$NoGitignore,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 6) {
    throw "Run this installer with PowerShell 7+ (pwsh), not Windows PowerShell 5.1."
}

$packageRoot = $PSScriptRoot
$target = (Resolve-Path -LiteralPath $TargetProject).Path

Write-Host "Installing Unity multi-agent kit"
Write-Host "  from: $packageRoot"
Write-Host "  to:   $target"
if ($DryRun) { Write-Host "  (dry run — no changes written)" }

$actions = New-Object System.Collections.Generic.List[string]

function New-TargetDir {
    param([string]$RelPath)
    $full = Join-Path $target $RelPath
    if (-not (Test-Path -LiteralPath $full)) {
        $actions.Add("mkdir $RelPath")
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $full | Out-Null }
    }
}

function Copy-Tree {
    param([string]$SourceRel, [string]$TargetRel)
    $src = Join-Path $packageRoot $SourceRel
    if (-not (Test-Path -LiteralPath $src)) { return }
    $dst = Join-Path $target $TargetRel
    $actions.Add("copy $SourceRel -> $TargetRel")
    if (-not $DryRun) {
        # Remove an existing destination first so re-running mirrors cleanly
        # instead of nesting the source folder inside it (Copy-Item -Recurse quirk).
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
}

function Copy-File {
    param([string]$SourceRel, [string]$TargetRel)
    $src = Join-Path $packageRoot $SourceRel
    if (-not (Test-Path -LiteralPath $src)) { return }
    $dst = Join-Path $target $TargetRel
    $actions.Add("copy $SourceRel -> $TargetRel")
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

function Copy-Skill {
    param([string]$Name)
    $src = Join-Path (Join-Path $packageRoot "skills") $Name
    if (-not (Test-Path -LiteralPath $src)) { return }
    foreach ($skillsRoot in @(".claude/skills", ".agents/skills")) {
        $dst = Join-Path $target (Join-Path $skillsRoot $Name)
        $actions.Add("skill $Name -> $skillsRoot/$Name")
        if (-not $DryRun) {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        }
    }
}

# --- Tools (lock core always; delegation/worktree optional) ---
Copy-Tree "tools/AgentLocks" ".agents/tools/AgentLocks"
if (-not $SkipDelegation) { Copy-Tree "tools/AgentDelegates" ".agents/tools/AgentDelegates" }
if (-not $SkipWorktrees)  { Copy-Tree "tools/Worktree" ".agents/tools/Worktree" }

# --- Hook script + docs ---
Copy-File "hooks/AgentLockContext.ps1" ".agents/hooks/AgentLockContext.ps1"
Copy-File "docs/MultiAgentWorkflow.md" ".agents/docs/MultiAgentWorkflow.md"
Copy-File "docs/UnitySafety.md" ".agents/docs/UnitySafety.md"
Copy-File "docs/AgentHandoffFormat.md" ".agents/docs/AgentHandoffFormat.md"
Copy-File "docs/LockRoot.README.md" "Logs/AgentLocks/README.md"

# --- Guidance block ---
Copy-File "templates/AGENTS.md" ".agents/AGENTS.coordination.md"

# --- Skills ---
Copy-Skill "unity-multi-agent"
Copy-Skill "agent-locks"
if (-not $SkipWorktrees)    { Copy-Skill "agent-worktrees" }
if (-not $SkipDelegation)   { Copy-Skill "agent-delegation" }
if (-not $SkipLaneTemplate) { Copy-Skill "agent-iteration-loop" }

# --- Merge the UserPromptSubmit hook into a settings file ---
function Merge-PromptHook {
    param(
        [string]$SettingsRel,
        [string]$Command,
        [string]$CommandWindows,
        [int]$Timeout,
        [string]$StatusMessage
    )

    $path = Join-Path $target $SettingsRel
    $root = @{}
    if (Test-Path -LiteralPath $path) {
        $existingText = Get-Content -LiteralPath $path -Raw
        if (-not [string]::IsNullOrWhiteSpace($existingText)) {
            $root = $existingText | ConvertFrom-Json -AsHashtable
        }
    }

    if (-not $root.ContainsKey("hooks")) { $root["hooks"] = @{} }
    if (-not $root["hooks"].ContainsKey("UserPromptSubmit")) { $root["hooks"]["UserPromptSubmit"] = @() }

    $already = $false
    foreach ($group in @($root["hooks"]["UserPromptSubmit"])) {
        if ($null -ne $group -and $group.ContainsKey("hooks")) {
            foreach ($h in @($group["hooks"])) {
                if ($null -ne $h -and $h.ContainsKey("command") -and ([string]$h["command"]).Contains("AgentLockContext.ps1")) {
                    $already = $true
                }
            }
        }
    }

    if ($already) {
        $actions.Add("hook already present in $SettingsRel")
        return
    }

    $hookEntry = @{ type = "command"; command = $Command; timeout = $Timeout }
    if (-not [string]::IsNullOrWhiteSpace($CommandWindows)) { $hookEntry["commandWindows"] = $CommandWindows }
    if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) { $hookEntry["statusMessage"] = $StatusMessage }

    $root["hooks"]["UserPromptSubmit"] = @($root["hooks"]["UserPromptSubmit"]) + @(@{ hooks = @($hookEntry) })

    $actions.Add("wire lock hook into $SettingsRel")
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        ($root | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding UTF8
    }
}

Merge-PromptHook -SettingsRel ".claude/settings.json" `
    -Command 'powershell -NoProfile -ExecutionPolicy Bypass -File "$CLAUDE_PROJECT_DIR/.agents/hooks/AgentLockContext.ps1"' `
    -Timeout 15000

Merge-PromptHook -SettingsRel ".codex/hooks.json" `
    -Command 'pwsh -NoProfile -ExecutionPolicy Bypass -File .agents/hooks/AgentLockContext.ps1' `
    -CommandWindows 'powershell -NoProfile -ExecutionPolicy Bypass -File .agents/hooks/AgentLockContext.ps1' `
    -Timeout 15 -StatusMessage "Checking agent locks"

# --- gitignore the live coordination state ---
if (-not $NoGitignore) {
    $gitignore = Join-Path $target ".gitignore"
    $marker = "# Unity multi-agent coordination (live state)"
    $hasMarker = $false
    if (Test-Path -LiteralPath $gitignore) {
        $hasMarker = (Get-Content -LiteralPath $gitignore -Raw).Contains($marker)
    }
    if (-not $hasMarker) {
        $block = @"

$marker
Logs/AgentLocks/
Logs/AgentHandoffs/
Logs/AgentDelegates/
!Logs/AgentLocks/README.md
"@
        $actions.Add("append coordination entries to .gitignore")
        if (-not $DryRun) { Add-Content -LiteralPath $gitignore -Value $block -Encoding UTF8 }
    }
}

Write-Host ""
Write-Host "Actions:"
foreach ($a in $actions) { Write-Host "  - $a" }

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Merge .agents/AGENTS.coordination.md into your project's AGENTS.md and/or .claude/CLAUDE.md."
Write-Host "  2. If you took the lane template, edit .agents/skills/agent-iteration-loop/SKILL.md (and the .claude copy) for your project's lanes."
Write-Host "  3. Start a session and confirm the lock-context hook prints when Logs/AgentLocks has active locks."
