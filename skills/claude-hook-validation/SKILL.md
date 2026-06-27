---
name: Claude MCP Hook Validation
description: Use when an MCP workspace marker tells Claude Code to validate active MCP hook enforcement. Verifies active Claude settings and installs missing MCP hooks through the claude-hook-wiring skill.
---

## Purpose

This skill is triggered by the workspace marker file during Claude Code plugin bootstrap. It verifies that the active Claude settings include the MCP hook chain required for per-request enforcement.

Use this skill when:

- `AGENTS-README-FIRST.yaml` or another marker file says to validate Claude hook wiring.
- Claude Code has the McpServer plugin installed but does not reliably open MCP turns or run stop gates.
- Active Claude settings may not include MCP `UserPromptSubmit`, `Stop`, or `PostToolUse` hooks.

## Action

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File "$env:CLAUDE_PLUGIN_ROOT/skills/claude-hook-validation/scripts/validate-claude-mcp-hooks.ps1"
```

If `CLAUDE_PLUGIN_ROOT` is unavailable, pass the plugin root explicitly:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File "F:/GitHub/mcpserver-claude-code-plugin/skills/claude-hook-validation/scripts/validate-claude-mcp-hooks.ps1" -PluginRoot "F:/GitHub/mcpserver-claude-code-plugin"
```

The validation script checks active Claude `settings.json` for:

- `UserPromptSubmit` with `user-prompt-submit.ps1`
- `Stop` with `stop-gate.ps1`
- `PostToolUse` with `code-verify.ps1`

When any required hook is missing, the script invokes the `claude-hook-wiring` skill installer script, `install-claude-mcp-hooks.ps1`, to merge MCP hooks from `hooks/hooks.json` into active Claude settings. Existing hooks must remain intact.

## Result Handling

- `status: valid`: hooks are already active; continue normal MCP work.
- `status: installed`: hooks were merged into active Claude settings; restart Claude Code before relying on automatic hook enforcement.
- `status: missing`: hooks are absent and installation was disabled; report the missing hooks and do not claim enforcement is active.

After `status: installed`, restart Claude Code. If the current task must continue before restart, manually follow the MCP session-log workflow for the current request and treat automatic enforcement as pending until the restart.
