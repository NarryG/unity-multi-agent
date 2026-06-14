param(
    [string]$Profile,
    [string]$RequestJson,
    [string]$RequestPath,
    [string]$Prompt,
    [string]$PromptFile,
    [string]$ConfigPath,
    [string]$Model,
    [string]$Agent,
    [string]$Harness,
    [string]$CliPath,
    [string]$OutputDir,
    [string]$Attach,
    [switch]$Json,
    [switch]$AllowWrites,
    [switch]$ForceHeadlessAntigravity,
    [switch]$LaunchInteractive,
    [switch]$PrintCommandOnly,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-ProjectRoot {
    # Walk up from the script location to the repository / Unity project root so
    # this wrapper works no matter how deep it is installed.
    $current = $PSScriptRoot
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ((Test-Path -LiteralPath (Join-Path $current ".git")) -or
            (Test-Path -LiteralPath (Join-Path $current "ProjectSettings\ProjectVersion.txt"))) {
            return (Resolve-Path -LiteralPath $current).Path
        }

        $parent = Split-Path -Parent $current
        if ($parent -eq $current) {
            break
        }

        $current = $parent
    }

    # Fallback: current working directory.
    return (Get-Location).ProviderPath
}

function Read-DelegatePrompt {
    param(
        [string]$InlinePrompt,
        [string]$FilePath
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($InlinePrompt)) {
        $parts.Add($InlinePrompt.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $resolved = Resolve-Path -LiteralPath $FilePath
        $parts.Add((Get-Content -LiteralPath $resolved.Path -Raw).Trim())
    }

    if ([Console]::IsInputRedirected) {
        $stdin = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($stdin)) {
            $parts.Add($stdin.Trim())
        }
    }

    return ($parts -join "`n`n")
}

function Read-DelegateRequest {
    param(
        [string]$InlineJson,
        [string]$FilePath
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($InlineJson)) {
        $parts.Add($InlineJson.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $resolved = Resolve-Path -LiteralPath $FilePath
        $parts.Add((Get-Content -LiteralPath $resolved.Path -Raw).Trim())
    }

    if ($parts.Count -gt 1) {
        throw "Pass only one JSON request source: -RequestJson or -RequestPath."
    }

    if ($parts.Count -eq 0) {
        return $null
    }

    return ($parts[0] | ConvertFrom-Json)
}

function Test-HasProperty {
    param(
        [pscustomobject]$Object,
        [string]$Name
    )

    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Get-RequestString {
    param(
        [pscustomobject]$Request,
        [string]$Name,
        [string]$CurrentValue
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    if (Test-HasProperty -Object $Request -Name $Name) {
        return [string]$Request.$Name
    }

    return $CurrentValue
}

function Get-RequestSwitch {
    param(
        [pscustomobject]$Request,
        [string]$Name,
        [bool]$CurrentValue
    )

    if ($CurrentValue) {
        return $true
    }

    if (Test-HasProperty -Object $Request -Name $Name) {
        return [bool]$Request.$Name
    }

    return $false
}

function Get-RequiredProperty {
    param(
        [pscustomobject]$Object,
        [string]$Name
    )

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        throw "Profile is missing required property '$Name'."
    }

    return $Object.$Name
}

function Get-OptionalProperty {
    param(
        [pscustomobject]$Object,
        [string]$Name,
        $DefaultValue
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }

    return $DefaultValue
}

function Add-Argument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $Arguments.Add($Value)
    }
}

function Get-DisplayEnvironment {
    param($Environment)

    $display = @{}
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($entry.Key -match "(?i)(key|token|secret|password)") {
            $display[$entry.Key] = if ([string]::IsNullOrWhiteSpace([string]$entry.Value) -or ([string]$entry.Value).StartsWith("<set ")) { [string]$entry.Value } else { "<redacted>" }
        } else {
            $display[$entry.Key] = $entry.Value
        }
    }

    return $display
}

function Get-StringArrayProperty {
    param(
        [pscustomobject]$Object,
        [string]$Name,
        [string[]]$DefaultValue
    )

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        return $DefaultValue
    }

    $value = $Object.$Name
    if ($null -eq $value) {
        return $DefaultValue
    }

    if ($value -is [array]) {
        return @($value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @([string]$value)
}

function ConvertTo-QuotedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $all = @($FilePath) + @($Arguments)
    return (($all | ForEach-Object {
        $value = [string]$_
        if ($value -match '^[A-Za-z0-9_./:=@+-]+$') {
            return $value
        }

        return "'" + ($value -replace "'", "''") + "'"
    }) -join " ")
}

