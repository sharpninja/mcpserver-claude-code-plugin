---
name: sync-logs
description: Synchronize MCP Server session logs for Claude Code when asked to "sync logs", "repair MCP session logs", or "logging summary".
---

Use the local Claude Code bridge path: `lib/mcp.claude.status.ps1`, `lib/repl-invoke.ps1` or `lib/repl-invoke.ps1`, `lib/marker-resolver.*`, and `lib/final-response.ps1`. Do not use raw REST for normal MCP mutations.

Run a status check first. Ensure session/turn handling is open with `workflow.sessionlog.openSession` or `workflow.sessionlog.beginTurn`, append reasoning with `workflow.sessionlog.appendDialog`, and append durable actions with `workflow.sessionlog.appendActions`.

Discover background sessions from local cache/session state before closing. Report a compact factual summary with session ids, turn ids, actions, commits, validation, defects, and blockers.

## Wrapper Result Semantics

- Treat `deprecated: true` on a successful `workflow.sessionlog.*` result as migration metadata only. It means the workflow namespace is legacy-compatible and should migrate toward `client.*` where practical; it does not mean the wrapper is broken.
- Treat only `type: error`, a nonzero wrapper exit code, `MCP_UNTRUSTED`, or `MCP_PLUGIN_UNAVAILABLE:<Agent>` as MCP/plugin failure states.
- An empty `workflow.sessionlog.queryHistory` result is a valid result. It means no sessions matched the supplied query, agent filter, workspace, or offset. Re-run the wrapper with the correct workspace current directory, explicit `agent` or `sourceType`, and plugin cache/session state before concluding history is absent.
- Do not fall back to raw REST because `queryHistory` returned no rows or because the result included `deprecated: true`. If wrapper recovery cannot find the active turn, report that sync-logs could not locate history through the plugin and continue with non-MCP work.
- Raw REST is allowed only when the user's active request is REST/API diagnostics and the plugin path has already failed closed.
