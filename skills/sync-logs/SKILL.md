---
name: sync-logs
description: Synchronize MCP Server session logs for Claude Code when asked to "sync logs", "repair MCP session logs", or "logging summary".
---

Use the local Claude Code bridge path: `lib/mcp.claude.status.ps1`, `lib/repl-invoke.ps1` or `lib/repl-invoke.ps1`, `lib/marker-resolver.*`, and `lib/final-response.ps1`. Do not use raw REST for normal MCP mutations.

Run a status check first. Ensure session/turn handling is open with `workflow.sessionlog.openSession` or `workflow.sessionlog.beginTurn`, append reasoning with `workflow.sessionlog.appendDialog`, and append durable actions with `workflow.sessionlog.appendActions`.

Discover background sessions from local cache/session state before closing. Report a compact factual summary with session ids, turn ids, actions, commits, validation, defects, and blockers.
