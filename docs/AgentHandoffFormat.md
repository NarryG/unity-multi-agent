# Agent Handoff Format

Use this format for branch/worktree closeout handoffs when a slice runs in its
own checkout or Unity instance. The handoff is branch-local evidence; your
project's work queue (board, issue tracker, etc.) remains the source of truth
for story state.

`New-AgentWorktree.ps1` writes a starter stub under
`Logs/AgentHandoffs/<safe-branch>/<timestamp>-<story-id>.md`. Update it at
closeout. If a slice runs in the primary worktree, create the same handoff path
manually before merge.

## Required Fields

- `story` — work-item id, or `unassigned`
- `owner` — agent identity or human owner
- `branch` — branch name
- `worktree` — absolute worktree path
- `base` — integration base the branch started from
- `lane` / `domain` — routing labels for your project
- `resources` — named locks held during the slice, or `none`
- `unityAccess` — `none`, `read-only`, `validation`, or `authoring`
- `validationLane` — the proof lane used, or `docs-only`
- `createdAt` / `updatedAt` — ISO 8601 timestamps

## Required Sections

Keep each section compact and current. Do not paste raw logs when a command,
request id, or artifact path proves the point.

### Summary
One to three bullets describing the shipped outcome.

### Touch Points
Files or globs intentionally changed. Add a `Not touched` line for prohibited or
serialized surfaces that were intentionally avoided.

### Resources
Resource lock acquire/refresh/release outcomes, or the explicit reason a lock
remains held for handoff.

### Proof
Exact validation or doc-proof commands and their result. Include known-red or
skipped proof as explicit truth, not implied green.

### Unity And Serialized Assets
State one of: no Unity serialized assets touched; Unity validation skipped
because this was a code/docs-only slice; Unity authoring/validation completed by
the named owner and artifact; or Unity proof blocked by an exact blocker.

### Follow-Up
Next ready work item, blocker, or integration action. Keep it short.

## Template

```markdown
# Agent Handoff

story:
owner:
branch:
worktree:
base:
lane:
domain:
resources:
unityAccess:
validationLane:
createdAt:
updatedAt:

## Summary
- ...

## Touch Points
- Changed: ...
- Not touched: ...

## Resources
- Acquired:
- Refreshed:
- Released:

## Proof
- ...

## Unity And Serialized Assets
- ...

## Follow-Up
- ...
```

## Merge Queue (when multiple branches are ready)

Keep a tiny local merge queue rather than a heavyweight system. Each candidate
branch targets the integration base; the integration owner serializes the final
merge while holding any required global or serialized resource locks.

Merge order, smallest blast radius first:

1. Dependency-unblocking workflow branches (lock/validation/handoff/policy).
2. Code-only branches with disjoint touch points.
3. Branches touching shared validation, policy, packages/project settings,
   Unity editor validation, or serialized authoring — only while holding the
   matching resource locks.
4. Broad mission / ownership-migration branches last unless they unblock
   smaller branches.

Rehearse pairwise ordering before merging two ready branches:

```bash
git merge-tree $(git merge-base <first-branch> <second-branch>) <first-branch> <second-branch>
```

If the rehearsal prints conflicts, rebase/merge one branch locally and re-run
proof before touching the integration base. If clean, merge one, re-prove the
next against the updated base, then merge it.
