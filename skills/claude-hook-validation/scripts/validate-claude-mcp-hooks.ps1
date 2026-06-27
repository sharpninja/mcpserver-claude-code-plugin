#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $HOME '.claude/settings.json'),
    [string]$PluginRoot = $(if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).ProviderPath }),
    [switch]$CheckOnly,
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{}
    }

    $content = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($content)) {
        return [ordered]@{}
    }

    return $content | ConvertFrom-Json -AsHashtable -Depth 100
}

function Test-HookCommand {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$CommandFragment
    )

    if (-not $Settings.Contains('hooks') -or $Settings['hooks'] -isnot [System.Collections.IDictionary]) {
        return $false
    }

    $hooks = $Settings['hooks']
    if (-not $hooks.Contains($EventName)) {
        return $false
    }

    foreach ($group in @($hooks[$EventName])) {
        if ($group -isnot [System.Collections.IDictionary] -or -not $group.Contains('hooks')) {
            continue
        }

        foreach ($hook in @($group['hooks'])) {
            if ($hook -isnot [System.Collections.IDictionary] -or -not $hook.Contains('command')) {
                continue
            }

            if ([string]$hook['command'] -like "*$CommandFragment*") {
                return $true
            }
        }
    }

    return $false
}

function Get-MissingHookCommands {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $required = @(
        @{ EventName = 'UserPromptSubmit'; Fragment = 'user-prompt-submit.ps1' },
        @{ EventName = 'Stop'; Fragment = 'stop-gate.ps1' },
        @{ EventName = 'PostToolUse'; Fragment = 'code-verify.ps1' }
    )

    $missing = @()
    foreach ($requirement in $required) {
        if (-not (Test-HookCommand -Settings $Settings -EventName $requirement.EventName -CommandFragment $requirement.Fragment)) {
            $missing += "$($requirement.EventName):$($requirement.Fragment)"
        }
    }

    return $missing
}

$pluginRootFull = (Resolve-Path -LiteralPath $PluginRoot).ProviderPath
$installerPath = Join-Path $pluginRootFull 'skills/claude-hook-wiring/scripts/install-claude-mcp-hooks.ps1'
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Claude hook wiring installer not found: $installerPath"
}

$settingsBefore = Read-JsonObject -Path $SettingsPath
$missingBefore = @(Get-MissingHookCommands -Settings $settingsBefore)
if ($missingBefore.Count -eq 0) {
    [ordered]@{
        status = 'valid'
        settingsPath = if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) { (Resolve-Path -LiteralPath $SettingsPath).ProviderPath } else { $SettingsPath }
        missingHooks = @()
        restartRequired = $false
    } | ConvertTo-Json -Depth 10 -Compress
    return
}

if ($CheckOnly) {
    [ordered]@{
        status = 'missing'
        settingsPath = $SettingsPath
        missingHooks = $missingBefore
        restartRequired = $false
    } | ConvertTo-Json -Depth 10 -Compress
    return
}

$installerArgs = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-File',
    $installerPath,
    '-SettingsPath',
    $SettingsPath,
    '-PluginRoot',
    $pluginRootFull
)
if ($NoBackup) {
    $installerArgs += '-NoBackup'
}

& pwsh @installerArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Claude hook wiring installer failed with exit code $LASTEXITCODE."
}

$settingsAfter = Read-JsonObject -Path $SettingsPath
$missingAfter = @(Get-MissingHookCommands -Settings $settingsAfter)
$status = if ($missingAfter.Count -eq 0) { 'installed' } else { 'missing' }

[ordered]@{
    status = $status
    settingsPath = (Resolve-Path -LiteralPath $SettingsPath).ProviderPath
    missingHooks = $missingAfter
    restartRequired = ($status -eq 'installed')
} | ConvertTo-Json -Depth 10 -Compress
