#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Invoke', 'CompleteTurn')]
    [string]$Command = 'Status',

    [string]$Method,

    [string]$Params,

    [string]$ParamsPath,

    [string]$Response,

    [string]$ResponsePath,

    [string]$WorkspacePath = $(if ($env:MCP_WORKSPACE_PATH) { $env:MCP_WORKSPACE_PATH } elseif ($env:MCPSERVER_WORKSPACE_PATH) { $env:MCPSERVER_WORKSPACE_PATH } elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).ProviderPath }),

    [string]$PluginRoot = $(if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { Split-Path -Parent $PSScriptRoot }),

    [string]$CacheRoot,

    [string]$BashPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return $resolved.ProviderPath
}

function Resolve-OptionalDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }

    return (Resolve-FullPath $Path)
}

function Resolve-BashExecutable {
    param([string]$Candidate)

    if ($Candidate) {
        return (Resolve-FullPath $Candidate)
    }

    if ($env:BASH -and (Test-Path -LiteralPath $env:BASH)) {
        return (Resolve-FullPath $env:BASH)
    }

    $gitBash = Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'
    if (Test-Path -LiteralPath $gitBash) {
        return $gitBash
    }

    $command = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $fallback = Get-Command bash -ErrorAction SilentlyContinue
    if ($fallback) {
        return $fallback.Source
    }

    throw 'Unable to find bash. Install Git for Windows or pass -BashPath.'
}

function ConvertTo-BashPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FullPath $Path
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2] -replace '\\', '/'
        return "/$drive/$tail"
    }

    return ($full -replace '\\', '/')
}

function Read-RedirectedInput {
    if ([Console]::IsInputRedirected) {
        return [Console]::In.ReadToEnd()
    }

    return ''
}

function Read-OptionalText {
    param(
        [string]$Inline,
        [bool]$HasInline,
        [string]$Path,
        [switch]$AllowRedirectedInput
    )

    if ($Path) {
        return [System.IO.File]::ReadAllText((Resolve-FullPath $Path))
    }

    if ($HasInline) {
        return $Inline
    }

    if ($AllowRedirectedInput) {
        return (Read-RedirectedInput)
    }

    return ''
}

function Invoke-BashPluginScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$StandardInput = ''
    )

    $bash = Resolve-BashExecutable $BashPath
    $pluginRootFull = Resolve-FullPath $PluginRoot
    $workspaceFull = Resolve-OptionalDirectory $WorkspacePath
    $cacheRootFull = if ($CacheRoot) {
        Resolve-OptionalDirectory $CacheRoot
    } elseif ($env:PLUGIN_ROOT_OVERRIDE) {
        Resolve-OptionalDirectory $env:PLUGIN_ROOT_OVERRIDE
    } else {
        $pluginRootFull
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $bash
    $startInfo.WorkingDirectory = $workspaceFull
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add((ConvertTo-BashPath $ScriptPath))
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['CLAUDE_PLUGIN_ROOT'] = $pluginRootFull
    $startInfo.Environment['PLUGIN_ROOT_OVERRIDE'] = $cacheRootFull
    $startInfo.Environment['MCP_WORKSPACE_PATH'] = $workspaceFull
    $startInfo.Environment['MCPSERVER_WORKSPACE_PATH'] = $workspaceFull
    $startInfo.Environment['CLAUDE_PROJECT_DIR'] = $workspaceFull

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    if ($StandardInput.Length -gt 0) {
        $process.StandardInput.Write($StandardInput)
    }
    $process.StandardInput.Close()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stderr.Length -gt 0) {
        [Console]::Error.Write($stderr)
    }

    if ($process.ExitCode -ne 0) {
        throw "Plugin command failed with exit code $($process.ExitCode)."
    }

    if ($stdout.Length -gt 0) {
        Write-Output ($stdout.TrimEnd("`r", "`n"))
    }
}

$pluginRootFull = Resolve-FullPath $PluginRoot

switch ($Command) {
    'Status' {
        Invoke-BashPluginScript -ScriptPath (Join-Path $pluginRootFull 'lib\mcp.claude.status.sh')
    }
    'Invoke' {
        if (-not $Method) {
            throw '-Method is required when -Command Invoke is used.'
        }

        $paramsText = Read-OptionalText -Inline $Params -HasInline:$($PSBoundParameters.ContainsKey('Params')) -Path $ParamsPath -AllowRedirectedInput
        Invoke-BashPluginScript -ScriptPath (Join-Path $pluginRootFull 'lib\repl-invoke.sh') -Arguments @($Method) -StandardInput ($paramsText ?? '')
    }
    'CompleteTurn' {
        $responseText = Read-OptionalText -Inline $Response -HasInline:$($PSBoundParameters.ContainsKey('Response')) -Path $ResponsePath -AllowRedirectedInput
        if (-not $responseText) {
            $responseText = 'Turn completed.'
        }

        Invoke-BashPluginScript -ScriptPath (Join-Path $pluginRootFull 'lib\final-response.sh') -StandardInput $responseText
    }
}
