<#
.SYNOPSIS
    Sends a YAML request envelope to mcpserver-repl --agent-stdio.
.DESCRIPTION
    PowerShell fallback for repl-invoke.sh. Constructs a YAML envelope
    and pipes it to the mcpserver-repl dotnet tool.
#>
param(
    [Parameter(Mandatory)][string]$Method,
    [string]$ParamsYaml = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command mcpserver-repl -ErrorAction SilentlyContinue)) {
    Write-Error "mcpserver-repl not found on PATH"
    exit 1
}

$requestId = "req-$(Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ')-$((Get-Random -Maximum 0xFFFF).ToString('x4'))"
$timeout = if ($env:REPL_TIMEOUT) { [int]$env:REPL_TIMEOUT } else { 30 }

$envelope = @"
type: request
payload:
  requestId: $requestId
  method: $Method
"@

if ($ParamsYaml) {
    $indented = ($ParamsYaml -split "`n" | ForEach-Object { "    $_" }) -join "`n"
    $envelope += "`n  params:`n$indented"
}

try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('mcpserver-repl', '--agent-stdio')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine($envelope)
    $proc.StandardInput.Close()

    if (-not $proc.WaitForExit($timeout * 1000)) {
        $proc.Kill()
        Write-Error "mcpserver-repl timed out after ${timeout}s"
        exit 1
    }

    $output = $proc.StandardOutput.ReadToEnd()
    if ($proc.ExitCode -ne 0) {
        $stderr = $proc.StandardError.ReadToEnd()
        Write-Error "mcpserver-repl failed: $stderr"
        exit 1
    }

    Write-Output $output
}
catch {
    Write-Error "mcpserver-repl invocation failed for method ${Method}: $_"
    exit 1
}
