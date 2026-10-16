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

# TR-MCP-PLUGIN-013 AC-004 (McpServer PLAN-SESSIONTRIAGEFIX-001 D5, triage-report-bd1f4386): the validator and the installer recognize the
# plugin from the enabledPlugins object Claude Code writes ("<plugin>@<marketplace>": true), with or without CLAUDE_PLUGIN_ROOT.
Describe 'Claude hook validator and installer recognize the enabled plugin' {
    BeforeAll {
        $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
        $script:ValidateScript = Join-Path $script:PluginRoot 'skills/claude-hook-validation/scripts/validate-claude-mcp-hooks.ps1'
        $script:InstallScript = Join-Path $script:PluginRoot 'skills/claude-hook-wiring/scripts/install-claude-mcp-hooks.ps1'

        # A settings shape as the scripts read it: JSON parsed with ConvertFrom-Json -AsHashtable.
        function ConvertTo-SettingsShape([object]$EnabledPlugins, [switch]$Omit) {
            $settings = [ordered]@{ hooks = [ordered]@{} }
            if (-not $Omit) { $settings.enabledPlugins = $EnabledPlugins }
            return ($settings | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 100)
        }

        # Pinned shapes; the object form is the one Claude Code writes (LAB-OMARCHY ~/.claude/settings.json on 2026-10-14 holds
        # "mcpserver@mcpserver-local": true).
        $script:EnabledPluginShapes = @(
            @{ Name = 'object form, enabled'; Settings = (ConvertTo-SettingsShape ([ordered]@{ 'mcpserver@mcpserver-local' = $true })); Expected = $true }
            @{ Name = 'object form, enabled from another marketplace'; Settings = (ConvertTo-SettingsShape ([ordered]@{ 'mcpserver@other-marketplace' = $true })); Expected = $true }
            @{ Name = 'object form, enabled beside another plugin'; Settings = (ConvertTo-SettingsShape ([ordered]@{ 'other@mcpserver-local' = $true; 'mcpserver@mcpserver-local' = $true })); Expected = $true }
            @{ Name = 'object form, disabled'; Settings = (ConvertTo-SettingsShape ([ordered]@{ 'mcpserver@mcpserver-local' = $false })); Expected = $false }
            @{ Name = 'object form, only a plugin whose name contains this name'; Settings = (ConvertTo-SettingsShape ([ordered]@{ 'mcpserver-tools@mcpserver-local' = $true })); Expected = $false }
            @{ Name = 'object form, empty'; Settings = (ConvertTo-SettingsShape ([ordered]@{})); Expected = $false }
            @{ Name = 'list form'; Settings = (ConvertTo-SettingsShape @('mcpserver')); Expected = $true }
            @{ Name = 'no enabledPlugins'; Settings = (ConvertTo-SettingsShape -Omit); Expected = $false }
        )

        # AC-004 assertion: the rule recognizes the plugin in exactly the shapes that enable it.
        function Assert-EnabledPluginRule([scriptblock]$Rule) {
            foreach ($shape in $script:EnabledPluginShapes) {
                [bool](& $Rule $shape.Settings) | Should -Be $shape.Expected -Because $shape.Name
            }
        }

        # The script's own Read-JsonObject, Get-PluginName and Test-PluginEnabled, taken from its syntax tree, as one rule over a settings shape.
        function Get-ScriptEnabledPluginRule([string]$ScriptPath) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw "parse errors in $ScriptPath" }
            $definitions = foreach ($name in 'Read-JsonObject', 'Get-PluginName', 'Test-PluginEnabled') {
                $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
                if ($null -eq $function) { throw "$name not found in $ScriptPath" }
                $function.Extent.Text
            }
            $root = $script:PluginRoot.Replace("'", "''")
            return [scriptblock]::Create("param(`$Settings)`n$($definitions -join "`n")`nTest-PluginEnabled -Settings `$Settings -PluginRoot '$root'")
        }

        function Write-SettingsFile([System.Collections.IDictionary]$Settings) {
            [System.IO.File]::WriteAllText($script:SettingsPath, ($Settings | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
        }
    }

    BeforeEach {
        $script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-claude-hooks-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)
        $script:SettingsPath = Join-Path $script:ScratchRoot 'settings.json'
        # The fallback must not stand in for the enabledPlugins reading these tests prove.
        $script:SavedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
        [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_ROOT', $null)
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_ROOT', $script:SavedPluginRoot)
        Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'EnabledPluginAssertion_AcceptsObjectFormAndRejectsCastOrBooleanBlindRules' {
        # Reference rule taken from AC-004: an object key whose plugin name is this plugin's and whose value is true, or a list entry naming it.
        $reference = {
            param($Settings)
            if (-not $Settings.Contains('enabledPlugins')) { return $false }
            $enabled = $Settings['enabledPlugins']
            if ($enabled -is [System.Collections.IDictionary]) {
                foreach ($key in $enabled.Keys) {
                    if ((([string]$key) -replace '@[^@]*$', '') -eq 'mcpserver' -and $enabled[$key] -is [bool] -and $enabled[$key]) { return $true }
                }
                return $false
            }
            return @($enabled | Where-Object { [string]$_ -eq 'mcpserver' }).Count -gt 0
        }
        Assert-EnabledPluginRule $reference

        # Negative controls: today's rule casts the whole object to one string; a rule that ignores the value; a rule that matches by substring.
        $todayCast = {
            param($Settings)
            $Settings.Contains('enabledPlugins') -and @(@($Settings['enabledPlugins']) | Where-Object { [string]$_ -eq 'mcpserver' }).Count -gt 0
        }
        $booleanBlind = {
            param($Settings)
            if (-not $Settings.Contains('enabledPlugins')) { return $false }
            $enabled = $Settings['enabledPlugins']
            if ($enabled -is [System.Collections.IDictionary]) { return @($enabled.Keys | Where-Object { (([string]$_) -replace '@[^@]*$', '') -eq 'mcpserver' }).Count -gt 0 }
            return @($enabled | Where-Object { [string]$_ -eq 'mcpserver' }).Count -gt 0
        }
        $substring = {
            param($Settings)
            if (-not $Settings.Contains('enabledPlugins')) { return $false }
            $enabled = $Settings['enabledPlugins']
            if ($enabled -is [System.Collections.IDictionary]) { return @($enabled.Keys | Where-Object { [string]$_ -like '*mcpserver*' -and $enabled[$_] }).Count -gt 0 }
            return @($enabled | Where-Object { [string]$_ -eq 'mcpserver' }).Count -gt 0
        }
        { Assert-EnabledPluginRule $todayCast } | Should -Throw
        { Assert-EnabledPluginRule $booleanBlind } | Should -Throw
        { Assert-EnabledPluginRule $substring } | Should -Throw
    }

    It 'EnabledPlugin_BothScripts_PinnedSettingsShapes' {
        foreach ($scriptPath in $script:ValidateScript, $script:InstallScript) {
            Assert-EnabledPluginRule (Get-ScriptEnabledPluginRule $scriptPath)
        }
    }

    It 'Validator_ObjectFormWithoutPluginRoot_ReportsValid' {
        Write-SettingsFile ([ordered]@{ enabledPlugins = [ordered]@{ 'mcpserver@mcpserver-local' = $true }; hooks = [ordered]@{} })
        $before = [System.IO.File]::ReadAllText($script:SettingsPath)

        $result = & $script:ValidateScript -SettingsPath $script:SettingsPath -PluginRoot $script:PluginRoot -CheckOnly | ConvertFrom-Json

        $env:CLAUDE_PLUGIN_ROOT | Should -BeNullOrEmpty
        $result.status | Should -Be 'valid'
        @($result.missingHooks).Count | Should -Be 0
        [System.IO.File]::ReadAllText($script:SettingsPath) | Should -BeExactly $before
    }

    It 'Validator_DisabledObjectForm_ReportsMissing' {
        Write-SettingsFile ([ordered]@{ enabledPlugins = [ordered]@{ 'mcpserver@mcpserver-local' = $false }; hooks = [ordered]@{} })

        $result = & $script:ValidateScript -SettingsPath $script:SettingsPath -PluginRoot $script:PluginRoot -CheckOnly | ConvertFrom-Json

        $result.status | Should -Be 'missing'
        @($result.missingHooks).Count | Should -Be 3
    }

    It 'Installer_ObjectFormWithoutPluginRoot_AddsNoBridgeHooks' {
        $bridge = 'pwsh -NoLogo -NoProfile -NonInteractive -File "/hooks/claude-mcp-hook-bridge.ps1" -ScriptName {0} -PluginRootHint "/plugin"'
        Write-SettingsFile ([ordered]@{
                enabledPlugins = [ordered]@{ 'mcpserver@mcpserver-local' = $true }
                hooks = [ordered]@{
                    UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = ($bridge -f 'user-prompt-submit.ps1') }) })
                    Stop = @(@{ hooks = @(@{ type = 'command'; command = ($bridge -f 'stop-gate.ps1') }) })
                    PostToolUse = @(@{ matcher = 'Write|Edit'; hooks = @(@{ type = 'command'; command = ($bridge -f 'code-verify.ps1') }) })
                }
            })

        $result = & $script:InstallScript -SettingsPath $script:SettingsPath -PluginRoot $script:PluginRoot -NoBackup | ConvertFrom-Json
        $updated = [System.IO.File]::ReadAllText($script:SettingsPath)

        $result.status | Should -Be 'plugin-hooks'
        $result.addedHookGroups | Should -Be 0
        $updated | Should -Not -Match 'claude-mcp-hook-bridge\.ps1'
        Test-Path -LiteralPath (Join-Path $script:ScratchRoot 'hooks/mcpserver/claude-mcp-hook-bridge.ps1') | Should -BeFalse
    }
}
