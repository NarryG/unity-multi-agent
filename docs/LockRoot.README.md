# Agent Locks

Short-lived coordination files live here so multiple agent sessions can share
one checkout and one Unity Editor safely. The scripts in
`.agents/tools/AgentLocks/` own the lock file schema; do not hand-author lock
bodies here.

Keep this README small. It is startup guidance, not a place to paste lock
bodies, handoffs, or long examples. Live lock files in this folder are
disposable coordination state and are typically gitignored.

## Defaults

- Use the current shared branch/worktree by default while the project has one
  shared Unity Editor.
- Same-branch agents lock overlapping edit scopes and shared files.
- Different-branch agents do not need subsystem locks just because branches
  exist, but they still lock shared resources.
- Shared resources include the Unity Editor, Unity validation, serialized Unity
  assets, package/project settings, standalone/native proof, shared runner
  state, and global policy docs.
- Exclusive mode is the single-agent shortcut: when one agent owns
  `exclusive.md`, it refreshes that one lock and skips routine subsystem,
  validation, Unity-runner, and proof locks inside the same coherent pass.
- Locks are coordination state, not history. Close them when the slice is done.

## Use The Scripts

```powershell
# claim or refresh a subsystem lock
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 `
  -Scope docs-routing `
  -Agent claude-opus-docs-audit `
  -Task "Update active docs routes" `
  -Files @("docs/Routing.md") `
  -Loop "checking stale route references"

# close it
.\.agents\tools\AgentLocks\Exit-AgentLock.ps1 `
  -Scope docs-routing `
  -Agent claude-opus-docs-audit `
  -Status completed `
  -Loop "updated routes and recorded validation"

# the single Unity-runner lease (outside exclusive mode)
.\.agents\tools\AgentLocks\Enter-AgentLock.ps1 -UnityRunner -Agent <id> -Task <task>

# prune closed locks after retention
.\.agents\tools\AgentLocks\Clear-CompletedLocks.ps1
```

See `.agents/docs/MultiAgentWorkflow.md` for the full protocol.
