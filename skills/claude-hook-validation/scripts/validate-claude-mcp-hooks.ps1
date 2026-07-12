#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $HOME '.claude/settings.json'),
    [string]$PluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).ProviderPath,
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
function Get-RequiredHookSpecs {
    return @(
        @{ EventName = 'UserPromptSubmit'; ScriptName = 'user-prompt-submit.ps1'; Fragments = @('claude-mcp-hook-bridge.ps1', 'user-prompt-submit.ps1') },
        @{ EventName = 'Stop'; ScriptName = 'stop-gate.ps1'; Fragments = @('claude-mcp-hook-bridge.ps1', 'stop-gate.ps1') },
        @{ EventName = 'PostToolUse'; ScriptName = 'code-verify.ps1'; Fragments = @('claude-mcp-hook-bridge.ps1', 'code-verify.ps1') }
    )
}

function Get-HookScriptNameFromCommand {
    param([AllowNull()][string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $null
    }

    $match = [regex]::Match($Command, '(?i)(?:hooks[\\/]+scripts[\\/]+|-ScriptName\s+["'']?)(?<script>[A-Za-z0-9._-]+\.ps1)')
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['script'].Value
}

function Get-PluginName {
    param([Parameter(Mandatory)][string]$PluginRoot)

    $manifestPath = Join-Path $PluginRoot '.claude-plugin/plugin.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-JsonObject -Path $manifestPath
        if ($manifest.Contains('name') -and -not [string]::IsNullOrWhiteSpace([string]$manifest['name'])) {
            return [string]$manifest['name']
        }
    }

    return Split-Path -Leaf $PluginRoot
}

function Test-PluginEnabled {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$PluginRoot
    )

    $pluginName = Get-PluginName -PluginRoot $PluginRoot
    if ($Settings.Contains('enabledPlugins')) {
        foreach ($entry in @($Settings['enabledPlugins'])) {
            $value = [string]$entry
            if ([string]::Equals($value, $pluginName, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($value, 'mcpserver', [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($value, $PluginRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_ROOT)) {
        try {
            $envRoot = (Resolve-Path -LiteralPath $env:CLAUDE_PLUGIN_ROOT -ErrorAction Stop).ProviderPath
            $pluginRootFull = (Resolve-Path -LiteralPath $PluginRoot -ErrorAction Stop).ProviderPath
            return [string]::Equals($envRoot.TrimEnd('\'), $pluginRootFull.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
        } catch {
            return $false
        }
    }

    return $false
}

function Test-HooksContainScript {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Hooks,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$ScriptName
    )

    if (-not $Hooks.Contains($EventName)) {
        return $false
    }

    foreach ($group in @($Hooks[$EventName])) {
        if ($group -isnot [System.Collections.IDictionary] -or -not $group.Contains('hooks')) {
            continue
        }

        foreach ($hook in @($group['hooks'])) {
            if ($hook -isnot [System.Collections.IDictionary] -or -not $hook.Contains('command')) {
                continue
            }

            $candidate = Get-HookScriptNameFromCommand -Command ([string]$hook['command'])
            if ([string]::Equals($candidate, $ScriptName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    return $false
}

function Test-PluginHookCommand {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$PluginRoot,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$ScriptName
    )

    if (-not (Test-PluginEnabled -Settings $Settings -PluginRoot $PluginRoot)) {
        return $false
    }

    $pluginHooksPath = Join-Path $PluginRoot 'hooks/hooks.json'
    if (-not (Test-Path -LiteralPath $pluginHooksPath -PathType Leaf)) {
        return $false
    }

    $pluginHooksDocument = Read-JsonObject -Path $pluginHooksPath
    if (-not $pluginHooksDocument.Contains('hooks') -or $pluginHooksDocument['hooks'] -isnot [System.Collections.IDictionary]) {
        return $false
    }

    return Test-HooksContainScript -Hooks $pluginHooksDocument['hooks'] -EventName $EventName -ScriptName $ScriptName
}

function Test-HookCommand {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string[]]$CommandFragments
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

            $command = [string]$hook['command']
            $missingFragment = $false
            foreach ($fragment in $CommandFragments) {
                if ($command -notlike "*$fragment*") {
                    $missingFragment = $true
                    break
                }
            }

            if (-not $missingFragment) {
                return $true
            }
        }
    }

    return $false
}

function Get-MissingHookCommands {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$PluginRoot
    )

    $required = Get-RequiredHookSpecs

    $missing = @()
    foreach ($requirement in $required) {
        if (-not (Test-HookCommand -Settings $Settings -EventName $requirement.EventName -CommandFragments $requirement.Fragments) -and
            -not (Test-PluginHookCommand -Settings $Settings -PluginRoot $PluginRoot -EventName $requirement.EventName -ScriptName $requirement.ScriptName)) {
            $missing += "$($requirement.EventName):$($requirement.Fragments -join '+')"
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
$missingBefore = @(Get-MissingHookCommands -Settings $settingsBefore -PluginRoot $pluginRootFull)
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
$missingAfter = @(Get-MissingHookCommands -Settings $settingsAfter -PluginRoot $pluginRootFull)
$status = if ($missingAfter.Count -eq 0) { 'installed' } else { 'missing' }

[ordered]@{
    status = $status
    settingsPath = (Resolve-Path -LiteralPath $SettingsPath).ProviderPath
    missingHooks = $missingAfter
    restartRequired = ($status -eq 'installed')
} | ConvertTo-Json -Depth 10 -Compress
