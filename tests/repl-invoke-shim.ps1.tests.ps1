# Pester regression suite for the workflow.sessionlog.* shim added to
# lib/repl-invoke.ps1. Mirrors the bash suite at tests/lib/repl-invoke.test.sh.
#
# Original bug: every workflow.sessionlog.* call returned method_not_found
# from mcpserver-repl. mcpserver-repl exits 0 even on type:error, so callers
# saw "success" — but cache/current-turn.yaml never flipped to completed and
# the Stop hook blocked every turn.
#
# Run: pwsh -NoProfile -Command "Invoke-Pester plugins/mcpserver/tests/lib/repl-invoke.ps1.tests.ps1"
# Pester v3.4 syntax (Should Be, no Should -Be).

$script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:LibPath    = Join-Path $script:PluginRoot 'lib\repl-invoke.ps1'

Describe 'repl-invoke.ps1 workflow.sessionlog.* shim' {

    BeforeEach {
        $script:Sandbox = Join-Path $env:TEMP ("repl-invoke-pester-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -Path $script:Sandbox -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:Sandbox 'cache') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:Sandbox 'bin')   -ItemType Directory -Force | Out-Null

        # Stub mcpserver-repl as a .cmd shim that runs a pwsh stub script.
        # On Windows, .cmd extensions are auto-discoverable on PATH.
        $stubPs1 = Join-Path $script:Sandbox 'bin\mcpserver-repl-stub.ps1'
        @'
$input | Out-String | Set-Variable raw
$method = ''
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^\s*method:\s*(.+)$') { $method = $Matches[1].Trim(); break }
}
switch -Wildcard ($method) {
    'client.SessionLog.SubmitAsync' { "type: response`npayload:`n  ok: true" }
    'client.SessionLog.QueryAsync'  { "type: response`npayload: { items: [] }" }
    'client.Health.PingAsync'       { "type: response`npayload: { ok: true }" }
    'workflow.sessionlog.*' {
        "type: error`npayload:`n  code: method_not_found`n  message: not routed"
    }
    default {
        "type: error`npayload:`n  code: method_invocation_error`n  message: unknown"
    }
}
exit 0
'@ | Set-Content -Path $stubPs1 -Encoding ASCII

        $stubCmd = Join-Path $script:Sandbox 'bin\mcpserver-repl.cmd'
        @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "$stubPs1"
"@ | Set-Content -Path $stubCmd -Encoding ASCII

        # Seed cache/session-state.yaml so persistence shim has sourceType+sessionId.
        @'
status: verified
sessionId: ClaudeCode-20260419T000000Z-test
workspacePath: "/tmp/ws"
workspace: "test"
baseUrl: "http://localhost:1"
timestamp: "2026-04-19T00:00:00Z"
'@ | Set-Content -Path (Join-Path $script:Sandbox 'cache\session-state.yaml') -Encoding ASCII

        $script:OriginalPath = $env:PATH
        $env:PATH = (Join-Path $script:Sandbox 'bin') + [System.IO.Path]::PathSeparator + $env:PATH
        $env:PLUGIN_ROOT_OVERRIDE = $script:Sandbox

        # Dot-source lib so Invoke-ReplMethod is in scope.
        . $script:LibPath
    }

    AfterEach {
        $env:PATH = $script:OriginalPath
        Remove-Item Env:\PLUGIN_ROOT_OVERRIDE -ErrorAction SilentlyContinue
        if (Test-Path $script:Sandbox) {
            Remove-Item -Recurse -Force $script:Sandbox -ErrorAction SilentlyContinue
        }
    }

    function Write-TurnCache {
        param(
            [string]$Status = 'in_progress',
            [int]$Edits     = 0,
            [string]$Build  = 'unknown'
        )
        @"
turnRequestId: req-test-pester-001
queryTitle: Pester shim test
openedAt: 2026-04-19T00:00:00Z
status: $Status
codeEdits: $Edits
lastBuildStatus: $Build
"@ | Set-Content -Path (Join-Path $script:Sandbox 'cache\current-turn.yaml') -Encoding ASCII
    }

    function Read-TurnField {
        param([string]$Field)
        $f = Join-Path $script:Sandbox 'cache\current-turn.yaml'
        $line = (Get-Content $f) | Where-Object { $_ -match "^${Field}:" } | Select-Object -First 1
        if (-not $line) { return '' }
        return ($line -replace "^${Field}:\s*", '').Trim()
    }

    Context 'completeTurn' {
        It 'flips current-turn.yaml status from in_progress to completed' {
            Write-TurnCache -Status 'in_progress'
            $params = "requestId: req-test-pester-001`nresponse: |`n  Done."
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.completeTurn' -ParamsYaml $params
            $r | Should Be $true
            (Read-TurnField -Field 'status') | Should Be 'completed'
        }

        It 'is idempotent on already-completed turns' {
            Write-TurnCache -Status 'completed'
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.completeTurn' -ParamsYaml 'response: again'
            $r | Should Be $true
            (Read-TurnField -Field 'status') | Should Be 'completed'
        }

        It 'no-ops gracefully when current-turn.yaml is missing' {
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.completeTurn' -ParamsYaml 'response: x'
            $r | Should Be $true
        }
    }

    Context 'appendActions' {
        It 'bumps codeEdits once per filePath: in params' {
            Write-TurnCache -Status 'in_progress' -Edits 0
            $params = @"
actions:
  - description: a
    type: edit
    filePath: src/a.cs
  - description: b
    type: edit
    filePath: src/b.cs
"@
            Invoke-ReplMethod -Method 'workflow.sessionlog.appendActions' -ParamsYaml $params | Out-Null
            (Read-TurnField -Field 'codeEdits') | Should Be '2'
        }

        It 'leaves codeEdits unchanged when no filePath: present' {
            Write-TurnCache -Status 'in_progress' -Edits 0
            $params = @"
actions:
  - description: design only
    type: design_decision
"@
            Invoke-ReplMethod -Method 'workflow.sessionlog.appendActions' -ParamsYaml $params | Out-Null
            (Read-TurnField -Field 'codeEdits') | Should Be '0'
        }

        It 'accumulates across multiple invocations' {
            Write-TurnCache -Status 'in_progress' -Edits 1
            $params = @"
actions:
  - description: c
    type: edit
    filePath: src/c.cs
"@
            Invoke-ReplMethod -Method 'workflow.sessionlog.appendActions' -ParamsYaml $params | Out-Null
            (Read-TurnField -Field 'codeEdits') | Should Be '2'
        }
    }

    Context 'no-op shims' {
        It 'beginTurn returns success without server call' {
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.beginTurn' -ParamsYaml 'requestId: x'
            $r | Should Be $true
        }

        It 'openSession returns success without server call' {
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.openSession' -ParamsYaml 'agent: ClaudeCode'
            $r | Should Be $true
        }
    }

    Context 'raw dispatcher passthrough' {
        It 'dispatches non-workflow.* methods to mcpserver-repl' {
            # Asserts the call reaches mcpserver-repl (response shape comes
            # back), not that auth succeeds. The sandbox doesn't carry a
            # real AGENTS-README-FIRST marker, so the binary may reject
            # with type: error 'Authentication required' — that still
            # proves dispatch happened, which is what this test guards.
            $raw = Invoke-ReplRaw -Method 'client.Health.GetAsync' -ParamsYaml ''
            $raw.Output | Should Match '(?m)^type:\s*(result|response|error)\b'
        }

        It 'returns false when mcpserver-repl emits type: error' {
            $r = Invoke-ReplMethod -Method 'client.SessionLog.NopeAsync' -ParamsYaml ''
            $r | Should Be $false
        }
    }

    Context 'regression guards' {
        It 'workflow verbs never fall through to raw error path' {
            Write-TurnCache -Status 'in_progress'
            # Stub returns type:error for workflow.* methods. If shim were
            # removed, this test would catch the regression.
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.completeTurn' -ParamsYaml 'response: regression guard'
            $r | Should Be $true
            (Read-TurnField -Field 'status') | Should Be 'completed'
        }

        It 'completeTurn still flips cache when mcpserver-repl is unavailable' {
            Write-TurnCache -Status 'in_progress'
            # Strip stub bin from PATH so mcpserver-repl is unfindable.
            $sep = [System.IO.Path]::PathSeparator
            $stubBin = Join-Path $script:Sandbox 'bin'
            $env:PATH = (($env:PATH -split $sep) | Where-Object { $_ -ne $stubBin }) -join $sep
            $r = Invoke-ReplMethod -Method 'workflow.sessionlog.completeTurn' -ParamsYaml 'response: offline'
            $r | Should Be $true
            (Read-TurnField -Field 'status') | Should Be 'completed'
        }
    }
}
