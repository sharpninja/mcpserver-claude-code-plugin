#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for the McpServer Claude Code plugin.
# Persists the current session log turn and flushes the write cache before
# Claude Code performs a context compaction.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CACHE_DIR="${PLUGIN_ROOT_OVERRIDE:-$CLAUDE_PLUGIN_ROOT}/cache"
SESSION_STATE="$CACHE_DIR/session-state.yaml"

# Source libraries if not already loaded
if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

if ! type cache_flush >/dev/null 2>&1; then
    # shellcheck source=../../lib/cache-manager.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/cache-manager.sh"
fi

# Read session state
SESSION_ID=""
if [ -f "$SESSION_STATE" ]; then
    SESSION_ID=$(grep '^sessionId:' "$SESSION_STATE" 2>/dev/null | sed 's/^sessionId:[[:space:]]*//' || true)
fi

# Update the session turn with compaction tag before compacting
if [ -n "$SESSION_ID" ]; then
    UPDATE_PARAMS="agent: ClaudeCode
sessionId: ${SESSION_ID}
tags:
  - pre-compact
status: persisting"
    repl_invoke "workflow.sessionlog.updateTurn" "$UPDATE_PARAMS" >/dev/null 2>&1 || true
fi

# Flush cache so no pending items are lost during compaction
FLUSH_RESULT=$(cache_flush 2>/dev/null || echo "flushed=0 failed=0 pending=0")

printf '{"hookSpecificOutput":{"status":"persisted","cacheFlush":"%s"}}\n' "$FLUSH_RESULT"
