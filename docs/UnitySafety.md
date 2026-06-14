# Unity Scene And Asset Safety

These rules keep Unity the owner of its own serialized data when multiple agents
edit one project. They pair with the single-writer authoring locks in
[MultiAgentWorkflow.md](MultiAgentWorkflow.md).

## Let Unity Own Serialization

- Never directly text-patch Unity serialized scene or asset files — `.unity`,
  `.prefab`, `.asset`, `.mat`, `.anim` — when a Unity-side editing path exists.
- For scene, prefab, transform, component, and override changes, use Unity
  editor tools or Unity MCP commands so Unity owns serialization.
- After any Unity scene change, explicitly save the open scene through Unity
  (`scene-save`, `Unity_ManageScene Save`, or `EditorSceneManager.SaveOpenScenes`)
  before claiming the change is complete.
- Do not normalize Unity-generated serialized whitespace just to satisfy a
  generic whitespace check. Unity folder `.meta` files commonly carry
  empty-field trailing spaces such as `assetBundleName: ` and
  `assetBundleVariant: `; leave those semantics-owned values alone unless Unity
  itself rewrites them.
- Direct file edits are fine for ordinary text/code: `.cs`, `.md`, `.json`,
  `.yaml`, and similar non-Unity-source assets.

## Validation Tiers

Run the narrowest truthful tier that covers the change, in order. Stop and
report at the first tier that fails or is blocked rather than running a later
tier as if it supersedes the missing one.

0. **docs-only** — docs, prompt, or skill text with no code/tool behavior claim.
   `git diff --check` is enough for whitespace proof.
1. **compile-code** — C#/script compile or parser proof. A `dotnet build` proves
   compile only, not Unity import/serialization or runtime behavior.
2. **unity-serialization** — serialized assets, Unity authoring, Unity-loaded
   type shape, asmdefs, packages, ProjectSettings, scenes, prefabs, materials,
   animators, or script add/remove/rename/split. Run under the Unity-runner lock
   (or the exclusive lease).
3. **focused-behavior** — the smallest truthful behavior lane (edit-mode pure,
   edit-mode editor, play-mode scene, standalone/native, etc.).
4. **broad-confidence** — broader suite/standalone proof only when integration
   risk or checkpoint scope justifies it.

Proof truth rules:

- After Unity/editor/player actions, check for blocking modals before calling a
  run failed, stalled, or clean. If Unity MCP jams or times out after an action,
  inspect the actual Editor window for a modal before retrying or restarting.
- A passing batch/headless run is batch proof only. Do not describe it as live
  Editor or scene-view validation.
- `selected: 0` / `total: 0` / `NoTestsMatched` means "tests did not run" — not
  a pass. Verify the loaded namespace/class/method from the test source, then
  rerun the exact full name. Do not widen a focused run to make it green.
- Nonzero output is partial evidence only. Retry or apply scoped fixes when
  obvious; otherwise record `blocked` / `partial` with the command, artifact,
  blocker, attempted recovery, and next step.
- If live proof is required but skipped, state the exact blocker instead of
  calling the slice validated.

## Coordinate / Projection Ownership (pattern)

Unity projects routinely mix coordinate spaces — world, local, screen/client
pixels, GUI rects, virtual-desktop/window rects. Treat them as distinct spaces
and route conversions through shared owner helpers rather than ad hoc per-call
math (sign flips, screen-height subtraction, one-off X/Y tweaks). When touching
a coordinate path, identify the source space, target space, and the owning
helper before changing code, and prefer explicit space names in variables and
helpers when a conversion crosses more than one space. Adapt the specific helper
names to your project.

## Do Not Use Reflection To Bypass Typed APIs

Do not use Unity MCP reflection tools or reflection-driven commands to bypass
typed/editor APIs. If a needed surface is not exposed, add or extend the owning
typed command, test seam, or editor utility instead of calling private project
code through reflection.