function New-InteractiveLauncher {
    param(
        [string]$LauncherPath,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$PromptPath,
        [string]$Harness
    )

    $encodedArguments = @($Arguments | ForEach-Object {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_))
    })

    $encodedFilePath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($FilePath))
    $encodedPromptPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PromptPath))
    $encodedHarness = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Harness))
    $encodedArray = ($encodedArguments | ForEach-Object { "    '$_'" }) -join ",`n"

    $script = @"
`$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Decode-DelegateValue {
    param([string]`$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Value))
}

`$harness = Decode-DelegateValue '$encodedHarness'
`$filePath = Decode-DelegateValue '$encodedFilePath'
`$promptPath = Decode-DelegateValue '$encodedPromptPath'
`$arguments = @(
$encodedArray
) | ForEach-Object { Decode-DelegateValue `$_ }

Write-Host "Agent delegate interactive launcher"
Write-Host "Harness: `$harness"
Write-Host "Prompt:  `$promptPath"
Write-Host ""

if (`$harness -eq "antigravity") {
    Write-Host "Antigravity headless stdout is not reliable under non-TTY capture."
    Write-Host "This launcher runs agy in an interactive terminal and passes the prompt as the initial interactive prompt."
    Write-Host ""
}

& `$filePath @arguments
`$exitCode = if (`$LASTEXITCODE -is [int]) { `$LASTEXITCODE } else { 0 }
Write-Host ""
Write-Host "Delegate exited with code `$exitCode."
Write-Host "Press Enter to close this window."
[void][Console]::ReadLine()
exit `$exitCode
"@

    Set-Content -LiteralPath $LauncherPath -Value $script -Encoding UTF8
}

function Get-RoundRobinSecret {
    param(
        [string[]]$EnvironmentVariableNames,
        [string]$StatePath,
        [bool]$RequireSecrets
    )

    $available = New-Object System.Collections.Generic.List[object]
    foreach ($name in $EnvironmentVariableNames) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, "User")
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, "Machine")
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $available.Add([pscustomobject]@{
                Name = $name
                Value = $value
            })
        }
    }

    if ($available.Count -eq 0) {
        $expected = ($EnvironmentVariableNames -join ", ")
        if ($RequireSecrets) {
            throw "Profile '$Profile' needs at least one configured API key environment variable. Expected one of: $expected"
        }

        $displayName = if ($EnvironmentVariableNames.Count -gt 0) { $EnvironmentVariableNames[0] } else { "AGENT_DELEGATE_API_KEY" }
        return [pscustomobject]@{
            Name = $displayName
            Value = "<set $displayName>"
            Index = -1
            Count = 0
        }
    }

    $lastIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath)) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ($state.PSObject.Properties.Name -contains "lastIndex") {
                $lastIndex = [int]$state.lastIndex
            }
        } catch {
            $lastIndex = -1
        }
    }

    $nextIndex = ($lastIndex + 1) % $available.Count
    $selected = $available[$nextIndex]

    if ($RequireSecrets -and -not [string]::IsNullOrWhiteSpace($StatePath)) {
        $stateDir = Split-Path -Parent $StatePath
        if (-not [string]::IsNullOrWhiteSpace($stateDir)) {
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        }

        [pscustomobject]@{
            lastIndex = $nextIndex
            selectedEnvironmentVariable = $selected.Name
            availableCount = $available.Count
            updatedAt = (Get-Date).ToString("o")
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }

    return [pscustomobject]@{
        Name = $selected.Name
        Value = $selected.Value
        Index = $nextIndex
        Count = $available.Count
    }
}

function Build-OpencodeInvocation {
    param(
        [pscustomobject]$ProfileConfig,
        [string]$SelectedCliPath,
        [string]$SelectedModel,
        [string]$SelectedAgent,
        [string]$ProjectRoot,
        [string]$PromptPath,
        [string]$Title,
        [string]$AttachUrl,
        [bool]$UseJson,
        [bool]$CanWrite
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("run")
    $args.Add("--dir")
    $args.Add($ProjectRoot)
    $args.Add("--model")
    $args.Add($SelectedModel)
    $args.Add("--title")
    $args.Add($Title)

    $agent = if ([string]::IsNullOrWhiteSpace($SelectedAgent)) { Get-OptionalProperty -Object $ProfileConfig -Name "agent" -DefaultValue $null } else { $SelectedAgent }
    if (-not [string]::IsNullOrWhiteSpace($agent)) {
        $args.Add("--agent")
        $args.Add($agent)
    }

    if (-not [string]::IsNullOrWhiteSpace($AttachUrl)) {
        $args.Add("--attach")
        $args.Add($AttachUrl)
    }

    if ($UseJson) {
        $args.Add("--format")
        $args.Add("json")
    }

    if ($CanWrite) {
        $args.Add("Execute the attached delegation prompt. Keep the scope bounded and report changed files plus validation.")
    } else {
        $args.Add("Read the attached delegation prompt and return analysis only. Do not edit files or run destructive commands.")
    }

    $args.Add("--file")
    $args.Add($PromptPath)

    return [pscustomobject]@{
        FilePath = $SelectedCliPath
        Arguments = $args.ToArray()
        Environment = @{}
        Metadata = @{}
    }
}

function Build-AntigravityInvocation {
    param(
        [pscustomobject]$ProfileConfig,
        [string]$SelectedCliPath,
        [string]$SelectedModel,
        [string]$ProjectRoot,
        [string]$PromptPath,
        [string]$LogPath,
        [string]$PromptText,
        [bool]$CanWrite,
        [bool]$Headless
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("--add-dir")
    $args.Add($ProjectRoot)
    $args.Add("--log-file")
    $args.Add($LogPath)

    $extraArgs = Get-OptionalProperty -Object $ProfileConfig -Name "args" -DefaultValue @()
    foreach ($arg in $extraArgs) {
        Add-Argument -Arguments $args -Value ([string]$arg)
    }

    if ($CanWrite) {
        $autoApprove = [bool](Get-OptionalProperty -Object $ProfileConfig -Name "dangerouslySkipPermissionsWhenWriting" -DefaultValue $false)
        if ($autoApprove) {
            $args.Add("--dangerously-skip-permissions")
        }
    }

    if ($Headless) {
        $args.Add("--print")
    } else {
        $args.Add("--prompt-interactive")
    }

    $args.Add($PromptText)

    return [pscustomobject]@{
        FilePath = $SelectedCliPath
        Arguments = $args.ToArray()
        Environment = @{}
        Metadata = @{
            ConfiguredModelLabel = $SelectedModel
            PromptPath = $PromptPath
            LogPath = $LogPath
            HeadlessCaptureIssue = "google-antigravity/antigravity-cli#76"
            RequiresInteractiveTerminal = (-not $Headless)
            InvocationMode = if ($Headless) { "headless-print" } else { "interactive-handoff" }
        }
    }
}

function Build-CopilotInvocation {
    param(
        [pscustomobject]$ProfileConfig,
        [string]$SelectedCliPath,
        [string]$SelectedModel,
        [string]$ProjectRoot,
        [string]$PromptPath,
        [string]$PromptText,
        [string]$Title,
        [bool]$UseJson,
        [bool]$CanWrite,
        [bool]$RequireSecrets
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("-C")
    $args.Add($ProjectRoot)
    $args.Add("--model")
    $args.Add($SelectedModel)
    $args.Add("--name")
    $args.Add($Title)
    $args.Add("--secret-env-vars")
    $args.Add("COPILOT_PROVIDER_API_KEY,OPENCODE_GO_API_KEY_1,OPENCODE_GO_API_KEY_2,OPENCODE_GO_API_KEY")

    if ($UseJson) {
        $args.Add("--output-format")
        $args.Add("json")
    } else {
        $args.Add("--silent")
    }

    if ($CanWrite) {
        $args.Add("--autopilot")
    }

    $extraArgs = Get-OptionalProperty -Object $ProfileConfig -Name "args" -DefaultValue @()
    foreach ($arg in $extraArgs) {
        Add-Argument -Arguments $args -Value ([string]$arg)
    }

    $args.Add("-p")
    $args.Add($PromptText)

    $apiKeyEnvNames = Get-StringArrayProperty -Object $ProfileConfig -Name "apiKeyEnvironmentVariables" -DefaultValue @((Get-OptionalProperty -Object $ProfileConfig -Name "apiKeyEnvironmentVariable" -DefaultValue "OPENCODE_GO_API_KEY"))
    $statePath = Get-OptionalProperty -Object $ProfileConfig -Name "roundRobinStatePath" -DefaultValue $null
    if (-not [string]::IsNullOrWhiteSpace($statePath) -and -not [System.IO.Path]::IsPathRooted($statePath)) {
        $statePath = Join-Path $ProjectRoot $statePath
    }

    $selectedApiKey = Get-RoundRobinSecret -EnvironmentVariableNames $apiKeyEnvNames -StatePath $statePath -RequireSecrets $RequireSecrets

    return [pscustomobject]@{
        FilePath = $SelectedCliPath
        Arguments = $args.ToArray()
        Environment = @{
            COPILOT_PROVIDER_TYPE = (Get-OptionalProperty -Object $ProfileConfig -Name "providerType" -DefaultValue "openai")
            COPILOT_PROVIDER_BASE_URL = (Get-OptionalProperty -Object $ProfileConfig -Name "providerBaseUrl" -DefaultValue "https://opencode.ai/zen/go/v1")
            COPILOT_PROVIDER_API_KEY = $selectedApiKey.Value
            COPILOT_MODEL = $SelectedModel
        }
        Metadata = @{
            SelectedApiKeyEnvironmentVariable = $selectedApiKey.Name
            ApiKeyPoolCount = $selectedApiKey.Count
            RoundRobinStatePath = $statePath
        }
    }
}

$projectRoot = Resolve-ProjectRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "agent-delegates.json"
}

$resolvedConfig = Resolve-Path -LiteralPath $ConfigPath
$config = Get-Content -LiteralPath $resolvedConfig.Path -Raw | ConvertFrom-Json
$request = Read-DelegateRequest -InlineJson $RequestJson -FilePath $RequestPath

$Profile = Get-RequestString -Request $request -Name "profile" -CurrentValue $Profile
$Prompt = Get-RequestString -Request $request -Name "prompt" -CurrentValue $Prompt
$PromptFile = Get-RequestString -Request $request -Name "promptFile" -CurrentValue $PromptFile
$Model = Get-RequestString -Request $request -Name "model" -CurrentValue $Model
$Agent = Get-RequestString -Request $request -Name "agent" -CurrentValue $Agent
$Harness = Get-RequestString -Request $request -Name "harness" -CurrentValue $Harness
$CliPath = Get-RequestString -Request $request -Name "cliPath" -CurrentValue $CliPath
$OutputDir = Get-RequestString -Request $request -Name "outputDir" -CurrentValue $OutputDir
$Attach = Get-RequestString -Request $request -Name "attach" -CurrentValue $Attach
$shouldUseJson = Get-RequestSwitch -Request $request -Name "json" -CurrentValue $Json.IsPresent
$shouldAllowWrites = Get-RequestSwitch -Request $request -Name "allowWrites" -CurrentValue $AllowWrites.IsPresent
$shouldForceHeadlessAntigravity = Get-RequestSwitch -Request $request -Name "forceHeadlessAntigravity" -CurrentValue $ForceHeadlessAntigravity.IsPresent
$shouldLaunchInteractive = Get-RequestSwitch -Request $request -Name "launchInteractive" -CurrentValue $LaunchInteractive.IsPresent
$shouldPrintCommandOnly = Get-RequestSwitch -Request $request -Name "printCommandOnly" -CurrentValue $PrintCommandOnly.IsPresent
$shouldDryRun = Get-RequestSwitch -Request $request -Name "dryRun" -CurrentValue $DryRun.IsPresent

if ([string]::IsNullOrWhiteSpace($Profile)) {
    if ([string]::IsNullOrWhiteSpace($Harness) -or [string]::IsNullOrWhiteSpace($CliPath) -or [string]::IsNullOrWhiteSpace($Model)) {
        throw "No profile provided. Pass -Profile, request.profile, or an ad hoc request with harness, cliPath, and model."
    }

    $Profile = if (Test-HasProperty -Object $request -Name "name") { [string]$request.name } else { "adhoc-$Harness" }
    $profileConfig = [pscustomobject]@{
        description = if (Test-HasProperty -Object $request -Name "description") { [string]$request.description } else { "Ad hoc delegate request." }
        harness = $Harness
        cliPath = $CliPath
        model = $Model
        agent = $Agent
        lane = if (Test-HasProperty -Object $request -Name "lane") { [string]$request.lane } else { "adhoc" }
        useCase = if (Test-HasProperty -Object $request -Name "useCase") { [string]$request.useCase } else { "adhoc" }
        systemPrompt = if (Test-HasProperty -Object $request -Name "systemPrompt") { [string]$request.systemPrompt } else { "You are a bounded side agent. Follow the prompt exactly and return concise results." }
    }
} else {
    if ($config.profiles.PSObject.Properties.Name -notcontains $Profile) {
        $known = ($config.profiles.PSObject.Properties.Name | Sort-Object) -join ", "
        throw "Unknown delegate profile '$Profile'. Known profiles: $known"
    }

    $profileConfig = $config.profiles.$Profile
}

$selectedHarness = if ([string]::IsNullOrWhiteSpace($Harness)) { Get-RequiredProperty -Object $profileConfig -Name "harness" } else { $Harness }
$selectedCliPath = if ([string]::IsNullOrWhiteSpace($CliPath)) { Get-RequiredProperty -Object $profileConfig -Name "cliPath" } else { $CliPath }
$selectedModel = if ([string]::IsNullOrWhiteSpace($Model)) { Get-RequiredProperty -Object $profileConfig -Name "model" } else { $Model }
$selectedAgent = if ([string]::IsNullOrWhiteSpace($Agent)) { Get-OptionalProperty -Object $profileConfig -Name "agent" -DefaultValue $null } else { $Agent }

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $defaultOutput = Get-OptionalProperty -Object $config.defaults -Name "outputDir" -DefaultValue "Logs/AgentDelegates"
    $OutputDir = Join-Path $projectRoot $defaultOutput
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$taskPrompt = Read-DelegatePrompt -InlinePrompt $Prompt -FilePath $PromptFile
if ([string]::IsNullOrWhiteSpace($taskPrompt)) {
    throw "No prompt provided. Pass -Prompt, -PromptFile, or pipe text into this wrapper."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeProfile = $Profile -replace "[^A-Za-z0-9_.-]", "-"
$promptPath = Join-Path $OutputDir "delegate-$safeProfile-prompt-$timestamp.md"
$stdoutPath = Join-Path $OutputDir "delegate-$safeProfile-stdout-$timestamp.txt"
$stderrPath = Join-Path $OutputDir "delegate-$safeProfile-stderr-$timestamp.txt"
$resultPath = Join-Path $OutputDir "delegate-$safeProfile-result-$timestamp.json"
$launcherPath = Join-Path $OutputDir "delegate-$safeProfile-launch-$timestamp.ps1"
$antigravityLogPath = Join-Path $OutputDir "delegate-$safeProfile-agy-log-$timestamp.txt"

$description = Get-OptionalProperty -Object $profileConfig -Name "description" -DefaultValue ""
$useCase = Get-OptionalProperty -Object $profileConfig -Name "useCase" -DefaultValue $Profile
$systemPrompt = Get-OptionalProperty -Object $profileConfig -Name "systemPrompt" -DefaultValue ""
$writePolicy = if ($shouldAllowWrites) { "Writes are allowed only inside the requested scope." } else { "Analysis only unless the parent explicitly reruns with allowWrites." }

$fullPrompt = @"
# Agent Delegate Prompt

profile: $Profile
harness: $selectedHarness
model: $selectedModel
useCase: $useCase
description: $description
projectRoot: $projectRoot
writePolicy: $writePolicy

## System Role

$systemPrompt

## Repository Rules

- Follow AGENTS.md and any active project docs named by the task.
- Coordinate through Logs/AgentLocks before touching the shared Unity Editor or serialized assets.
- Keep scope narrow and do not disturb unrelated dirty work.
- Return a concise final status with changed files, validation, and blockers.

## Parent Task

$($taskPrompt.Trim())
"@

Set-Content -LiteralPath $promptPath -Value $fullPrompt -Encoding UTF8

switch ($selectedHarness.ToLowerInvariant()) {
    "opencode" {
        $invocation = Build-OpencodeInvocation -ProfileConfig $profileConfig -SelectedCliPath $selectedCliPath -SelectedModel $selectedModel -SelectedAgent $selectedAgent -ProjectRoot $projectRoot -PromptPath $promptPath -Title $safeProfile -AttachUrl $Attach -UseJson $shouldUseJson -CanWrite $shouldAllowWrites
    }
    "antigravity" {
        if (-not ($shouldPrintCommandOnly -or $shouldDryRun -or $shouldLaunchInteractive -or $shouldForceHeadlessAntigravity)) {
            throw "Antigravity CLI is not safe as a captured subprocess right now: google-antigravity/antigravity-cli#76 reports that print/headless mode can return exit 0 with empty stdout under non-TTY capture. Use -LaunchInteractive to start an interactive terminal handoff, -PrintCommandOnly to inspect the launcher/command, or pass -ForceHeadlessAntigravity if you intentionally want to test the current CLI behavior."
        }

        $invocation = Build-AntigravityInvocation -ProfileConfig $profileConfig -SelectedCliPath $selectedCliPath -SelectedModel $selectedModel -ProjectRoot $projectRoot -PromptPath $promptPath -LogPath $antigravityLogPath -PromptText $fullPrompt -CanWrite $shouldAllowWrites -Headless $shouldForceHeadlessAntigravity
    }
    "copilot" {
        $invocation = Build-CopilotInvocation -ProfileConfig $profileConfig -SelectedCliPath $selectedCliPath -SelectedModel $selectedModel -ProjectRoot $projectRoot -PromptPath $promptPath -PromptText $fullPrompt -Title $safeProfile -UseJson $shouldUseJson -CanWrite $shouldAllowWrites -RequireSecrets (-not ($shouldPrintCommandOnly -or $shouldDryRun))
    }
    default {
        throw "Unsupported harness '$selectedHarness'. Supported harnesses: antigravity, opencode, copilot."
    }
}

$plan = [pscustomobject]@{
    Profile = $Profile
    Harness = $selectedHarness
    Model = $selectedModel
    Agent = $selectedAgent
    FilePath = $invocation.FilePath
    Arguments = $invocation.Arguments
    Command = ConvertTo-QuotedCommand -FilePath $invocation.FilePath -Arguments $invocation.Arguments
    Environment = Get-DisplayEnvironment -Environment $invocation.Environment
    Metadata = $invocation.Metadata
    PromptPath = $promptPath
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
    ResultPath = $resultPath
    LauncherPath = $launcherPath
    AllowWrites = $shouldAllowWrites
    ForceHeadlessAntigravity = $shouldForceHeadlessAntigravity
    LaunchInteractive = $shouldLaunchInteractive
}

if (($selectedHarness.ToLowerInvariant() -eq "antigravity") -and -not $shouldForceHeadlessAntigravity) {
    New-InteractiveLauncher -LauncherPath $launcherPath -FilePath $invocation.FilePath -Arguments $invocation.Arguments -PromptPath $promptPath -Harness "antigravity"
}

if ($shouldPrintCommandOnly -or $shouldDryRun) {
    $plan | ConvertTo-Json -Depth 8
    exit 0
}

if ($shouldLaunchInteractive) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", $launcherPath)

    $result = [pscustomobject]@{
        ExitCode = $null
        Status = "launched-interactive"
        Profile = $Profile
        Harness = $selectedHarness
        Model = $selectedModel
        Metadata = $invocation.Metadata
        PromptPath = $promptPath
        LauncherPath = $launcherPath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }

    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 6
    exit 0
}

$startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
$runningResult = [pscustomobject]@{
    ExitCode = $null
    Status = "running"
    Profile = $Profile
    Harness = $selectedHarness
    Model = $selectedModel
    Metadata = $invocation.Metadata
    PromptPath = $promptPath
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
    StartedAtUtc = $startedAtUtc
    WrapperProcessId = $PID
    Command = $plan.Command
}

$runningResult | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8

$previousEnv = @{}
foreach ($entry in $invocation.Environment.GetEnumerator()) {
    $previousEnv[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, "Process")
}

try {
    $argumentList = $invocation.Arguments
    & $invocation.FilePath @argumentList > $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
} finally {
    foreach ($entry in $previousEnv.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

$result = [pscustomobject]@{
    ExitCode = $exitCode
    Status = "completed"
    Profile = $Profile
    Harness = $selectedHarness
    Model = $selectedModel
    Metadata = $invocation.Metadata
    PromptPath = $promptPath
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
    StartedAtUtc = $startedAtUtc
    FinishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    WrapperProcessId = $PID
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 6
exit $exitCode
