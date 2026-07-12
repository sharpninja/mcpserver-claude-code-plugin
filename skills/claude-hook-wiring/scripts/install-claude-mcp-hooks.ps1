#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $HOME '.claude/settings.json'),
    [string]$PluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).ProviderPath,
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

function ConvertTo-CommandArgument {
    param([Parameter(Mandatory)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
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
function Get-RequiredHookSpecs {
    return @(
        @{ EventName = 'UserPromptSubmit'; ScriptName = 'user-prompt-submit.ps1' },
        @{ EventName = 'Stop'; ScriptName = 'stop-gate.ps1' },
        @{ EventName = 'PostToolUse'; ScriptName = 'code-verify.ps1' }
    )
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

function Test-PluginHookCoverage {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$PluginRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$PluginHooks
    )

    if (-not (Test-PluginEnabled -Settings $Settings -PluginRoot $PluginRoot)) {
        return $false
    }

    foreach ($requirement in Get-RequiredHookSpecs) {
        if (-not (Test-HooksContainScript -Hooks $PluginHooks -EventName $requirement.EventName -ScriptName $requirement.ScriptName)) {
            return $false
        }
    }

    return $true
}

function New-StableHookCommand {
    param(
        [Parameter(Mandatory)][string]$BridgePath,
        [Parameter(Mandatory)][string]$HookScriptName,
        [Parameter(Mandatory)][string]$PluginRootHint
    )

    $bridgeArg = ConvertTo-CommandArgument -Value $BridgePath
    $scriptArg = ConvertTo-CommandArgument -Value $HookScriptName
    $rootArg = ConvertTo-CommandArgument -Value $PluginRootHint
    return "pwsh -NoLogo -NoProfile -NonInteractive -File $bridgeArg -ScriptName $scriptArg -PluginRootHint $rootArg"
}

function ConvertTo-StableHookGroup {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$HookGroup,
        [Parameter(Mandatory)][string]$BridgePath,
        [Parameter(Mandatory)][string]$PluginRootHint
    )

    $converted = Convert-ToOrderedObject $HookGroup
    if (-not $converted.Contains('hooks')) {
        return $converted
    }

    $convertedHooks = @()
    foreach ($hook in @($converted['hooks'])) {
        if ($hook -isnot [System.Collections.IDictionary]) {
            $convertedHooks += $hook
            continue
        }

        $hookCopy = Convert-ToOrderedObject $hook
        $scriptName = if ($hookCopy.Contains('command')) { Get-HookScriptNameFromCommand -Command ([string]$hookCopy['command']) } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($scriptName)) {
            $hookCopy['command'] = New-StableHookCommand -BridgePath $BridgePath -HookScriptName $scriptName -PluginRootHint $PluginRootHint
        }

        $convertedHooks += $hookCopy
    }

    $converted['hooks'] = @($convertedHooks)
    return $converted
}

function Remove-ManagedHookCommands {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$TargetHooks)

    foreach ($eventName in @($TargetHooks.Keys)) {
        $retainedGroups = @()
        foreach ($group in @($TargetHooks[$eventName])) {
            if ($group -isnot [System.Collections.IDictionary] -or -not $group.Contains('hooks')) {
                $retainedGroups += $group
                continue
            }

            $groupCopy = Convert-ToOrderedObject $group
            $retainedCommands = @()
            foreach ($hook in @($groupCopy['hooks'])) {
                if ($hook -isnot [System.Collections.IDictionary] -or -not $hook.Contains('command')) {
                    $retainedCommands += $hook
                    continue
                }

                $scriptName = Get-HookScriptNameFromCommand -Command ([string]$hook['command'])
                if ([string]::IsNullOrWhiteSpace($scriptName)) {
                    $retainedCommands += $hook
                }
            }

            if ($retainedCommands.Count -gt 0) {
                $groupCopy['hooks'] = @($retainedCommands)
                $retainedGroups += $groupCopy
            }
        }

        if ($retainedGroups.Count -gt 0) {
            $TargetHooks[$eventName] = @($retainedGroups)
        } else {
            $TargetHooks.Remove($eventName)
        }
    }
}

