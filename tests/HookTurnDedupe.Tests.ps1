#Requires -Version 7.0

# triage-report-7c84e6437f7b42d0a67fbe32679a686a (defect 2): the user-prompt-submit hook can run
# twice for one prompt when both the plugin hooks.json registration and the settings.json bridge
# entries are active. The second run must reuse the already-open turn for the same prompt instead
# of opening a duplicate session-log turn.

Describe 'Open-PluginTurn duplicate-prompt dedupe' {
    BeforeEach {
        $script:SavedEnv = @{
            MCP_CACHE_DIR_OVERRIDE = $env:MCP_CACHE_DIR_OVERRIDE
            MCP_AGENT_NAME = $env:MCP_AGENT_NAME
            MCP_PLUGIN_REPL_LOG = $env:MCP_PLUGIN_REPL_LOG
            MCP_PLUGIN_REPL_RESPONSE = $env:MCP_PLUGIN_REPL_RESPONSE
        }

        $script:TestRoot = Join-Path $env:TEMP ('mcp-hook-dedupe-' + [guid]::NewGuid().ToString('N'))
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
        $openedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        [System.IO.File]::WriteAllText((Join-Path $script:TestRoot 'current-turn.yaml'), @"
turnRequestId: req-20260714T000001Z-prompt-aaaa
queryTitle: process triage reports and fix them.
queryText: process triage reports and fix them.
openedAt: $openedAt
status: in_progress
sessionId: TestAgent-20260714T000000Z-plugin-session
"@.Trim() + "`n")
    }

    AfterEach {
        foreach ($pair in $script:SavedEnv.GetEnumerator()) {
            if ($null -ne $pair.Value) {
                Set-Item -LiteralPath "Env:$($pair.Key)" -Value $pair.Value
            } else {
                Remove-Item -LiteralPath "Env:$($pair.Key)" -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reuses the open turn when the same prompt arrives again' {
        $params = @{ prompt = 'process triage reports and fix them.' } | ConvertTo-Json -Compress
        $output = & (Join-Path $PSScriptRoot '..\lib\plugin-hook.ps1') `
            -HookName 'user-prompt-submit' `
            -HostName 'claude-code' `
            -CacheMode 'flat' `
            -Params $params 2>&1 | Out-String

        $output | Should -Match 'turn-already-open'
        $output | Should -Match 'req-20260714T000001Z-prompt-aaaa'
        # The dedupe path must not open a second turn through the repl bridge.
        if (Test-Path -LiteralPath $env:MCP_PLUGIN_REPL_LOG) {
            (Get-Content -LiteralPath $env:MCP_PLUGIN_REPL_LOG -Raw) | Should -Not -Match 'beginTurn'
        }
    }

    It 'opens a new turn when the prompt differs' {
        $params = @{ prompt = 'a different prompt entirely' } | ConvertTo-Json -Compress
        $output = & (Join-Path $PSScriptRoot '..\lib\plugin-hook.ps1') `
            -HookName 'user-prompt-submit' `
            -HostName 'claude-code' `
            -CacheMode 'flat' `
            -Params $params 2>&1 | Out-String

        $output | Should -Not -Match 'turn-already-open'
        (Get-Content -LiteralPath $env:MCP_PLUGIN_REPL_LOG -Raw) | Should -Match 'beginTurn'
    }
}
