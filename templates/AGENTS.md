<!--
  Multi-Agent Unity Coordination — guidance block.

  Merge these sections into your project's AGENTS.md (and/or .claude/CLAUDE.md).
  They are the project-instruction half of the coordination kit; the runnable
  half is the skills under .agents/skills + .claude/skills and the tools under
  .agents/tools. Trim anything that does not apply to your project.
-->

## Multi-Agent Coordination

This project may have several agent sessions active at once. Coordinate through
the markdown locks under `Logs/AgentLocks/` (scripts in
`.agents/tools/AgentLocks/`). Full protocol: `.agents/docs/MultiAgentWorkflow.md`.
Use the `unity-multi-agent` skill as the entry router.

Operating rule:

1. Inspect `Logs/AgentLocks/` (the `UserPromptSubmit` hook prints a summary; or
   run `.agents/tools/AgentLocks/Get-AgentLockSnapshot.ps1`).
2. If the user requested single-agent / exclusive mode, claim **one**
   `-Exclusive` lock and refresh only that lease. Otherwise claim the narrowest
   relevant scoped lock with `Enter-AgentLock.ps1`.
3. Claim locks at the point of use, not at session start. Never pre-claim or
   "re-acquire" a handoff's locks before the action that needs them is next.
4. Wait ~30s and retry up to 3 times for a conflicting active lock; then report
   the owner, task, scope, files, and `updatedAt` if still blocked.
5. Refresh held locks once per active loop iteration.
6. Always release held locks before ending the turn: `Exit-AgentLock.ps1
   -Status completed`, or `-Status stale` with a `-Loop` note when blocked or
   handed off.

Outside exclusive mode, take `Enter-AgentLock.ps1 -UnityRunner` before any
action that drives Unity (tests, serialization/import checks, Play Mode proof,
AssetDatabase refresh, project-file regeneration, screenshots/proof). The
non-exclusive runner lease is strictly per pass — acquire it immediately before
the action, read that pass's artifacts, release it before doing anything else,
and never hold it across code reading, editing, planning, or waits.

## Branch And Lock Policy

Default to the current shared branch/worktree while the project has one shared
Unity Editor. Use another branch/worktree only when explicitly requested,
integration-owned, or read-only/non-Unity with a recorded merge owner (see the
`agent-worktrees` skill). If branch and lock policy disagree, stay on the shared
branch, claim the narrow lock, and record deferred branch cleanup in the
handoff.

Use `Logs/AgentLocks/` for overlapping same-branch work and for all shared
resources: Unity/editor/proof actions, serialized authoring, package/project
settings, shared runner state, standalone/native proof, and global policy docs.

## Unity Scene And Asset Safety

Never directly text-patch Unity serialized files (`.unity`, `.prefab`,
`.asset`, `.mat`, `.anim`, `ProjectSettings/*`, `Packages/*`) when a Unity-side
editing path exists — use Unity editor tools or Unity MCP so Unity owns
serialization, and save through Unity before claiming a scene change is done.
Direct edits are fine for ordinary text/code. Run the narrowest truthful
validation tier and state skipped Unity/editor proof as an explicit blocker, not
implied green. Full rules: `.agents/docs/UnitySafety.md`.

## Agent Behavior Guardrails

- **Prefer replacement over compatibility.** Do not add compatibility shims,
  legacy aliases, or "old API still works" paths by default. Update callers to
  the new contract and delete the old path. Add a shim only for a named,
  still-supported external consumer or a serialization boundary that cannot be
  migrated in the same slice — and document the consumer and removal condition.
- **Fix behavior in the owning subsystem**, not from controllers, adapters, or
  call sites when a subsystem-owned contract should change.
- **Validate only what you claim.** Use the narrowest proof that truthfully
  covers the change; do not run broad tests by habit or overstate partial proof.
- **Do not memorialize deleted behavior with absence tests.** When removing a
  feature, delete the tests that existed only to prove it. Add a
  negative/regression test only when the absence is itself a durable safety,
  privacy, architecture, or product contract.

## Tooling Notes

- Use a unique `-Agent` identity for every session, lock, and handoff (e.g.
  `claude-opus-ui-pass`), never a bare model/tool/lane name.
- To hand a bounded subtask to a child CLI harness, use the `agent-delegation`
  skill (analysis-only unless writes are explicitly allowed).
- Do not use Unity MCP reflection tools to bypass typed/editor APIs; extend the
  owning typed command, test seam, or editor utility instead.
