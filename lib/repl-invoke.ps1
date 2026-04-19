<#
.SYNOPSIS
    Sends a YAML request envelope to mcpserver-repl --agent-stdio.
.DESCRIPTION
    PowerShell parallel of lib/repl-invoke.sh. Constructs a YAML envelope
    and pipes it to the mcpserver-repl dotnet tool.

    Translation shim: workflow.sessionlog.* methods are not server routes
    — the dispatcher rejects them as method_not_found. They are plugin-
    local verbs that update cache/current-turn.yaml so the Stop hook can
    verify completion, and (best-effort) persist a session-log turn via
    the real client.SessionLog.SubmitAsync route.

    Two usage modes:
      1. Script entry: pwsh -File repl-invoke.ps1 -Method <m> [-ParamsYaml <y>]
      2. Dot-source for Invoke-ReplMethod cmdlet:
             . .\repl-invoke.ps1
             Invoke-ReplMethod -Method workflow.sessionlog.completeTurn ...
#>
[CmdletBinding()]
param(
    [string]$Method,
    [string]$ParamsYaml = ''
)

$ErrorActionPreference = 'Stop'

$script:ReplInvokePluginRoot = if ($env:PLUGIN_ROOT_OVERRIDE) {
    $env:PLUGIN_ROOT_OVERRIDE
} else {
    Split-Path -Parent $PSScriptRoot
}
$script:ReplInvokeCacheDir = Join-Path $script:ReplInvokePluginRoot 'cache'

function Get-ReplSessionMeta {
    $f = Join-Path $script:ReplInvokeCacheDir 'session-state.yaml'
    if (-not (Test-Path $f)) { return $null }
    $line = Select-String -Path $f -Pattern '^sessionId:' -SimpleMatch:$false |
        Select-Object -First 1
    if (-not $line) { return $null }
    $sid = ($line.Line -replace '^sessionId:\s*', '').Trim()
    if (-not $sid) { return $null }
    $prefix = ($sid -split '-', 2)[0]
    [pscustomobject]@{ SourceType = $prefix; SessionId = $sid }
}

function Invoke-ReplRaw {
    param(
        [Parameter(Mandatory)][string]$Method,
        [string]$ParamsYaml = ''
    )
    if (-not (Get-Command mcpserver-repl -ErrorAction SilentlyContinue)) {
        Write-Error 'mcpserver-repl not found on PATH'
        return @{ Success = $false; Output = '' }
    }

    $requestId = "req-$(Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ')-$((Get-Random -Maximum 0xFFFF).ToString('x4'))"
    $timeout = if ($env:REPL_TIMEOUT) { [int]$env:REPL_TIMEOUT } else { 30 }

    $envelope = "type: request`npayload:`n  requestId: $requestId`n  method: $Method"
    if ($ParamsYaml) {
        $indented = ($ParamsYaml -split "`n" | ForEach-Object { "    $_" }) -join "`n"
        $envelope += "`n  params:`n$indented"
    }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new('mcpserver-repl', '--agent-stdio')
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        # Do NOT redirect stderr: mcpserver-repl logs verbose 'info:' lines
        # to stderr, and an unread redirected stream blocks the child once
        # its pipe buffer fills (Windows ~4 KB), causing WaitForExit to hang.
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # mcpserver-repl writes UTF-8 (with BOM). Without explicit encoding,
        # PowerShell decodes as cp437 and BOM bytes (EF BB BF) become box-
        # drawing glyphs that break the '^type: error' regex anchor.
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.WriteLine($envelope)
        $proc.StandardInput.Close()

        # Drain stdout BEFORE waiting for exit. With a redirected pipe, the
        # child blocks on stdout writes once the pipe buffer (~4 KB on
        # Windows) fills, and WaitForExit then deadlocks. ReadToEndAsync
        # streams the buffer concurrently and resolves when the child closes
        # stdout (which happens at process exit).
        $readTask = $proc.StandardOutput.ReadToEndAsync()
        if (-not $readTask.Wait($timeout * 1000)) {
            $proc.Kill()
            Write-Error "mcpserver-repl timed out after ${timeout}s"
            return @{ Success = $false; Output = '' }
        }
        $output = $readTask.Result
        $proc.WaitForExit()

        # mcpserver-repl writes a UTF-8 BOM before the YAML doc and may
        # interleave logger 'info:' lines on stdout — strip BOM and ignore
        # leading log noise so the regex anchor matches the real header.
        $output = $output -replace "[\uFEFF]", ''
        $isError = $output -match '(?m)^type:\s*error\b'
        if ($proc.ExitCode -ne 0 -or $isError) {
            return @{ Success = $false; Output = $output }
        }
        return @{ Success = $true; Output = $output }
    }
    catch {
        Write-Error "mcpserver-repl invocation failed for method ${Method}: $_"
        return @{ Success = $false; Output = '' }
    }
}

function Invoke-ReplPersistTurn {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Status,
        [string]$ResponseText = '',
        [string]$ActionsYaml = ''
    )
    $meta = Get-ReplSessionMeta
    if (-not $meta) { return $false }

    $respLines = ($ResponseText -split "`n" | ForEach-Object { "      $_" }) -join "`n"
    $params = @"
sessionLog:
  sourceType: $($meta.SourceType)
  sessionId: $($meta.SessionId)
  title: $Title
  status: in_progress
  turns:
    - requestId: $RequestId
      queryTitle: $Title
      status: $Status
      response: |
