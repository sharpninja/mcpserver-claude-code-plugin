#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$StateRoot = (Join-Path $HOME '.claude\hooks\state')
)

$ErrorActionPreference = 'SilentlyContinue'

if ($env:CLAUDE_SYNC_HOOK_SKIP -eq '1') { exit 0 }

function Get-HookValue {
    param(
        $Payload,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Payload) { return $null }
    foreach ($name in $Names) {
        if ($Payload -is [System.Collections.IDictionary] -and $Payload.Contains($name)) {
            return $Payload[$name]
        }

        $property = $Payload.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }

    return $null
}

function ConvertTo-Bool {
    param($Value)

    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $false }
    return [string]$Value -ieq 'true'
}

function Get-StatePath {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$TranscriptPath
    )

    $inputText = "$SessionId|$TranscriptPath"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($inputText)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hash = [Convert]::ToHexString($hashBytes).ToLowerInvariant()
    return Join-Path $StateRoot "sync-log-stop-$hash.json"
}

function Read-State {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 20
    } catch {
        return $null
    }
}

function Write-State {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$TranscriptPath,
        [Parameter(Mandatory)][long]$Length,
        [Parameter(Mandatory)][string]$LastWriteTimeUtc
    )

    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($StateRoot)
    }

    $state = [ordered]@{
        sessionId = $SessionId
        transcriptPath = $TranscriptPath
        length = $Length
        lastWriteTimeUtc = $LastWriteTimeUtc
        reconciledAtUtc = (Get-Date).ToUniversalTime().ToString('O')
    }
    [System.IO.File]::WriteAllText($Path, ($state | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function Read-TranscriptSegment {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset
    )

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($Offset -gt 0 -and $Offset -lt $stream.Length) { [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin) }
            elseif ($Offset -ge $stream.Length) { return '' }
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 4096, $false)
            return $reader.ReadToEnd()
        } finally {
            $stream.Dispose()
        }
    } catch {
        return ''
    }
}

function Test-MaterialTranscriptChange {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '"tool_use"' -or $Text -match '"tool_result"') { return $true }
    return $Text -match '"name"\s*:\s*"(Write|Edit|MultiEdit|NotebookEdit|Bash|Shell|PowerShell|pwsh|Task|Skill|TodoWrite|mcp_[^"]+|workflow\.[^"]+)"'
}

$raw = [Console]::In.ReadToEnd()
$payload = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try { $payload = $raw | ConvertFrom-Json -AsHashtable -Depth 100 } catch { $payload = $null }
}

$stopHookActive = ConvertTo-Bool (Get-HookValue -Payload $payload -Names @('stop_hook_active', 'stopHookActive'))
$transcriptPath = [string](Get-HookValue -Payload $payload -Names @('transcript_path', 'transcriptPath'))
$sessionId = [string](Get-HookValue -Payload $payload -Names @('session_id', 'sessionId'))
if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'claude-code' }

if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
    exit 0
}

$transcriptFull = (Resolve-Path -LiteralPath $transcriptPath).ProviderPath
$statePath = Get-StatePath -SessionId $sessionId -TranscriptPath $transcriptFull
$file = Get-Item -LiteralPath $transcriptFull
$length = [long]$file.Length
$lastWrite = $file.LastWriteTimeUtc.ToString('O')

if ($stopHookActive) {
    Write-State -Path $statePath -SessionId $sessionId -TranscriptPath $transcriptFull -Length $length -LastWriteTimeUtc $lastWrite
    exit 0
}

$state = Read-State -Path $statePath
$previousLength = 0L
if ($state -and $state.Contains('length')) { [void][long]::TryParse([string]$state['length'], [ref]$previousLength) }
if ($state -and $previousLength -eq $length -and [string]$state['lastWriteTimeUtc'] -eq $lastWrite) {
    exit 0
}
if ($previousLength -lt 0 -or $previousLength -gt $length) { $previousLength = 0L }

$segment = Read-TranscriptSegment -Path $transcriptFull -Offset $previousLength
if (-not (Test-MaterialTranscriptChange -Text $segment)) {
    Write-State -Path $statePath -SessionId $sessionId -TranscriptPath $transcriptFull -Length $length -LastWriteTimeUtc $lastWrite
    exit 0
}

$reason = 'Before ending the turn, run the sync-logs skill once to reconcile new MCP relevant tool activity. Leave the active turn open, print the compact Sync Logs summary, then stop. Do not begin new work and do not duplicate already logged records.'
[Console]::Out.Write(([ordered]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress))
exit 0
