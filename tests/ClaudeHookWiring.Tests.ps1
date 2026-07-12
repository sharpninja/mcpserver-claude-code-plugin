#Requires -Version 7.0

Describe 'Claude hook validation and wiring' {
    BeforeAll {
        $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
        $script:ValidateScript = Join-Path $script:PluginRoot 'skills\claude-hook-validation\scripts\validate-claude-mcp-hooks.ps1'
        $script:InstallScript = Join-Path $script:PluginRoot 'skills\claude-hook-wiring\scripts\install-claude-mcp-hooks.ps1'
    }

    BeforeEach {
        $script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-claude-hooks-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)
        $script:SettingsPath = Join-Path $script:ScratchRoot 'settings.json'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'TEST-MCP-BUGTRIAGE-026 validate accepts enabled plugin hooks without settings hooks' {
        [System.IO.File]::WriteAllText($script:SettingsPath, (@{
            enabledPlugins = @('mcpserver')
            hooks = @{}
        } | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))

        $result = & $script:ValidateScript -SettingsPath $script:SettingsPath -PluginRoot $script:PluginRoot -CheckOnly | ConvertFrom-Json

        $result.status | Should -Be 'valid'
        @($result.missingHooks).Count | Should -Be 0
        $result.restartRequired | Should -BeFalse
        @(([System.IO.File]::ReadAllText($script:SettingsPath) | ConvertFrom-Json).hooks.PSObject.Properties).Count | Should -Be 0
    }

    It 'TEST-MCP-BUGTRIAGE-026 install removes redundant managed settings hooks when plugin hooks are enabled' {
        $settings = [ordered]@{
            enabledPlugins = @('mcpserver')
            hooks = [ordered]@{
                UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = 'pwsh -NoLogo -NoProfile -NonInteractive -File "C:\hooks\claude-mcp-hook-bridge.ps1" -ScriptName user-prompt-submit.ps1 -PluginRootHint "F:\GitHub\mcpserver-claude-code-plugin"' }) })
                Stop = @(@{ hooks = @(@{ type = 'command'; command = 'pwsh -NoLogo -NoProfile -NonInteractive -File "C:\hooks\claude-mcp-hook-bridge.ps1" -ScriptName stop-gate.ps1 -PluginRootHint "F:\GitHub\mcpserver-claude-code-plugin"' }) })
                PostToolUse = @(@{ matcher = 'Write|Edit'; hooks = @(@{ type = 'command'; command = 'pwsh -NoLogo -NoProfile -NonInteractive -File "C:\hooks\claude-mcp-hook-bridge.ps1" -ScriptName code-verify.ps1 -PluginRootHint "F:\GitHub\mcpserver-claude-code-plugin"' }) })
            }
        }
        [System.IO.File]::WriteAllText($script:SettingsPath, ($settings | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))

        $result = & $script:InstallScript -SettingsPath $script:SettingsPath -PluginRoot $script:PluginRoot -NoBackup | ConvertFrom-Json
        $updated = [System.IO.File]::ReadAllText($script:SettingsPath)

        $result.status | Should -Be 'plugin-hooks'
        $result.addedHookGroups | Should -Be 0
        $updated | Should -Not -Match 'claude-mcp-hook-bridge\.ps1'
        $updated | Should -Not -Match 'user-prompt-submit\.ps1'
        $updated | Should -Not -Match 'stop-gate\.ps1'
        $updated | Should -Not -Match 'code-verify\.ps1'
    }
}