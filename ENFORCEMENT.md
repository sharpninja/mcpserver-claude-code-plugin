# McpServer Claude Code Plugin - Enforcement Protocol (v4)

This plugin implements the McpServer **v4 Shared Enforcement Protocol** for Claude Code agent sessions.

## Shared Core Reference

All enforcement behaviors align with the canonical v4 shared core defined in:
- `packages/mcpserver-agent-core` (`@sharpninja/mcpserver-agent-core`)
- `docs/plans/plan-agent-plugin-operational-parity-v1.0.md` in the McpServer repository
- TR-MCP-AGENT-PARITY-010 through -013 (technical requirements for shared enforcement)

## Three-Phase Protocol

Every user message triggers the v4 three-phase enforcement protocol:

## Tool Name Surfaces

The enforcement scripts call `workflow.sessionlog.*`, `workflow.todo.*`, and
`workflow.requirements.*` through `lib/repl-invoke.sh`. Those are plugin
workflow/REPL method names, not literal native MCP tool names. Native McpServer
MCP discovery uses names such as `sessionlog_*`, `todo_*`, and
`requirements_*`; hosted-agent adapters may expose aliases such as
`mcp_session_*`.

Use plugin status, marker trust, hooks, and skill loading to validate this
plugin. Do not search generic MCP discovery for literal `workflow.*` names and
call the plugin unavailable solely because those names are absent.

### Phase 1 - Begin Turn (`UserPromptSubmit` hook)
- `hooks/scripts/user-prompt-submit.sh` calls `workflow.sessionlog.beginTurn` via REPL
- A `current-turn.yaml` file is written to the workspace cache so the Stop hook can verify completion
- If the server is unavailable, the turn is buffered to the v4 failsafe cache

### Phase 2 - Edit + Verify (`PostToolUse` hook on Write/Edit)
- `hooks/scripts/code-verify.sh` runs the project build after every file edit
- Build failure transitions the enforcement state to `BlockedOnBuild`
- Build success is recorded in the session log action list (`appendActions`)
- `hooks/scripts/plan-modified.sh` syncs plan file changes to MCP TODOs

### Phase 3 - Complete Turn (`Stop` hook)
- `hooks/scripts/stop-gate.sh` verifies the turn was begun and not left open
- If a prior build failed, the stop gate blocks the response (no escape hatch)
- Successful completion calls `workflow.sessionlog.completeTurn`
- If server is unavailable, the completion is buffered to failsafe cache

## State Machine

The enforcement states (per v4 shared core, TR-MCP-AGENT-PARITY-011):

```
NoTurn
  |-- UserPromptSubmit --> TurnOpen
       |-- Write/Edit (success) --> EditsInProgress
       |-- Write/Edit (failure) --> BlockedOnBuild (no escape, stop gate blocked)
       |-- Stop (all builds green) --> TurnComplete
       |-- Stop (pending edits, no complete) --> BlockedOnMissingComplete
```

## Failsafe Cache (v4 format, TR-MCP-AGENT-PARITY-013)

When the MCP server is unavailable, pending REPL calls are buffered to the workspace failsafe cache:

**v4 layout:** `<workspace_root>/.mcpServer/failsafe/ClaudeCode/workspaces/<base64url(workspacePath)>/`
- `pending/` - queued entries, max 3 retries
- `failed/` - entries exceeding retry limit

The workspace key is the Base64URL encoding of the absolute workspace path, matching
`V4CacheManager.GetScopedCachePath` in `@sharpninja/mcpserver-agent-core`.

**Legacy layout** (pre-v4): `cache/workspaces/<slug-sha1>/sessions/<session-key>/` remains
supported for read-back during migration. New writes use the v4 layout.

## Marker Bootstrap (TR-MCP-AGENT-PARITY-012)

`lib/marker-resolver.sh` implements upward directory search for `AGENTS-README-FIRST.yaml`,
HMAC-SHA256 signature verification with the workspace API key, and nonce health challenge
against `/health?nonce=`. Behavior is identical to `V4MarkerTrustService` in the shared core.

## Plugin Version

This plugin is on the v1.x operational parity release line. All eight official `mcpserver-*-plugin`
repositories share this enforcement protocol version.

## References

- `hooks/hooks.json` - hook lifecycle wiring (SessionStart, UserPromptSubmit, Stop, PostToolUse, SessionEnd, PreCompact, PostCompact)
- `lib/cache-scope.sh` - workspace key derivation (v4: `cache_scope_workspace_key_v4`, `cache_scope_v4_failsafe_root`)
- `lib/cache-manager.sh` - pending write/flush/recovery (MAX_RETRIES=3)
- `lib/marker-resolver.sh` - HMAC-SHA256 marker trust
- `lib/repl-invoke.sh` - REPL client with retry and timeout
- `Plugin-Validation-Testing-Plan.md` - parity v1 validation checklist
