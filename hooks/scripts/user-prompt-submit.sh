#!/usr/bin/env bash
# user-prompt-submit.sh — UserPromptSubmit hook for the McpServer Claude Code plugin.
#
# Runs on every user prompt. Auto-opens a session log turn via
# workflow.sessionlog.beginTurn so agents cannot skip the Per-User-Message
# protocol required by AGENTS-README-FIRST.yaml. Writes the active turn's
# requestId to cache/current-turn.yaml so the Stop hook can verify the turn
# was completed before the response finalizes.
#
# Input (stdin): Claude Code UserPromptSubmit payload as JSON with at least:
#   { "prompt": "<user message>", "session_id": "...", ... }
#
# Output (stdout): JSON with optional additionalContext. Exits 0 unconditionally
# so prompt processing never blocks on MCP issues (graceful degradation).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_PLUGIN_ROOT}"
if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=../../lib/resolve-cache-dir.sh
    source "$SCRIPT_PLUGIN_ROOT/lib/resolve-cache-dir.sh"
fi
CACHE_DIR="$(resolve_cache_dir)"

mkdir -p "$CACHE_DIR"
LOCK_DIR="$CACHE_DIR/user-prompt-submit.lock"
if [ -d "$LOCK_DIR" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt "${MCP_PLUGIN_STALE_LOCK_SECONDS:-120}" ]; then
        rm -rf "$LOCK_DIR"
    fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","status":"already-running"}}\n'
    exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

# Source libraries
if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$SCRIPT_PLUGIN_ROOT/lib/repl-invoke.sh" 2>/dev/null || true
fi

# Read stdin into PAYLOAD (may be empty)
PAYLOAD="$(cat 2>/dev/null || true)"

# Extract the user prompt text. Prefer jq when available; fall back to grep/sed.
extract_prompt() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null
    else
        # Rough fallback — assumes no escaped quotes inside the prompt.
        printf '%s' "$PAYLOAD" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1
    fi
}

USER_PROMPT="$(extract_prompt)"

# If no MCP session established, short-circuit. Claude can still respond.
if [ ! -f "$CACHE_DIR/session-state.yaml" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","status":"no-session"}}\n'
    exit 0
fi

SESSION_STATUS="$(grep '^status:' "$CACHE_DIR/session-state.yaml" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//')"
if [ "$SESSION_STATUS" != "verified" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","status":"%s"}}\n' "$SESSION_STATUS"
    exit 0
fi

# Build a deterministic turn requestId
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RAND_SUFFIX="$(printf '%04x' $RANDOM)"
TURN_REQUEST_ID="req-${TIMESTAMP}-prompt-${RAND_SUFFIX}"

# Derive a short queryTitle from the first line of the prompt (max 60 chars)
QUERY_TITLE="$(printf '%s' "$USER_PROMPT" | head -1 | cut -c1-60)"
[ -z "$QUERY_TITLE" ] && QUERY_TITLE="User prompt"

# Escape the prompt for YAML embedding (preserve multi-line content via literal block)
QUERY_TEXT_BLOCK="$(printf '%s' "$USER_PROMPT" | sed 's/^/    /')"

TURN_PARAMS="requestId: ${TURN_REQUEST_ID}
queryTitle: ${QUERY_TITLE}
queryText: |
${QUERY_TEXT_BLOCK}"

# Open the turn. Graceful fallback to cache_write if REPL unavailable.
if type repl_invoke >/dev/null 2>&1; then
    PREVIOUS_REPL_TIMEOUT="${REPL_TIMEOUT:-}"
    export REPL_TIMEOUT="${REPL_SESSIONLOG_REPL_TIMEOUT:-8}"
    if ! repl_invoke "workflow.sessionlog.beginTurn" "$TURN_PARAMS" >/dev/null 2>&1; then
        if type cache_write >/dev/null 2>&1; then
            cache_write "workflow.sessionlog.beginTurn" "$TURN_PARAMS" >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "$PREVIOUS_REPL_TIMEOUT" ]; then
        export REPL_TIMEOUT="$PREVIOUS_REPL_TIMEOUT"
    else
        unset REPL_TIMEOUT
    fi
fi

# Discover Codex JSONL transcript path for this session (if running under Codex CLI).
# Codex may set CODEX_SESSION_FILE or CODEX_ROLLOUT_FILE; otherwise scan the session dir.
_CODEX_JSONL_PATH="${CODEX_SESSION_FILE:-${CODEX_ROLLOUT_FILE:-}}"
if [ -z "$_CODEX_JSONL_PATH" ] && command -v node >/dev/null 2>&1; then
    _CODEX_SESSION_DIR="${CODEX_SESSION_DIR:-${HOME}/.codex/sessions}"
    _TODAY_DIR="${_CODEX_SESSION_DIR}/$(date -u +%Y/%m/%d 2>/dev/null || true)"
    if [ -d "$_TODAY_DIR" ]; then
        _CODEX_JSONL_PATH="$(ls -t "${_TODAY_DIR}"/rollout-*.jsonl 2>/dev/null | head -1 || true)"
    fi
fi

# Record the active turn so Stop hook can verify completion.
mkdir -p "$CACHE_DIR"
{
    printf 'turnRequestId: %s\n' "${TURN_REQUEST_ID}"
    printf 'queryTitle: %s\n' "${QUERY_TITLE}"
    printf 'openedAt: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status: in_progress\n'
    printf 'codeEdits: 0\n'
    printf 'lastBuildStatus: unknown\n'
    if [ -n "$_CODEX_JSONL_PATH" ] && [ -f "$_CODEX_JSONL_PATH" ]; then
        printf 'codexJsonlPath: "%s"\n' "$_CODEX_JSONL_PATH"
    fi
} > "$CACHE_DIR/current-turn.yaml"

INTERNAL_TODO_REMINDER="Use TODO and requirements tools only as needed."
if type _repl_internal_todo_is_enabled >/dev/null 2>&1 && _repl_internal_todo_is_enabled; then
    INTERNAL_TODO_REMINDER="MCP-backed internal TODO tracking is enabled. Mirror durable plan items through workflow.todo.* and keep only transient execution details in the local checklist."
fi

# Inject a per-turn reminder into Claude's context so the agent sees the
# exact contract that applies to this turn. The stop-gate hook auto-closes
# the turn via the plugin's own repl-invoke.sh shim — Claude is NOT expected
# to invoke workflow.sessionlog.* (those verbs are not exposed as MCP tools).
REMINDER="session log turn ${TURN_REQUEST_ID} is now active. ${INTERNAL_TODO_REMINDER} The stop-gate hook will auto-close the turn on finalize. PostToolUse/Write|Edit hooks auto-log actions. If you want richer action metadata, POST /mcpserver/sessionlog directly with the workspace API key from AGENTS-README-FIRST.yaml."

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","status":"turn-opened","turnRequestId":"%s","additionalContext":"%s"}}\n' \
    "$TURN_REQUEST_ID" \
    "$REMINDER"
exit 0
