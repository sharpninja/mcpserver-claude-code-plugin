#!/usr/bin/env bash
# post-compact.sh — PostCompact hook for the McpServer Claude Code plugin.
# Re-verifies the marker signature after compaction and reloads MCP session
# history into Claude Code via hookSpecificOutput.additionalContext.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=../../lib/resolve-cache-dir.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/resolve-cache-dir.sh"
fi
CACHE_DIR="$(resolve_cache_dir)"
SESSION_STATE="$CACHE_DIR/session-state.yaml"

# Source libraries if not already loaded
if ! type full_bootstrap >/dev/null 2>&1; then
    # shellcheck source=../../lib/marker-resolver.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/marker-resolver.sh"
fi

if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

# Re-verify the marker after compaction
if ! full_bootstrap 2>/dev/null; then
    printf '{"hookSpecificOutput":{"status":"MCP_UNTRUSTED","additionalContext":""}}\n'
    exit 0
fi

# Read session state for session ID
SESSION_ID=""
if [ -f "$SESSION_STATE" ]; then
    SESSION_ID=$(grep '^sessionId:' "$SESSION_STATE" 2>/dev/null | sed 's/^sessionId:[[:space:]]*//' || true)
fi

# Query recent session history
HISTORY_CONTEXT=""
if [ -n "$SESSION_ID" ]; then
    HISTORY_PARAMS="agent: ClaudeCode
sessionId: ${SESSION_ID}"
    HISTORY_CONTEXT=$(repl_invoke "workflow.sessionlog.getHistory" "$HISTORY_PARAMS" 2>/dev/null || echo "")
fi

# Escape the context for JSON embedding (basic escaping)
ESCAPED_CONTEXT=$(node -e "process.stdout.write(JSON.stringify(require('fs').readFileSync('/dev/stdin','utf8')))" \
    <<< "$HISTORY_CONTEXT" 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$HISTORY_CONTEXT" | sed 's/"/\\"/g')")

printf '{"hookSpecificOutput":{"status":"reloaded","additionalContext":%s}}\n' "$ESCAPED_CONTEXT"