function Add-HookGroups {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$TargetHooks,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceHooks,
        [Parameter(Mandatory)][string]$BridgePath,
        [Parameter(Mandatory)][string]$PluginRootHint
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
            $stableSourceGroup = ConvertTo-StableHookGroup -HookGroup $sourceGroup -BridgePath $BridgePath -PluginRootHint $PluginRootHint
            $identity = ConvertTo-HookIdentity -HookGroup $stableSourceGroup
            if ($existing.Contains($identity)) { continue }

            $targetGroups += $stableSourceGroup
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

$stableHookDirectory = Join-Path $settingsDirectory 'hooks/mcpserver'
if (-not (Test-Path -LiteralPath $stableHookDirectory -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($stableHookDirectory)
}

$bridgeSourcePath = Join-Path $pluginRootFull 'skills/claude-hook-wiring/scripts/claude-mcp-hook-bridge.ps1'
if (-not (Test-Path -LiteralPath $bridgeSourcePath -PathType Leaf)) {
    throw "Claude hook bridge source not found: $bridgeSourcePath"
}

$stableBridgePath = Join-Path $stableHookDirectory 'claude-mcp-hook-bridge.ps1'

$settings = Convert-ToOrderedObject (Read-JsonObject -Path $SettingsPath)
$pluginHooksDocument = Read-JsonObject -Path $pluginHooksPath
if (-not $pluginHooksDocument.Contains('hooks') -or $pluginHooksDocument['hooks'] -isnot [System.Collections.IDictionary]) {
    throw "Plugin hooks file does not contain a hooks object: $pluginHooksPath"
}

if (-not $settings.Contains('hooks') -or $settings['hooks'] -isnot [System.Collections.IDictionary]) {
    $settings['hooks'] = [ordered]@{}
}

$pluginHooksCoverRequired = Test-PluginHookCoverage -Settings $settings -PluginRoot $pluginRootFull -PluginHooks $pluginHooksDocument['hooks']
if ($pluginHooksCoverRequired) {
    Remove-ManagedHookCommands -TargetHooks $settings['hooks']
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
        status = if ($VerifyOnly) { 'verified' } else { 'plugin-hooks' }
        settingsPath = (Resolve-Path -LiteralPath $SettingsPath).ProviderPath
        pluginHooksPath = $pluginHooksPath
        bridgePath = ''
        addedHookGroups = 0
    } | ConvertTo-Json -Depth 10 -Compress
    return
}

Remove-ManagedHookCommands -TargetHooks $settings['hooks']
$added = Add-HookGroups -TargetHooks $settings['hooks'] -SourceHooks $pluginHooksDocument['hooks'] -BridgePath $stableBridgePath -PluginRootHint $pluginRootFull
Test-RequiredHooks -Hooks $settings['hooks']

if (-not $VerifyOnly) {
    if ((Test-Path -LiteralPath $SettingsPath -PathType Leaf) -and -not $NoBackup) {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-$timestamp" -Force
    }

    Copy-Item -LiteralPath $bridgeSourcePath -Destination $stableBridgePath -Force
    [System.IO.File]::WriteAllText((Join-Path $stableHookDirectory 'current-plugin-root.txt'), $pluginRootFull, [System.Text.UTF8Encoding]::new($false))

    $json = ($settings | ConvertTo-Json -Depth 100)
    $json = $json.Replace("`r`n", "`n").Replace("`r", "`n") + "`n"
    [System.IO.File]::WriteAllText($SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
}

[ordered]@{
    status = if ($VerifyOnly) { 'verified' } else { 'updated' }
    settingsPath = (Resolve-Path -LiteralPath $SettingsPath).ProviderPath
    pluginHooksPath = $pluginHooksPath
    bridgePath = $stableBridgePath
    addedHookGroups = $added
} | ConvertTo-Json -Depth 10 -Compress
