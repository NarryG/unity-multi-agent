# Multi-Agent Unity Workflow

This is the operating guide for multiple AI agent sessions sharing one Unity
project. It covers two situations:

- **Same checkout, shared Unity Editor** — several agents work in parallel in
  one worktree while one Unity Editor is open. They coordinate with file locks.
- **Separate checkouts / Unity instances** — agents work on their own
  branch/worktree (and their own Unity Editor) and only coordinate over shared
  serialized resources and global policy surfaces.

The mechanism is a set of small markdown lock files under `Logs/AgentLocks/`,
managed by the scripts in `.agents/tools/AgentLocks/`. Locks are coordination
state, not history: claim narrowly, refresh while working, release at the slice
boundary.

## Default Posture

- Prefer one shared branch/worktree while the project has one shared Unity
  Editor. Parallel work on that shared branch is fine when touch points are
  narrow and the relevant locks are held.
- Separate branches/worktrees are an explicit opt-in (use
  `.agents/tools/Worktree/New-AgentWorktree.ps1`). Use them when a task wants
  isolation and the merge owner is clear.
- Unity/editor validation, scene/prefab/asset/profile edits, package/project
  settings, shared test-runner state, and global policy docs are **serialized
  resources**: take the matching lock before the work starts, regardless of
  branch.

## Agent Identity

Every running session, lock, and handoff uses a unique `-Agent` value that
identifies the specific session — not just a model or tool name. Good values:
`codex-gpt5-docs-audit`, `claude-opus-ui-pass`, `opencode-kimi-board-sync`.
Never use a bare `codex`, `claude`, `validation`, or `subagent` when more than
one session may be running. When the session has a thread id (e.g. a Codex
thread), pass `-ThreadId <id>` so conflict reports can route back to the owner.

## Lock Types

The scripts write three kinds of lock under `Logs/AgentLocks/`:

| File | Acquire with | Meaning |
|---|---|---|
| `subsystem-<scope>.md` | `Enter-AgentLock.ps1 -Scope <area>` | Active editing of one durable area / set of files. |
| `unity-runner.md` | `Enter-AgentLock.ps1 -UnityRunner` | The single "drive Unity" lease (tests, Play Mode proof, AssetDatabase refresh, serialization checks, project-file regeneration). Only one agent holds it. |
| `exclusive.md` | `Enter-AgentLock.ps1 -Exclusive -Scope <name>` | Single-agent shortcut. Refuses to start while any other agent holds a lock, and blocks other agents from new scoped locks until released. |

Name subsystem scopes by durable area, not one-off task phrasing:
`docs-routing`, `validation`, `ui`, `audio`, `physics`, `packages-projectsettings`,
`global-policy`, `agent-lock-management`. Reuse stable scope names instead of
minting one-off filenames.

## Operating Rule (compact)

1. Inspect `Logs/AgentLocks/` (the session hook prints a summary; or run
   `.agents/tools/AgentLocks/Get-AgentLockSnapshot.ps1`).
2. If the user requested single-agent / exclusive mode, claim **one**
   `-Exclusive` lock and refresh only that lease. Otherwise claim the narrowest
   relevant scoped lock with `Enter-AgentLock.ps1`.
3. Claim locks at the point of use, not at session start. Do not pre-claim — or
   "re-acquire" a lock named in a handoff — until the concrete action that needs
   it is the very next step.
4. If a conflicting active lock exists, wait ~30s and retry up to 3 times. If it
   still conflicts, report the owner, task, scope, files, and `updatedAt`.
5. Refresh held locks once per active loop iteration.
6. Always release held locks before ending the turn: `Exit-AgentLock.ps1
   -Status completed` when the slice is done, or `-Status stale` with a clear
   `-Loop` note when the goal is blocked or handed off.

## The Unity Runner Lease

Outside exclusive mode, take `-UnityRunner` before any action that drives
Unity: Unity tests, serialization/import checks, Play Mode proof,
screenshots/proof that drive the Editor, AssetDatabase refreshes, or
project-file regeneration.

