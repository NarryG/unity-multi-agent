---
name: unity-multi-agent
description: Coordinate multiple AI agents working on one Unity project — either several sessions sharing one checkout and Unity Editor, or agents spread across separate branches/worktrees and Unity instances. Use at the start of any agent session in a Unity project that has the .agents coordination kit installed, and whenever you are about to edit shared files, drive the Unity Editor, run tests, or touch serialized assets while another session may be active. Routes to the lock protocol, worktree launcher, delegation wrapper, and Unity safety rules.
---

# Unity Multi-Agent Coordination

This project uses a file-lock coordination kit so multiple agent sessions share
one Unity project without clobbering each other's edits, Unity Editor state, or
serialized assets.

Two situations this covers:

- **Shared checkout + one Unity Editor** — coordinate every overlapping edit and
  every Unity-driving action with locks.
- **Separate branches/worktrees + separate Unity instances** — coordinate only
  shared serialized resources and global policy surfaces.

## At Session Start

1. Read the current lock state. The `UserPromptSubmit` hook prints a summary; if
   you need it on demand run:
   ```powershell
   .\.agents\tools\AgentLocks\Get-AgentLockSnapshot.ps1
   ```
2. Choose one coherent slice of work.
3. Use a **unique** agent identity for this session (e.g.
   `claude-opus-<task>`), never a bare model/tool name. See
   `.agents/docs/MultiAgentWorkflow.md` → Agent Identity.

## Before You Act, Pick The Lane

- **About to edit a shared subsystem / overlapping files?** → use
  `$agent-locks`: claim `Enter-AgentLock.ps1 -Scope <area>`, refresh once per
  loop, release at the slice boundary.
- **About to drive Unity** (tests, Play Mode, serialization/import checks,
  AssetDatabase refresh, project-file regeneration, screenshots/proof)? → use
  `$agent-locks` with `-UnityRunner` (per-pass), then read
  `.agents/docs/UnitySafety.md` for the validation tiers and proof-truth rules.
- **User wants exactly one active agent?** → take one `-Exclusive` lease and
  skip routine scoped locks (see `$agent-locks`).
- **Need an isolated branch / separate Unity instance for a slice?** → use
  `$agent-worktrees`.
- **Want to hand a bounded subtask to a cheaper/narrower child agent?** → use
  `$agent-delegation`.
- **Running a recurring heartbeat/lane loop?** → use `$agent-iteration-loop`.

## Hard Rules

- Claim locks at the point of use, never at session start, and never
  "re-acquire" a handoff's locks before the action that needs them is the very
  next step.
- Never text-edit `.unity`, `.prefab`, `.asset`, `.mat`, `.anim`,
  `ProjectSettings/*`, or `Packages/*` — let Unity own serialization
  (`.agents/docs/UnitySafety.md`).
- Always release held locks before ending the turn (`-Status completed`, or
  `-Status stale` with a note when blocked/handed off).
- State skipped Unity/editor proof as an explicit blocker, never implied green.

## Reference

- `.agents/docs/MultiAgentWorkflow.md` — full protocol (lock types, exclusive
  mode, single-writer Unity authoring, closeout, merge queue).
- `.agents/docs/UnitySafety.md` — Unity serialization safety + validation tiers.
- `.agents/docs/AgentHandoffFormat.md` — branch/worktree closeout handoffs.
