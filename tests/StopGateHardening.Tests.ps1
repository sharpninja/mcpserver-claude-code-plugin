#Requires -Version 7.0

# TR-MCP-PLUGIN-011 (BUG-TRIAGE-071/082/083): the Stop gate must (a) count auditCommits in the
# audit-completeness sum and (b) no-op instead of block for empty/system-event (phantom) turns such
# as <task-notification> prompts, which by construction have no agent work under them.

Describe 'Close-PluginTurnIfNeeded hardening' {
    BeforeEach {
        $script:SavedEnv = @{
            MCP_CACHE_DIR_OVERRIDE = $env:MCP_CACHE_DIR_OVERRIDE
            MCP_AGENT_NAME = $env:MCP_AGENT_NAME
            MCP_PLUGIN_REPL_LOG = $env:MCP_PLUGIN_REPL_LOG
            MCP_PLUGIN_REPL_RESPONSE = $env:MCP_PLUGIN_REPL_RESPONSE
            CLAUDE_STOP_HOOK_ACTIVE = $env:CLAUDE_STOP_HOOK_ACTIVE
        }
        $env:CLAUDE_STOP_HOOK_ACTIVE = $null

        $script:TestRoot = Join-Path $env:TEMP ('mcp-stopgate-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:TestRoot)
        $env:MCP_CACHE_DIR_OVERRIDE = $script:TestRoot
        $env:MCP_AGENT_NAME = 'TestAgent'
        $env:MCP_PLUGIN_REPL_LOG = Join-Path $script:TestRoot 'repl-log.txt'
        $env:MCP_PLUGIN_REPL_RESPONSE = "type: result`npayload:`n  result:`n    ok: true`n"

        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'session-state.yaml'), @"
sessionId: TestAgent-20260714T000000Z-plugin-session
agent: TestAgent
status: verified
"@.Trim() + "`n")
    }

    AfterEach {
        foreach ($pair in $script:SavedEnv.GetEnumerator()) {
            if ($null -ne $pair.Value) { Set-Item -LiteralPath "Env:$($pair.Key)" -Value $pair.Value }
            else { Remove-Item -LiteralPath "Env:$($pair.Key)" -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not block a completed code-edit turn whose only audit signal is commits' {
        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'current-turn.yaml'), @"
turnRequestId: req-20260714T000001Z-prompt-commit
queryTitle: real user work
queryText: real user work
status: completed
sessionId: TestAgent-20260714T000000Z-plugin-session
codeEdits: 1
lastBuildStatus: succeeded
auditActions: 0
auditFiles: 0
auditDialog: 0
auditDecisions: 0
auditCommits: 2
"@.Trim() + "`n")

        $output = & (Join-Path $PSScriptRoot '..\lib\plugin-hook.ps1') `
            -HookName 'stop-gate' -HostName 'claude-code' -CacheMode 'flat' 2>&1 | Out-String

        $output | Should -Not -Match 'decision.{0,4}block'
        $output | Should -Not -Match 'audit is incomplete'
    }

    It 'no-ops instead of blocking for a task-notification phantom turn' {
        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'current-turn.yaml'), @"
turnRequestId: req-20260714T000002Z-prompt-phantom
queryTitle: <task-notification>
queryText: <task-notification>
status: in_progress
sessionId: TestAgent-20260714T000000Z-plugin-session
codeEdits: 0
auditActions: 0
auditFiles: 0
auditDialog: 0
auditDecisions: 0
auditCommits: 0
"@.Trim() + "`n")

        $output = & (Join-Path $PSScriptRoot '..\lib\plugin-hook.ps1') `
            -HookName 'stop-gate' -HostName 'claude-code' -CacheMode 'flat' 2>&1 | Out-String

        $output | Should -Not -Match 'decision.{0,4}block'
        if (Test-Path -LiteralPath $env:MCP_PLUGIN_REPL_LOG) {
            (Get-Content -LiteralPath $env:MCP_PLUGIN_REPL_LOG -Raw) | Should -Not -Match 'completeTurn'
        }
    }
}
