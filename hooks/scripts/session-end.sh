#!/usr/bin/env bash
# session-end.sh — SessionEnd hook for the McpServer Claude Code plugin.
# Flushes the write cache, completes the current session log turn, and
# removes the session state file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=../../lib/resolve-cache-dir.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/resolve-cache-dir.sh"
fi
CACHE_DIR="$(resolve_cache_dir)"
SESSION_STATE="$CACHE_DIR/session-state.yaml"

# Source libraries if not already loaded (mocked in tests)
if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

if ! type cache_flush >/dev/null 2>&1; then
    # shellcheck source=../../lib/cache-manager.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/cache-manager.sh"
fi

# Flush any pending cache entries
FLUSH_RESULT=$(cache_flush 2>/dev/null || echo "flushed=0 failed=0 pending=0")

# Read session state if it exists
SESSION_ID=""
if [ -f "$SESSION_STATE" ]; then
    SESSION_ID=$(grep '^sessionId:' "$SESSION_STATE" 2>/dev/null | sed 's/^sessionId:[[:space:]]*//' || true)
fi

# Complete the session turn if we have a session ID
if [ -n "$SESSION_ID" ]; then
    CLOSE_PARAMS="agent: ClaudeCode
sessionId: ${SESSION_ID}
status: completed"
    repl_invoke "workflow.sessionlog.closeSession" "$CLOSE_PARAMS" >/dev/null 2>&1 || true
fi

# Clean up session state
rm -f "$SESSION_STATE"

printf '{"hookSpecificOutput":{"status":"completed","cacheFlush":"%s"}}\n' "$FLUSH_RESULT"
