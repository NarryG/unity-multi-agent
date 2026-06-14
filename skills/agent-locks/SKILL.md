---
name: agent-locks
description: Claim, refresh, and release the file-based coordination locks that let multiple agents share one Unity project. Use whenever you are about to edit a shared subsystem or overlapping files, drive the Unity Editor (tests, Play Mode, serialization/import checks, AssetDatabase refresh, project-file regeneration), or run in single-agent exclusive mode. Covers the Enter/Exit/Snapshot/Clear scripts under .agents/tools/AgentLocks and the scoped / unity-runner / exclusive lock types.
---

# Agent Locks

Lightweight markdown coordination locks live under `Logs/AgentLocks/`. The
scripts in `.agents/tools/AgentLocks/` own the schema — never hand-author lock
bodies. Full protocol: `.agents/docs/MultiAgentWorkflow.md`.

## The Three Lock Types

| File | Acquire | When |
|---|---|---|
| `subsystem-<scope>.md` | `Enter-AgentLock.ps1 -Scope <area>` | Active editing of a durable area / set of files. |
| `unity-runner.md` | `Enter-AgentLock.ps1 -UnityRunner` | The single shared "drive Unity" lease. Only one holder. |
| `exclusive.md` | `Enter-AgentLock.ps1 -Exclusive -Scope <name>` | Single-agent mode — blocks all other locks. |

Name scopes by durable area, not task phrasing: `ui`, `audio`, `physics`,
`docs-routing`, `packages-projectsettings`, `global-policy`.

## Claim / Refresh

```powershell
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 `
  -Scope ui `
  -Agent claude-opus-ui-pass `
  -Task 'Implement settings overlay card' `
  -Files @('Assets/Scripts/UI/SettingsCard.cs') `
  -Loop 'editing settings card'
```

- Refresh by running the same command again once per loop iteration.
- Optional: `-ThreadId <id>` (routes conflict reports back to your thread),
  `-TtlMinutes <n>` (default 30; Unity-runner default 5).

## Release

```powershell
.\.agents\tools\AgentLocks\Exit-AgentLock.ps1 `
  -Scope ui -Agent claude-opus-ui-pass `
  -Status completed -Loop 'card shipped and proven'
```

Use `-Status stale` with a `-Loop` note when the goal is blocked or handed off
instead of finished.

## Unity Runner (per pass)

Acquire immediately before the Unity-driving action, read that pass's
artifacts, then release before doing anything else. Never hold it across code
reading, editing, planning, or waits between passes.

```powershell
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 -UnityRunner `
  -Agent claude-opus-ui-pass -Task 'EditMode proof for settings card' `
  -Loop 'running focused proof'
# ...run the proof, read artifacts...
.\.agents\tools\AgentLocks\Exit-AgentLock.ps1 -UnityRunner `
  -Agent claude-opus-ui-pass -Status completed -Loop 'proof recorded'
```

For a long-running locked command, pass it through the script so the lease
auto-refreshes during the run and auto-releases on exit:

```powershell
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 -UnityRunner `
  -Agent <id> -Task 'full suite' `
  -File .\Tools\RunTests.ps1 -ArgumentList '-Suite','EditMode'
```

## Exclusive Mode (single agent)

```powershell
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 -Exclusive -Scope single-agent-session `
  -Agent claude-opus-single-agent -Task 'single-agent pass' -TtlMinutes 480
# ...work, refreshing only this lease...
.\.agents\tools\AgentLocks\Exit-AgentLock.ps1 -Exclusive -Scope single-agent-session `
  -Agent claude-opus-single-agent -Status completed
```

In exclusive mode, do not also take routine subsystem / unity-runner / proof
locks — the exclusive lease is the coordination lock for the whole pass.

## Conflicts

If `Enter` exits non-zero with a `conflict` / `exclusive-conflict` report, wait
~30s and retry up to 3 times. If it still conflicts, report the existing
owner's `agent`, `scope`, `task`, `files`, and `updatedAt`. Only use
`-Force -ForceReason <reason>` after confirming the foreign lock is genuinely
stale or abandoned.

## Inspect / Clean Up

```powershell
.\.agents\tools\AgentLocks\Get-AgentLockSnapshot.ps1          # read-only JSON summary
.\.agents\tools\AgentLocks\Clear-CompletedLocks.ps1           # prune closed locks past retention
```

`Clear-CompletedLocks.ps1` never deletes an in-progress lock; add
`-MarkExpiredActiveStale` to turn long-expired in-progress locks stale.
