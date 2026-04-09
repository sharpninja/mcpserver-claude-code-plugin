# McpServer Claude Code Plugin

Connect [Claude Code](https://claude.com/claude-code) to [McpServer](https://github.com/sharpninja/McpServer) for workspace-scoped TODO management, session logging, requirements tracking, and GraphRAG knowledge graph operations.

## Features

- **Auto-connect** via `AGENTS-README-FIRST.yaml` marker file discovery with HMAC-SHA256 signature verification
- **Session hooks** — automatic session creation, turn tracking, context reload after compaction
- **Plan tracking** — auto-creates MCP TODO when a plan is approved, syncs updates on plan edits
- **Offline resilience** — local YAML cache for writes when MCP server is unavailable, automatic flush on reconnect
- **Four skills**: TODO, Session Log, Requirements, GraphRAG — all using `mcpserver-repl` YAML-over-STDIO protocol

## Prerequisites

- [.NET 9.0 SDK](https://dotnet.microsoft.com/download)
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- [McpServer](https://github.com/sharpninja/McpServer) running with a workspace configured

The plugin auto-installs `mcpserver-repl` (dotnet global tool) from GitHub releases on first use.

## Installation

```bash
# Via Claude Code plugin system
claude plugin install sharpninja/mcpserver-claude-code-plugin
```

## How It Works

1. **SessionStart hook** discovers the nearest `AGENTS-README-FIRST.yaml` marker file
2. Verifies the marker's HMAC-SHA256 signature using the workspace API key
3. Confirms server health with a nonce challenge
4. Opens an MCP session log and sets `MCP_WORKSPACE_PATH` for the REPL transport
5. All subsequent operations go through `mcpserver-repl --agent-stdio`

## Skills

| Skill | Triggers | REPL Namespace |
|-------|----------|----------------|
| **TODO** | "create a todo", "list todos", "mark done" | `workflow.todo.*` |
| **Session** | "start session", "begin turn", "query history" | `workflow.sessionlog.*` |
| **Requirements** | "create FR", "list requirements", "generate docs" | `workflow.requirements.*` |
| **GraphRAG** | "ingest text", "create entity", "query knowledge graph" | `workflow.graphrag.*` |

## Offline Cache

When MCP server is unavailable, writes are cached as YAML files in `cache/pending/`. The cache flushes automatically on:
- Next skill invocation (opportunistic)
- Session end hook
- Manual: `hooks/scripts/cache-flush.sh`

Items retry up to 3 times before being marked as failed.

## Development

```bash
# Run tests
bats tests/

# Test a specific phase
bats tests/hooks.bats
bats tests/skills.bats
```

## License

MIT
