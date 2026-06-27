---
name: Claude MCP Hook Wiring
description: Use when Claude Code is not reliably opening MCP session turns, running MCP stop gates, or running MCP post-tool verification on every request. Installs the MCP plugin hook chain into the active Claude settings file.
---

## Purpose

Claude Code can have the McpServer plugin installed while the active Claude settings file still does not invoke the plugin hooks. This skill wires the MCP hooks directly into the active Claude settings so enforcement is driven by Claude's hook runtime, not by model memory or prompt compliance.

Use this skill when:

- Claude skips MCP session logging, TODO, requirements, triage, or build-verification rules.
- `hooks/hooks.json` exists in the plugin package but the active Claude settings do not run `UserPromptSubmit`, `Stop`, or `PostToolUse` MCP hooks.
- The user asks to make Claude follow MCP rules on every request.

Do not replace existing user hooks. Merge MCP hook entries into `settings.json` and preserve existing hook groups such as timestamp hooks, shell blockers, or unrelated workflow hooks.

## Install

Run the installer from the Claude plugin root:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File "$env:CLAUDE_PLUGIN_ROOT/skills/claude-hook-wiring/scripts/install-claude-mcp-hooks.ps1"
```

If `CLAUDE_PLUGIN_ROOT` is not set, pass the plugin root explicitly:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File "F:/GitHub/mcpserver-claude-code-plugin/skills/claude-hook-wiring/scripts/install-claude-mcp-hooks.ps1" -PluginRoot "F:/GitHub/mcpserver-claude-code-plugin"
```

The installer reads the plugin's `hooks/hooks.json`, merges it into the active Claude settings file, and writes a timestamped backup unless `-NoBackup` is supplied.

## Required Active Hooks

After wiring, the active Claude settings must contain MCP entries for:

- `UserPromptSubmit`: opens an MCP session-log turn before Claude starts work.
- `Stop`: blocks or auto-closes incomplete turns before Claude emits a final response.
- `PostToolUse`: runs plan synchronization and code verification after relevant tool calls.
- `SessionStart`, `SessionEnd`, `PreCompact`, and `PostCompact`: maintain session continuity around lifecycle events.

## Verification

After installation:

1. Restart Claude Code so the updated active Claude settings are reloaded.
2. Inspect the active `settings.json` and confirm existing hooks are still present.
3. Confirm MCP hook commands reference `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/user-prompt-submit.ps1`, `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/stop-gate.ps1`, and `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/code-verify.ps1`.
4. Start a fresh Claude request in an MCP workspace and confirm the first turn opens before tool use.
5. Make a small edit in a disposable test branch or fixture and confirm `PostToolUse` runs code verification.
6. Confirm a final response is blocked or auto-closed if the session turn is incomplete.

If the merge fails, do not claim Claude is enforced. Report the failure and leave the existing settings unchanged by restoring the backup.
