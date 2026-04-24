#!/usr/bin/env bash
# resolve-cache-dir.sh — workspace-aware cache path resolver.
#
# Cache state (session-state.yaml, current-turn.yaml, plan-todo-map.yaml,
# turn-accept-failure.marker, pending/, last-build.log) applies to the
# workspace the marker file is in, not the plugin install directory. This
# helper picks the right cache dir for the caller.
#
# Precedence:
#   1. $MCP_CACHE_DIR_OVERRIDE    — explicit override (any path).
#   2. $PLUGIN_ROOT_OVERRIDE/cache — legacy test hook (kept for bats suites).
#   3. <markerDir>/cache          — workspace resolved by walking up for
#                                   AGENTS-README-FIRST.yaml. Production path.
#   4. $CLAUDE_PLUGIN_ROOT/cache  — last-resort fallback.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/resolve-cache-dir.sh"
#   CACHE_DIR="$(resolve_cache_dir)"

# Guard: avoid re-defining if already sourced.
if type resolve_cache_dir >/dev/null 2>&1; then
    return 0 2>/dev/null || true
fi

_RESOLVE_CACHE_DIR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_cache_dir() {
    if [ -n "${MCP_CACHE_DIR_OVERRIDE:-}" ]; then
        printf '%s' "$MCP_CACHE_DIR_OVERRIDE"
        return 0
    fi

    if [ -n "${PLUGIN_ROOT_OVERRIDE:-}" ]; then
        printf '%s/cache' "$PLUGIN_ROOT_OVERRIDE"
        return 0
    fi

    # Walk up for the workspace marker. Prefer CLAUDE_PROJECT_DIR when
    # Claude Code exports it; fall back to CWD.
    local start_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

    if ! type find_marker_file >/dev/null 2>&1; then
        # Best-effort source. marker-resolver.sh lives alongside this file.
        # shellcheck source=./marker-resolver.sh
        source "$_RESOLVE_CACHE_DIR_SCRIPT_DIR/marker-resolver.sh" 2>/dev/null || true
    fi

    if type find_marker_file >/dev/null 2>&1; then
        local marker_file
        if marker_file=$(find_marker_file "$start_dir" 2>/dev/null); then
            printf '%s/cache' "$(dirname "$marker_file")"
            return 0
        fi
    fi

    local plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$_RESOLVE_CACHE_DIR_SCRIPT_DIR/.." && pwd)}"
    printf '%s/cache' "$plugin_root"
}

export -f resolve_cache_dir 2>/dev/null || true
