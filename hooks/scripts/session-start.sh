#!/usr/bin/env bash
# session-start.sh — SessionStart hook for the McpServer Claude Code plugin.
# Runs full_bootstrap (find marker, verify signature, health nonce check),
# opens a session log turn, and writes session state to cache/session-state.yaml.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=../../lib/resolve-cache-dir.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/resolve-cache-dir.sh"
fi
CACHE_DIR="$(resolve_cache_dir)"

_write_untrusted() {
    mkdir -p "$CACHE_DIR"
    cat > "$CACHE_DIR/session-state.yaml" << EOF
status: MCP_UNTRUSTED
reason: "$1"
timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
}

# Source shared libraries (only if functions not already defined, e.g. mocked in tests)
if ! type full_bootstrap >/dev/null 2>&1; then
    # shellcheck source=../../lib/marker-resolver.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/marker-resolver.sh"
fi

if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

if ! type cache_flush >/dev/null 2>&1; then
    # shellcheck source=../../lib/cache-manager.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/cache-manager.sh"
fi

# Ensure ensure-repl has run (install mcpserver-repl if missing)
if ! command -v mcpserver-repl >/dev/null 2>&1; then
    bash "$CLAUDE_PLUGIN_ROOT/lib/ensure-repl.sh" >&2 || true
fi

# Run bootstrap
if ! full_bootstrap 2>/dev/null; then
    _write_untrusted "Bootstrap failed"
    # Output minimal JSON so Claude Code doesn't error
    printf '{"hookSpecificOutput":{"status":"MCP_UNTRUSTED"}}\n'
    exit 0
fi

# Build session ID
SESSION_ID="ClaudeCode-$(date -u +%Y%m%dT%H%M%SZ)-plugin"

# Open session via REPL
SESSION_PARAMS="agent: ClaudeCode
sessionId: ${SESSION_ID}
title: Claude Code plugin session"

SESSION_RESPONSE=""
if SESSION_RESPONSE=$(repl_invoke "workflow.sessionlog.openSession" "$SESSION_PARAMS" 2>/dev/null); then
    STATUS="verified"
else
    STATUS="degraded"
fi

# Write session state
mkdir -p "$CACHE_DIR"
cat > "$CACHE_DIR/session-state.yaml" << EOF
status: ${STATUS}
sessionId: ${SESSION_ID}
workspacePath: "${MCPSERVER_WORKSPACE_PATH:-}"
workspace: "${MCPSERVER_WORKSPACE:-}"
baseUrl: "${MCPSERVER_BASE_URL:-}"
timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

# Output JSON hookSpecificOutput with env vars for Claude Code to consume
printf '{"hookSpecificOutput":{"status":"%s","sessionId":"%s","mcpWorkspacePath":"%s","mcpBaseUrl":"%s"}}\n' \
    "$STATUS" \
    "$SESSION_ID" \
    "${MCPSERVER_WORKSPACE_PATH:-}" \
    "${MCPSERVER_BASE_URL:-}"
