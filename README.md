# Unity Multi-Agent Coordination Kit

A drop-in system for running **multiple AI agents on one Unity project** without
clobbering each other — whether several sessions share one checkout and one
Unity Editor, or agents work across separate branches/worktrees and separate
Unity instances.

It is packaged as **skills** (SKILL.md format) plus the PowerShell tools and
session hooks they drive. It targets both **Claude Code** and **Codex**.

> Extracted and genericized from the SigilDrop/OwlPet project's multi-agent
> system. All project-specific content (boards, validators, product skills) has
> been stripped; what remains is the reusable coordination core.

## What's In The Box

| Piece | Path | What it does |
|---|---|---|
| **Lock core** | `tools/AgentLocks/` | File-based coordination locks: scoped subsystem locks, one shared Unity-runner lease, and an exclusive single-agent mode. TTL/expiry, auto-refresh while wrapping a command, JSON reports. |
| **Lock-context hook** | `hooks/AgentLockContext.ps1` | `UserPromptSubmit` hook that cleans up stale locks and injects the live lock state into every session. Works for both Claude Code and Codex. |
| **Worktree launcher** | `tools/Worktree/New-AgentWorktree.ps1` | Creates a branch + worktree + handoff stub for an isolated agent / Unity instance. |
| **Delegation wrapper** | `tools/AgentDelegates/` | Routes a bounded subtask to a child CLI harness (OpenCode / Antigravity / Copilot), analysis-only unless writes are allowed. |
| **Skills** | `skills/` | `unity-multi-agent` (router), `agent-locks`, `agent-worktrees`, `agent-delegation`, `agent-iteration-loop` (lane template). |
| **Reference docs** | `docs/` | Full workflow protocol, Unity safety + validation tiers, handoff format. |
| **Guidance block** | `templates/AGENTS.md` | The project-instruction sections to merge into your AGENTS.md / CLAUDE.md. |

## How It Works

Coordination state is a set of short-lived markdown files under
`Logs/AgentLocks/` (gitignored). The scripts own the schema:

- `Enter-AgentLock.ps1` — claim/refresh a lock. Three modes:
  - `-Scope <area>` → `subsystem-<area>.md` (active editing of a durable area)
  - `-UnityRunner` → `unity-runner.md` (the single "drive Unity" lease)
  - `-Exclusive -Scope <name>` → `exclusive.md` (single-agent shortcut that
    blocks all other locks)
- `Exit-AgentLock.ps1` — release (`completed` / `stale`).
- `Get-AgentLockSnapshot.ps1` — read-only JSON summary (used by the hook).
- `Clear-CompletedLocks.ps1` — prune closed locks past a retention window;
  never deletes a live lock.

A session starts, the hook prints who holds what, and the agent claims the
narrowest lock it needs at the point of use, refreshes once per loop, and
releases before ending the turn. See `docs/MultiAgentWorkflow.md` for the full
protocol.

## Install Into A Project

```powershell
pwsh -File .\install.ps1 -TargetProject D:\Unity\MyGame
```

This copies tools/hooks/docs to `.agents/`, copies skills to both
`.claude/skills/` and `.agents/skills/`, merges the lock-context hook into
`.claude/settings.json` and `.codex/hooks.json`, drops the guidance block at
`.agents/AGENTS.coordination.md`, and gitignores the live lock state. Re-running
is safe (copies overwrite, hook entries de-dupe). Use `-DryRun` to preview.

Opt out of optional pieces with `-SkipDelegation`, `-SkipWorktrees`,
`-SkipLaneTemplate`, or `-NoGitignore`.

After install:

1. Merge `.agents/AGENTS.coordination.md` into your project's AGENTS.md and/or
   `.claude/CLAUDE.md`.
2. If you kept the lane template, edit `agent-iteration-loop/SKILL.md` (both
   copies) to your project's real lanes, work queue, and validation commands.

## Requirements

- **PowerShell 7+** (pwsh) to run the installer; the lock/tool scripts run under
  Windows PowerShell 5.1 or pwsh.
- **git** for the worktree launcher (and for the hook's repo-root detection;
  it falls back to a `ProjectSettings/ProjectVersion.txt` walk-up for non-git
  Unity projects).
- The delegation wrapper assumes the relevant child CLI(s) — `opencode`, `agy`,
  `copilot` — are installed and authenticated. Adjust models/lanes in
  `tools/AgentDelegates/agent-delegates.json` for your setup.

## Conventions

- **Agent identity**: every session/lock/handoff uses a unique `-Agent` value
  (e.g. `claude-opus-ui-pass`), never a bare model/tool name.
- **Unity owns serialization**: never text-patch `.unity`/`.prefab`/`.asset`/
  `.mat`/`.anim`/`ProjectSettings`/`Packages` — use Unity/MCP tooling under the
  matching authoring lock. See `docs/UnitySafety.md`.
- **Locks are state, not history**: claim narrowly, refresh while working,
  release at the slice boundary.

## Package Layout

```
unity-multi-agent/
├─ install.ps1
├─ skills/            unity-multi-agent, agent-locks, agent-worktrees,
│                     agent-delegation, agent-iteration-loop
├─ tools/
│  ├─ AgentLocks/     Enter / Exit / Get-Snapshot / Clear + AgentLock.Common
│  ├─ AgentDelegates/ Invoke-AgentDelegate.ps1 + agent-delegates.json
│  └─ Worktree/       New-AgentWorktree.ps1
├─ hooks/             AgentLockContext.ps1 + claude/ + codex/ snippets
├─ docs/              MultiAgentWorkflow, UnitySafety, AgentHandoffFormat, LockRoot.README
└─ templates/         AGENTS.md guidance block
```
