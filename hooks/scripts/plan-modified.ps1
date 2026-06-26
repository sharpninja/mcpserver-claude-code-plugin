#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pluginRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '../..')).ProviderPath
$env:MCP_PLUGIN_ROOT = $pluginRoot
$env:MCP_PLUGIN_HOST = 'claude-code'

& (Join-Path $pluginRoot 'lib\plugin-hook.ps1') -HookName 'plan-modified' -HostName 'claude-code' -CacheMode 'flat' @RemainingArguments
if (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue) {
    exit $global:LASTEXITCODE
}

exit 0
