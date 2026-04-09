#!/usr/bin/env bash
# cache-flush.sh — Standalone script to flush the MCP write cache.
# Sources cache-manager.sh and calls cache_flush, printing the summary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Source cache manager (which sources repl-invoke if needed)
if ! type cache_flush >/dev/null 2>&1; then
    export PLUGIN_ROOT_OVERRIDE="${PLUGIN_ROOT_OVERRIDE:-$CLAUDE_PLUGIN_ROOT}"
    # shellcheck source=../../lib/cache-manager.sh
    source "$CLAUDE_PLUGIN_ROOT/lib/cache-manager.sh"
fi

RESULT=$(cache_flush 2>/dev/null || echo "flushed=0 failed=0 pending=0")
echo "$RESULT"
