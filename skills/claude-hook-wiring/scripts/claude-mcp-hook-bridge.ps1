#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ScriptName,

    [string]$PluginRootHint,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PluginRootForHook {
    param(
        [AllowNull()]
        [string]$CandidateRoot,

        [Parameter(Mandatory)]
        [string]$HookScriptName
    )

    if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $CandidateRoot -PathType Container)) {
        return $null
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $CandidateRoot).ProviderPath
    $hookPath = Join-Path $resolvedRoot (Join-Path 'hooks/scripts' $HookScriptName)
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
        return $null
    }

    return [ordered]@{
        root = $resolvedRoot
        hookPath = $hookPath
    }
}

function Resolve-CurrentPluginRoot {
    param([Parameter(Mandatory)][string]$HookScriptName)

    $candidates = [System.Collections.Generic.List[string]]::new()
    $rootPointerPath = Join-Path $PSScriptRoot 'current-plugin-root.txt'
    if (Test-Path -LiteralPath $rootPointerPath -PathType Leaf) {
        $pointerValue = [System.IO.File]::ReadAllText($rootPointerPath).Trim()
        if (-not [string]::IsNullOrWhiteSpace($pointerValue)) {
            [void]$candidates.Add($pointerValue)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_ROOT)) {
        [void]$candidates.Add($env:CLAUDE_PLUGIN_ROOT)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MCP_PLUGIN_ROOT)) {
        [void]$candidates.Add($env:MCP_PLUGIN_ROOT)
    }

    if (-not [string]::IsNullOrWhiteSpace($PluginRootHint)) {
        [void]$candidates.Add($PluginRootHint)
    }

    foreach ($candidate in $candidates) {
        $resolved = Test-PluginRootForHook -CandidateRoot $candidate -HookScriptName $HookScriptName
        if ($null -ne $resolved) {
            return $resolved
        }
    }

    $candidateText = ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join '; '
    throw "Unable to resolve a current Claude MCP plugin root for hook '$HookScriptName'. Checked: $candidateText. Re-run the claude-hook-validation skill to refresh active hooks."
}

if ($ScriptName.IndexOfAny([char[]]@('/', '\')) -ge 0 -or -not $ScriptName.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Invalid Claude MCP hook script name '$ScriptName'."
}

$resolvedPlugin = Resolve-CurrentPluginRoot -HookScriptName $ScriptName
$env:CLAUDE_PLUGIN_ROOT = [string]$resolvedPlugin.root
$env:MCP_PLUGIN_ROOT = [string]$resolvedPlugin.root
$env:MCP_PLUGIN_HOST = 'claude-code'

& ([string]$resolvedPlugin.hookPath) @RemainingArguments
if (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue) {
    exit $global:LASTEXITCODE
}

exit 0