The non-exclusive runner lease is strictly **per pass**:

- Acquire immediately before the Unity-driving action; inspect that pass's
  immediate artifacts; release with `-Status completed` before doing anything
  else.
- Never hold it across code reading, editing, audits, planning, or waits
  between Unity passes. Release and re-acquire — reacquisition is cheap and
  conflicts resolve through the normal wait/retry rule.
- Do not raise `-TtlMinutes` to cover idle holding. The 5-minute default is the
  intended pass length. When one locked command legitimately runs longer, pass
  it through `-File` / `-ArgumentList` so the lease auto-refreshes while the
  command runs and auto-releases on exit.

Holding a subsystem lock never justifies holding `unity-runner` between proofs.

## Exclusive Mode

When the user wants exactly one active agent in the shared worktree, exclusive
mode is the shortcut that removes routine lock churn. Take one exclusive lock
for the coherent single-agent pass, refresh that one lease while working, and
release it at closeout. Inside the same pass, do **not** also acquire routine
subsystem / validation / Unity-runner / proof locks — the point of exclusive
mode is that nobody else is competing for those resources. The validation tool's
own internal mutex/artifacts still record the actual proof run.

Add a scoped lock during exclusive mode only when the work genuinely introduces
another active owner or a real handoff boundary the exclusive owner does not
control.

```powershell
# acquire
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 `
  -Exclusive -Scope single-agent-session `
  -Agent claude-opus-single-agent `
  -Task 'Run single-agent implementation pass' `
  -TtlMinutes 480 -Loop 'single-agent mode'

# release
.\.agents\tools\AgentLocks\Exit-AgentLock.ps1 `
  -Exclusive -Scope single-agent-session `
  -Agent claude-opus-single-agent `
  -Status completed -Loop 'single-agent pass complete'
```

## Single-Writer Unity Authoring

Unity-owned serialized assets use a single-writer model. Only the agent holding
the matching authoring resource lock applies and commits serialized changes.

Resource locks:

- `unity-prefab-authoring` — prefab / prefab-variant / ScriptableObject profile /
  material / animator / animation and other `Assets/*` Unity-owned saves.
- `unity-scene-authoring` — scene opens, scene object edits, scene saves, scene
  prefab-instance overrides.
- `packages-projectsettings` — `Packages/*`, `ProjectSettings/*`, and the
  generated project graph caused by package/settings changes.
- `unity-editor` — live Editor access for applying, validating, or inspecting
  Unity-owned state.

Code-only agents stop at code, docs, or authoring-intent notes. They do not
text-edit `.unity`, `.prefab`, `.asset`, `.mat`, `.anim`, `ProjectSettings/*`,
or `Packages/*`. Holding a lock is necessary but not sufficient: serialized
changes must still be applied through Unity / editor / MCP tooling, saved
through Unity-owned serialization, and proven with the named proof. See
[UnitySafety.md](UnitySafety.md).

Prefer narrower serialized ownership when it reduces contention: a prefab
variant or a domain-owned ScriptableObject profile is preferable to editing the
global scene or root prefab when it expresses the same behavior.

## Closeout

Before handing off or merging:

- record proof in the work queue / story card or a linked artifact;
- state any skipped Unity/editor proof as an explicit blocker, not implied
  green;
- commit only files for the current slice;
- release any held resource locks after merge or explicit handoff;
- leave a handoff using [AgentHandoffFormat.md](AgentHandoffFormat.md) when the
  slice runs on its own branch/worktree.

## Conflicts and Stale Locks

If a conflicting active lock exists, wait, reread, and retry as above. If
`expiresAt` is in the past, inspect the scope before proceeding. Prefer marking
abandoned locks `stale` or `completed` with a note over deleting them by hand.
`Clear-CompletedLocks.ps1` prunes closed locks after a retention window and
(with `-MarkExpiredActiveStale`) turns long-expired in-progress locks stale; it
never deletes a live `in_progress` lock.

Use `Exit-AgentLock.ps1 -Force -ForceReason <reason>` only after confirming a
foreign lock is genuinely stale or abandoned.
