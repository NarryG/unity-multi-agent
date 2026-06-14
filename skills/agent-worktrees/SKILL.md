---
name: agent-worktrees
description: Create an isolated git branch + worktree (and a starter handoff stub) so an agent can work on its own checkout and its own Unity Editor instance in parallel with other agents. Use when a slice needs branch isolation, when running several Unity instances at once, or when the user/integration owner explicitly asks for separate-branch work. Covers New-AgentWorktree.ps1 and the closeout handoff format.
---

# Agent Worktrees (multi-instance)

Separate branches/worktrees are an explicit opt-in, not the default. Use them
when a slice wants isolation and a clear merge owner — for example running two
Unity Editors against two checkouts at once. Otherwise prefer the shared
branch + locks (`$agent-locks`).

## Create A Worktree

```powershell
.\.agents\tools\Worktree\New-AgentWorktree.ps1 `
  -Branch claude/ui-settings-card `
  -WorktreePath D:\w\ui-settings-card `
  -Lane ui `
  -Domain product-ui `
  -UnityAccess validation `
  -ExpectedTouchPoints @('Assets/Scripts/UI/*') `
  -AgentId claude-opus-ui-pass `
  -StoryId TASK-123 `
  -BaseRef main
```

This creates the branch from `-BaseRef`, adds a worktree at `-WorktreePath`, and
writes an ignored handoff stub under
`Logs/AgentHandoffs/<safe-branch>/<timestamp>-<story>.md`.

- Use a **short** Windows worktree root such as `D:\w\<task>` to stay under the
  path length limit (or set `git config core.longpaths true`). The script
  refuses paths that would exceed the limit.
- The base worktree must be clean; pass `-AllowDirtyBase` only after accepting
  the risk. Use `-DryRun` to preview without creating anything.
- `-UnityAccess` is one of `none`, `read-only`, `validation`, `authoring`.

The launcher does **not** acquire resource locks. Inside the new worktree, still
use `$agent-locks` before touching the shared Unity Editor or serialized assets
— a separate checkout does not isolate the single shared Unity Editor or
serialized authoring resources.

## Before Editing In The New Worktree

- Update your work queue / story card with Owner, Branch, Worktree, Resources,
  Proof, and Claimed Touch Points.
- Keep edits inside the expected touch points.
- Keep the branch to one coherent slice.

## Closeout

Fill in the handoff stub at the slice boundary using
`.agents/docs/AgentHandoffFormat.md`, then follow the merge-queue ordering in
that doc when more than one branch is ready. Release any held locks after merge
or explicit handoff.
