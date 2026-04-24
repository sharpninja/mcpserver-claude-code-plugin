#!/usr/bin/env bash
# plan-modified.sh — PostToolUse/Write|Edit hook for plan files.
# Looks up the modified file in cache/plan-todo-map.yaml and updates the
# corresponding TODO via repl_invoke. Skips silently when no mapping exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=../../lib/resolve-cache-dir.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/resolve-cache-dir.sh"
fi
CACHE_DIR="$(resolve_cache_dir)"
PLAN_MAP="$CACHE_DIR/plan-todo-map.yaml"

# Source libraries if not already loaded
if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

# Resolve file path from TOOL_INPUT or first argument
FILE_PATH="${TOOL_INPUT:-${1:-}}"

if [ -z "$FILE_PATH" ]; then
    printf '{"hookSpecificOutput":{"status":"skipped","reason":"no file path"}}\n'
    exit 0
fi

# Check if plan-todo-map.yaml exists
if [ ! -f "$PLAN_MAP" ]; then
    printf '{"hookSpecificOutput":{"status":"skipped","reason":"no plan-todo-map"}}\n'
    exit 0
fi

# Look up the file in the mapping
TODO_ID=$(grep -A2 "planFile: ${FILE_PATH}" "$PLAN_MAP" 2>/dev/null \
    | grep 'todoId:' | head -1 | sed 's/.*todoId:[[:space:]]*//' || true)

if [ -z "$TODO_ID" ]; then
    printf '{"hookSpecificOutput":{"status":"skipped","reason":"no mapping for file"}}\n'
    exit 0
fi

# Update the TODO
UPDATE_PARAMS="id: ${TODO_ID}
planFile: ${FILE_PATH}
status: modified"

repl_invoke "todo.update" "$UPDATE_PARAMS" >/dev/null 2>&1 || true

printf '{"hookSpecificOutput":{"status":"updated","todoId":"%s"}}\n' "$TODO_ID"
