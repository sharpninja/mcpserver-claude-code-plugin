#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $HOME '.claude/settings.json'),
    [string]$PluginRoot = $(if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).ProviderPath }),
    [switch]$NoBackup,
    [switch]$VerifyOnly
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

function Convert-ToOrderedObject {
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $ordered[[string]$key] = Convert-ToOrderedObject $Value[$key]
        }
        return $ordered
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { Convert-ToOrderedObject $_ })
    }

    return $Value
}

function ConvertTo-HookIdentity {
    param([Parameter(Mandatory)]$HookGroup)

    $matcher = if ($HookGroup.Contains('matcher')) { [string]$HookGroup['matcher'] } else { '' }
    $condition = if ($HookGroup.Contains('if')) { [string]$HookGroup['if'] } else { '' }
    $commands = @()
    if ($HookGroup.Contains('hooks')) {
        foreach ($hook in @($HookGroup['hooks'])) {
            if ($hook -is [System.Collections.IDictionary] -and $hook.Contains('command')) {
                $commands += [string]$hook['command']
            }
        }
    }

    return "$matcher`n$condition`n$($commands -join "`n")"
}

function Add-HookGroups {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$TargetHooks,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceHooks
    )

    $added = 0
    foreach ($eventName in $SourceHooks.Keys) {
        if (-not $TargetHooks.Contains($eventName) -or $null -eq $TargetHooks[$eventName]) {
            $TargetHooks[$eventName] = @()
        }

        $targetGroups = @($TargetHooks[$eventName])
        $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($group in $targetGroups) {
            if ($group -is [System.Collections.IDictionary]) {
                [void]$existing.Add((ConvertTo-HookIdentity -HookGroup $group))
            }
        }

        foreach ($sourceGroup in @($SourceHooks[$eventName])) {
            if ($sourceGroup -isnot [System.Collections.IDictionary]) { continue }
            $identity = ConvertTo-HookIdentity -HookGroup $sourceGroup
            if ($existing.Contains($identity)) { continue }

            $targetGroups += Convert-ToOrderedObject $sourceGroup
            [void]$existing.Add($identity)
            $added++
        }

        $TargetHooks[$eventName] = @($targetGroups)
    }

    return $added
}

function Test-RequiredHooks {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Hooks)

    $required = @('UserPromptSubmit', 'Stop', 'PostToolUse')
    foreach ($eventName in $required) {
        if (-not $Hooks.Contains($eventName) -or @($Hooks[$eventName]).Count -eq 0) {
            throw "Required MCP hook '$eventName' is missing from active Claude settings."
        }
    }
}

$pluginRootFull = (Resolve-Path -LiteralPath $PluginRoot).ProviderPath
$pluginHooksPath = Join-Path $pluginRootFull 'hooks/hooks.json'
if (-not (Test-Path -LiteralPath $pluginHooksPath -PathType Leaf)) {
    throw "Plugin hooks file not found: $pluginHooksPath"
}

$settingsDirectory = Split-Path -Parent $SettingsPath
if (-not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($settingsDirectory)
}

$settings = Convert-ToOrderedObject (Read-JsonObject -Path $SettingsPath)
$pluginHooksDocument = Read-JsonObject -Path $pluginHooksPath
if (-not $pluginHooksDocument.Contains('hooks') -or $pluginHooksDocument['hooks'] -isnot [System.Collections.IDictionary]) {
    throw "Plugin hooks file does not contain a hooks object: $pluginHooksPath"
}

if (-not $settings.Contains('hooks') -or $settings['hooks'] -isnot [System.Collections.IDictionary]) {
    $settings['hooks'] = [ordered]@{}
}

$added = Add-HookGroups -TargetHooks $settings['hooks'] -SourceHooks $pluginHooksDocument['hooks']
Test-RequiredHooks -Hooks $settings['hooks']

if (-not $VerifyOnly) {
    if ((Test-Path -LiteralPath $SettingsPath -PathType Leaf) -and -not $NoBackup) {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-$timestamp" -Force
    }

    $json = ($settings | ConvertTo-Json -Depth 100)
    $json = $json.Replace("`r`n", "`n").Replace("`r", "`n") + "`n"
    [System.IO.File]::WriteAllText($SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
}

[ordered]@{
    status = if ($VerifyOnly) { 'verified' } else { 'updated' }
    settingsPath = (Resolve-Path -LiteralPath $SettingsPath).ProviderPath
    pluginHooksPath = $pluginHooksPath
    addedHookGroups = $added
} | ConvertTo-Json -Depth 10 -Compress
