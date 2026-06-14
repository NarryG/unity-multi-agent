---
name: agent-delegation
description: Route a bounded subtask from the current (parent) agent to a child CLI harness — OpenCode, Antigravity, or GitHub Copilot — through a single PowerShell wrapper and a profile registry. Use when you want to hand a narrow, well-specified task (a focused review, a scratch implementation, a doc scan, a creative/design exploration) to a cheaper, narrower, or differently-skilled model while keeping prompts and outputs auditable. Child agents are analysis-only unless writes are explicitly allowed.
---

# Agent Delegation

`.agents/tools/AgentDelegates/Invoke-AgentDelegate.ps1` is a thin, mechanical
launcher for child-agent CLI harnesses. Profiles live in
`.agents/tools/AgentDelegates/agent-delegates.json`. Prompts and outputs are
written under `Logs/AgentDelegates/` so the parent can inspect what happened.

Use it only after you have **decomposed** the work into a narrow task with a
clear prompt, expected files, and validation requirement. Do not hand broad
ownership work to a child agent.

## Guardrails

- Child agents run **analysis-only** unless you pass `-AllowWrites`.
- Preview a new profile with `-PrintCommandOnly` before first real use.
- Antigravity headless capture is unreliable; Antigravity profiles run as
  interactive terminal handoffs (`-LaunchInteractive`) or print-only.
- Never store API keys in `agent-delegates.json`; the wrapper reads them from
  environment variables.
- A delegated child still coordinates through `Logs/AgentLocks` before touching
  the shared Unity Editor or serialized assets.

## Common Calls

Focused review of the current diff (no edits):

```powershell
.\.agents\tools\AgentDelegates\Invoke-AgentDelegate.ps1 `
  -Profile opencode-go-review `
  -Prompt 'Review the current branch diff and the claimed handoff. Findings first, by severity, with file refs. Do not edit.' `
  -Json
```

Inspect the exact command without launching anything:

```powershell
.\.agents\tools\AgentDelegates\Invoke-AgentDelegate.ps1 `
  -Profile opencode-go-defined-task `
  -PromptFile .\Logs\AgentDelegates\next-small-task.md `
  -PrintCommandOnly
```

Allow a bounded child to edit:

```powershell
.\.agents\tools\AgentDelegates\Invoke-AgentDelegate.ps1 `
  -Profile opencode-go-defined-task `
  -PromptFile .\Logs\AgentDelegates\next-small-task.md `
  -AllowWrites
```

Creative/design handoff through Antigravity (interactive terminal):

```powershell
.\.agents\tools\AgentDelegates\Invoke-AgentDelegate.ps1 `
  -Profile creative-antigravity `
  -Prompt 'Generate three concrete designs for X. Tradeoffs included. Do not edit.' `
  -LaunchInteractive
```

Or pass a JSON request file:

```powershell
.\.agents\tools\AgentDelegates\Invoke-AgentDelegate.ps1 `
  -RequestPath .\.agents\tools\AgentDelegates\delegate-review.request.example.json
```

## Adding A Profile

Extend `agent-delegates.json` with a profile that sets at least `harness`
(`opencode` | `antigravity` | `copilot`), `cliPath`, `model`, `lane`,
`useCase`, and `systemPrompt`. Harness-specific optional keys include `agent`,
`args`, `providerBaseUrl`, `apiKeyEnvironmentVariables`, and
`roundRobinStatePath`. The shipped profiles assume OpenCode / Antigravity /
Copilot CLIs are installed and authenticated; adjust models and lanes to your
own setup before relying on them.