$respLines
"@
    if ($ActionsYaml) {
        $actLines = ($ActionsYaml -split "`n" | ForEach-Object { "      $_" }) -join "`n"
        $params += "`n      actions:`n$actLines"
    }

    $r = Invoke-ReplRaw -Method 'client.SessionLog.SubmitAsync' -ParamsYaml $params
    return $r.Success
}

function Update-ReplTurnCacheStatus {
    param([Parameter(Mandatory)][string]$NewStatus)
    $turnFile = Join-Path $script:ReplInvokeCacheDir 'current-turn.yaml'
    if (-not (Test-Path $turnFile)) { return $false }
    $lines = Get-Content -Path $turnFile
    $updated = $lines | ForEach-Object {
        if ($_ -match '^status:') { "status: $NewStatus" } else { $_ }
    }
    Set-Content -Path $turnFile -Value $updated -NoNewline:$false
    return $true
}

function Update-ReplTurnCacheEdits {
    param([Parameter(Mandatory)][int]$Increment)
    $turnFile = Join-Path $script:ReplInvokeCacheDir 'current-turn.yaml'
    if (-not (Test-Path $turnFile)) { return $false }
    $lines = Get-Content -Path $turnFile
    $current = 0
    foreach ($l in $lines) {
        if ($l -match '^codeEdits:\s*(\d+)') {
            $current = [int]$Matches[1]
            break
        }
    }
    $new = $current + $Increment
    $updated = $lines | ForEach-Object {
        if ($_ -match '^codeEdits:') { "codeEdits: $new" } else { $_ }
    }
    Set-Content -Path $turnFile -Value $updated -NoNewline:$false
    return $true
}

function Get-ReplTurnCacheField {
    param([Parameter(Mandatory)][string]$Field)
    $turnFile = Join-Path $script:ReplInvokeCacheDir 'current-turn.yaml'
    if (-not (Test-Path $turnFile)) { return '' }
    $line = Select-String -Path $turnFile -Pattern "^${Field}:" |
        Select-Object -First 1
    if (-not $line) { return '' }
    return ($line.Line -replace "^${Field}:\s*", '').Trim()
}

function Invoke-WorkflowAppendActions {
    param([string]$ParamsYaml)
    $turnFile = Join-Path $script:ReplInvokeCacheDir 'current-turn.yaml'
    if (-not (Test-Path $turnFile)) { return $true }

    $added = 0
    if ($ParamsYaml) {
        $added = ([regex]::Matches($ParamsYaml, '(?m)^\s*filePath:\s*\S')).Count
    }
    if ($added -le 0) { return $true }

    Update-ReplTurnCacheEdits -Increment $added | Out-Null

    $reqId = Get-ReplTurnCacheField -Field 'turnRequestId'
    $title = Get-ReplTurnCacheField -Field 'queryTitle'
    Invoke-ReplPersistTurn -RequestId $reqId -Title $title `
        -Status 'in_progress' -ResponseText 'Actions appended.' `
        -ActionsYaml $ParamsYaml | Out-Null
    return $true
}

function Invoke-WorkflowCompleteTurn {
    param([string]$ParamsYaml)
    $turnFile = Join-Path $script:ReplInvokeCacheDir 'current-turn.yaml'
    if (-not (Test-Path $turnFile)) { return $true }

    $responseText = '(no response provided)'
    if ($ParamsYaml -match '(?ms)^\s*response:\s*\|\s*\r?\n(.*)$') {
        $block = $Matches[1]
        $responseText = ($block -split "`n" | ForEach-Object {
            $_ -replace '^\s{0,8}', ''
        }) -join "`n"
        $responseText = $responseText.TrimEnd()
    } elseif ($ParamsYaml -match '(?m)^\s*response:\s*(.+)$') {
        $responseText = $Matches[1].Trim()
    }

    Update-ReplTurnCacheStatus -NewStatus 'completed' | Out-Null

    $reqId = Get-ReplTurnCacheField -Field 'turnRequestId'
    $title = Get-ReplTurnCacheField -Field 'queryTitle'
    Invoke-ReplPersistTurn -RequestId $reqId -Title $title `
        -Status 'completed' -ResponseText $responseText | Out-Null
    return $true
}

function Invoke-ReplMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [string]$ParamsYaml = ''
    )

    switch -Wildcard ($Method) {
        'workflow.sessionlog.beginTurn'       { return $true }
        'workflow.sessionlog.openSession'     { return $true }
        'workflow.sessionlog.appendActions'   { return Invoke-WorkflowAppendActions -ParamsYaml $ParamsYaml }
        'workflow.sessionlog.completeTurn'    { return Invoke-WorkflowCompleteTurn -ParamsYaml $ParamsYaml }
    }

    $r = Invoke-ReplRaw -Method $Method -ParamsYaml $ParamsYaml
    if ($r.Output) { Write-Host $r.Output }
    return [bool]$r.Success
}

# Script-entry: only when invoked directly with -Method (not when dot-sourced).
if ($Method -and $MyInvocation.InvocationName -ne '.') {
    $ok = Invoke-ReplMethod -Method $Method -ParamsYaml $ParamsYaml
    if (-not $ok) { exit 1 }
    exit 0
}
