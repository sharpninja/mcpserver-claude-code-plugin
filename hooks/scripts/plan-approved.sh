#!/usr/bin/env bash
# plan-approved.sh — PostToolUse/ExitPlanMode hook.
# Reads the approved plan file, extracts the title from the first # heading,
# creates a TODO via repl_invoke, and records the mapping in cache/plan-todo-map.yaml.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CACHE_DIR="${PLUGIN_ROOT_OVERRIDE:-$CLAUDE_PLUGIN_ROOT}/cache"
PLAN_MAP="$CACHE_DIR/plan-todo-map.yaml"

# Source libraries if not already loaded
if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

# Resolve plan file path from TOOL_INPUT or first argument
PLAN_FILE="${TOOL_INPUT:-${1:-}}"

if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
    # Nothing to do — no plan file provided
    printf '{"hookSpecificOutput":{"status":"skipped","reason":"no plan file"}}\n'
    exit 0
fi

# Extract title from first # heading
PLAN_TITLE=$(grep -m1 '^# ' "$PLAN_FILE" 2>/dev/null | sed 's/^# //' || true)

if [ -z "$PLAN_TITLE" ]; then
    PLAN_TITLE="$(basename "$PLAN_FILE" .md)"
fi

# Create TODO via REPL
TODO_PARAMS="title: ${PLAN_TITLE}
source: plan
planFile: ${PLAN_FILE}"

TODO_RESPONSE=$(repl_invoke "todo.create" "$TODO_PARAMS" 2>/dev/null || echo "")

# Extract todo ID from response
TODO_ID=$(echo "$TODO_RESPONSE" | grep '^id:' | head -1 | sed 's/^id:[[:space:]]*//' || echo "")

# Persist the plan -> todo mapping
mkdir -p "$CACHE_DIR"
if [ ! -f "$PLAN_MAP" ]; then
    cat > "$PLAN_MAP" << 'YAML'
entries: []
YAML
fi

# Append the new entry
cat >> "$PLAN_MAP" << YAML
  - planFile: ${PLAN_FILE}
    todoId: ${TODO_ID}
    title: ${PLAN_TITLE}
    createdAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YAML

printf '{"hookSpecificOutput":{"status":"created","todoId":"%s","title":"%s"}}\n' \
    "$TODO_ID" "$PLAN_TITLE"
