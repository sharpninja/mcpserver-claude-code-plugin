#Requires -Version 7.0

# TR-MCP-PLUGIN-012 (BUG-TRIAGE-071/075): when the session id rotates (Start-PluginSession mints a
# new sessionId) the still-present current-turn.yaml carries the old sessionId. Assert-ReplCurrentTurnFresh
# must re-bind the turn to the active session instead of hard-rejecting every subsequent completeTurn as
# stale. Marker-drift (wrong-workspace) rejection is preserved separately.

Describe 'Assert-ReplCurrentTurnFresh session rotation re-bind' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\lib\repl-invoke.ps1')
    }

    BeforeEach {
        $script:SavedEnv = @{
            MCP_CACHE_DIR_OVERRIDE = $env:MCP_CACHE_DIR_OVERRIDE
            MCP_AGENT_NAME = $env:MCP_AGENT_NAME
        }
        $script:TestRoot = Join-Path $env:TEMP ('mcp-turn-rebind-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:TestRoot)
        $env:MCP_CACHE_DIR_OVERRIDE = $script:TestRoot
        $env:MCP_AGENT_NAME = 'ClaudeCode'

        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'session-state.yaml'), @"
status: verified
sessionId: ClaudeCode-20260716T020000Z-plugin-session
agent: ClaudeCode
"@.Trim() + "`n")
        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'current-turn.yaml'), @"
turnRequestId: req-20260716T010000Z-prompt-old
queryTitle: real user work
status: in_progress
sessionId: ClaudeCode-20260716T010000Z-plugin-session
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

    It 'returns fresh and re-binds the turn to the active session id after rotation' {
        $fresh = Assert-ReplCurrentTurnFresh -Method 'workflow.sessionlog.completeTurn'

        $fresh | Should -BeTrue
        $turn = Read-McpYamlObject -Path (Join-Path $script:TestRoot 'current-turn.yaml')
        [string]$turn['sessionId'] | Should -Be 'ClaudeCode-20260716T020000Z-plugin-session'
    }
}
