#Requires -Version 7.0

# TEST-MCP-PLUGIN-SESSIONLOG-EXIT: the local session-log verbs (appendActions,
# appendDialog, completeTurn, beginTurn, openSession) must record their outcome on
# $script:LastInvokeReplMethodSuccess (so the script-entry exit code is truthful)
# and must NOT emit their boolean result to stdout (which leaked as "True" lines).
Describe 'repl-invoke local session-log verbs' {
    BeforeAll {
        $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
        . (Join-Path $script:PluginRoot 'lib\repl-invoke.ps1')
    }

    It 'TEST-MCP-PLUGIN-SESSIONLOG-101 records success and emits no boolean stdout for a successful local verb' {
        Mock -CommandName Invoke-WorkflowAppendActions -MockWith { $true }
        $script:LastInvokeReplMethodSuccess = $false
        $out = Invoke-ReplMethod -Method 'workflow.sessionlog.appendActions' -ParamsYaml '{}'
        $script:LastInvokeReplMethodSuccess | Should -BeTrue
        $out | Should -BeNullOrEmpty
    }

    It 'TEST-MCP-PLUGIN-SESSIONLOG-102 records failure when a local verb returns false' {
        Mock -CommandName Invoke-WorkflowAppendActions -MockWith { $false }
        $script:LastInvokeReplMethodSuccess = $true
        $out = Invoke-ReplMethod -Method 'workflow.sessionlog.appendActions' -ParamsYaml '{}'
        $script:LastInvokeReplMethodSuccess | Should -BeFalse
        $out | Should -BeNullOrEmpty
    }

    It 'TEST-MCP-PLUGIN-SESSIONLOG-103 records success for a no-op verb (beginTurn) without stdout' {
        $script:LastInvokeReplMethodSuccess = $false
        $out = Invoke-ReplMethod -Method 'workflow.sessionlog.beginTurn'
        $script:LastInvokeReplMethodSuccess | Should -BeTrue
        $out | Should -BeNullOrEmpty
    }

    It 'TEST-MCP-PLUGIN-SESSIONLOG-104 records success and emits no boolean stdout for completeTurn' {
        Mock -CommandName Invoke-WorkflowCompleteTurn -MockWith { $true }
        $script:LastInvokeReplMethodSuccess = $false
        $out = Invoke-ReplMethod -Method 'workflow.sessionlog.completeTurn' -ParamsYaml '{}'
        $script:LastInvokeReplMethodSuccess | Should -BeTrue
        $out | Should -BeNullOrEmpty
    }
}
