#Requires -Version 7.0

Describe 'Claude plugin skill guidance' {
    BeforeAll {
        $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
        $script:SkillsRoot = Join-Path $script:PluginRoot 'skills'
    }

    It 'TEST-MCP-PLUGIN-PSONLY-001 sync-logs treats deprecated workflow metadata as success and blocks REST fallback' {
        $content = [System.IO.File]::ReadAllText((Join-Path $script:SkillsRoot 'sync-logs\SKILL.md'))

        $content | Should -Match ([regex]::Escape('deprecated: true'))
        $content | Should -Match 'migration metadata only'
        $content | Should -Match 'does not mean the wrapper is broken'
        $content | Should -Match 'empty `workflow\.sessionlog\.queryHistory` result is a valid result'
        $content | Should -Match 'Do not fall back to raw REST'
    }

    It 'TEST-MCP-PLUGIN-PSONLY-001 session skill treats deprecated workflow metadata and empty history as valid wrapper outcomes' {
        $content = [System.IO.File]::ReadAllText((Join-Path $script:SkillsRoot 'session\SKILL.md'))

        $content | Should -Match ([regex]::Escape('deprecated: true'))
        $content | Should -Match 'success metadata'
        $content | Should -Match 'not a failure signal'
        $content | Should -Match 'valid no-match result'
        $content | Should -Match 'Re-check the workspace current directory'
    }
}
