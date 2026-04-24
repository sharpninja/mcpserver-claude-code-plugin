<#
.SYNOPSIS
    Workspace-aware cache path resolver (PowerShell parallel of resolve-cache-dir.sh).
.DESCRIPTION
    Cache state belongs to the workspace the marker file lives in, not to
    the plugin install directory. This helper returns the correct cache dir.

    Precedence:
      1. $env:MCP_CACHE_DIR_OVERRIDE    explicit override.
      2. $env:PLUGIN_ROOT_OVERRIDE/cache legacy test hook.
      3. <markerDir>/cache              workspace resolved by walking up for
                                        AGENTS-README-FIRST.yaml.
      4. $env:CLAUDE_PLUGIN_ROOT/cache  last-resort fallback.
#>

$script:ResolveCacheDirScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-McpCacheDir {
    [CmdletBinding()]
    param()

    if ($env:MCP_CACHE_DIR_OVERRIDE) {
        return $env:MCP_CACHE_DIR_OVERRIDE
    }

    if ($env:PLUGIN_ROOT_OVERRIDE) {
        return (Join-Path $env:PLUGIN_ROOT_OVERRIDE 'cache')
    }

    $startDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }

    if (-not (Get-Command Find-MarkerFile -ErrorAction SilentlyContinue)) {
        $resolver = Join-Path $script:ResolveCacheDirScriptDir 'marker-resolver.ps1'
        if (Test-Path $resolver) {
            . $resolver
        }
    }

    if (Get-Command Find-MarkerFile -ErrorAction SilentlyContinue) {
        try {
            $markerFile = Find-MarkerFile -StartDir $startDir
            if ($markerFile) {
                return (Join-Path (Split-Path -Parent $markerFile) 'cache')
            }
        } catch {
            # fall through to plugin-root fallback
        }
    }

    $pluginRoot = if ($env:CLAUDE_PLUGIN_ROOT) {
        $env:CLAUDE_PLUGIN_ROOT
    } else {
        Split-Path -Parent $script:ResolveCacheDirScriptDir
    }
    return (Join-Path $pluginRoot 'cache')
}
