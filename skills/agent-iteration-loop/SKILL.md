---
name: agent-iteration-loop
description: Template for running a bounded, implementation-first iteration pass on a Unity project with multiple agents — the heartbeat-to-lane routing pattern. Use as the startup router for recurring/automated passes or manual in-thread work: pick one slice, claim the owning lane and its locks, implement, prove with the narrowest truthful validation tier, and close out. ADAPT the lanes, work queue, and validation script names to your project before relying on it.
---

# Agent Iteration Loop (template)

> **Customize me.** This skill is a generic version of a "heartbeat → lane"
> orchestration loop. Replace the lane list, work-queue location, and
> validation/proof commands with your project's real ones, then keep this as the
> startup router for every pass.

Read this first for any recurring or bounded agent pass. It is a compact router,
not a second project plan.

## 1. Read The Active Sources

In order (adapt the paths):

1. The project plan / north-star doc.
2. The active work queue (board, issue tracker, `TODO`, etc.) — the source of
   truth for what to do next.
3. The claimed work item.

## 2. Pick The Mode

- **Bounded pass** — one slice that can truthfully close in one run. Use this
  loop directly.
- **Mission mode** — one larger objective needing multiple stable checkpoint
  boundaries. Escalate when the next truthful step is larger than one slice,
  needs multiple checkpoint commits, or repeated bounded passes would
  fragment the work.

## 3. Pick The Owning Lane

Lanes are project-specific. Define them once, then route each pass to exactly
one. A typical Unity split:

- **main / behavior** — visible runtime behavior, UI, audio, timing,
  feature implementation.
- **validation** — verification and proof routing (`$agent-locks` `-UnityRunner`
  + the validation tiers in `.agents/docs/UnitySafety.md`).
- **integration** — merge ordering, preflight, global-doc sync, post-merge
  cleanup (see merge queue in `.agents/docs/AgentHandoffFormat.md`).
- **ideas / design** — exploration; consider `$agent-delegation` for creative
  handoffs.

Keep ownership at work-item granularity: use the item's claimed touch points and
`$agent-locks` scopes for overlapping files/resources — not project-wide or
task-checklist locks.

## 4. Default Loop

1. Choose one objective from the active sources.
2. Claim the owning lane and its locks via `$agent-locks` (or one `-Exclusive`
   lease in single-agent mode). Coordinate first if a conflicting lock exists.
3. Implement one coherent slice that can be validated truthfully.
4. Run the compile gate before any test run for code/tooling slices. Treat a
   C# build as compile proof only.
5. If the slice touches serialized assets, Unity authoring, MonoBehaviour /
   ScriptableObject serialized shape, asmdefs, packages, ProjectSettings,
   scenes, prefabs, materials, or animators, run the Unity serialization/import
   gate under the Unity-runner lock.
6. Run the narrowest truthful validation tier for what changed
   (`.agents/docs/UnitySafety.md`). Stop and report at the first tier that
   fails or is blocked.
7. Update compact handoff/status docs only when shipped state, validation
   truth, or next guidance changed.
8. Make a checkpoint commit at the stable boundary unless the user said not to,
   or the work is planning-only.
9. Refresh held locks once per loop iteration; release them before ending the
   turn.

## Principles

- Prioritize implementation, validation, or concrete unblocking over status
  narration.
- Prefer clear subsystem ownership and hard removal of obsolete paths over
  compatibility shims.
- Validate only what you claim; do not run broad suites by habit, and do not
  overstate partial proof.
