#!/usr/bin/env bash
# health-check.sh — Verify McpServer connectivity via the REPL bootstrap method.
# Exits 0 if the server responds, exits 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Source repl-invoke if not already loaded
if ! type repl_invoke >/dev/null 2>&1; then
    # shellcheck source=../../lib/repl-invoke.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/repl-invoke.sh"
fi

if repl_invoke "workflow.sessionlog.bootstrap" "" >/dev/null 2>&1; then
    echo "health: ok"
    exit 0
else
    echo "health: failed" >&2
    exit 1
fi
