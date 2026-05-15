#!/usr/bin/env bash
# session-start.sh — SessionStart hook for the McpServer Claude Code plugin.
# Runs full_bootstrap (find marker, verify signature, health nonce check),
# opens a session log turn, and writes session state to cache/session-state.yaml.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_PLUGIN_ROOT}"
if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=../../lib/resolve-cache-dir.sh
    source "$SCRIPT_PLUGIN_ROOT/lib/resolve-cache-dir.sh"
fi
CACHE_DIR="$(resolve_cache_dir)"

_hook_run_with_timeout() {
    local timeout_seconds="${1:-8}"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=2s "$timeout_seconds" "$@"
        return $?
    fi

    "$@"
}

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
    source "$SCRIPT_PLUGIN_ROOT/lib/marker-resolver.sh"
fi

if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$SCRIPT_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

if ! type cache_flush >/dev/null 2>&1; then
    # shellcheck source=../../lib/cache-manager.sh
    source "$SCRIPT_PLUGIN_ROOT/lib/cache-manager.sh"
fi

mkdir -p "$CACHE_DIR"
LOCK_DIR="$CACHE_DIR/session-start.lock"
if [ -d "$LOCK_DIR" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt "${MCP_PLUGIN_STALE_LOCK_SECONDS:-120}" ]; then
        rm -rf "$LOCK_DIR"
    fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '{"hookSpecificOutput":{"status":"degraded","reason":"session-start already running"}}\n'
    exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

# Ensure ensure-repl has run (install mcpserver-repl if missing)
if ! command -v mcpserver-repl >/dev/null 2>&1; then
    bash "$SCRIPT_PLUGIN_ROOT/lib/ensure-repl.sh" >&2 || true
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
PREVIOUS_REPL_TIMEOUT="${REPL_TIMEOUT:-}"
export REPL_TIMEOUT="${REPL_SESSIONLOG_REPL_TIMEOUT:-8}"
if SESSION_RESPONSE=$(repl_invoke "workflow.sessionlog.openSession" "$SESSION_PARAMS" 2>/dev/null); then
    STATUS="verified"
else
    STATUS="degraded"
fi
if [ -n "$PREVIOUS_REPL_TIMEOUT" ]; then
    export REPL_TIMEOUT="$PREVIOUS_REPL_TIMEOUT"
else
    unset REPL_TIMEOUT
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
