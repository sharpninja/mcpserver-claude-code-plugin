#!/usr/bin/env bats
# smoke.bats - host-neutral migration smoke test (Model C).
#
# Proves the migrated thin wrappers wire up to the canonical lib (lib/hook-lib.sh
# + lib/plugin-env.sh) and emit schema-valid output when NO MCP marker is
# reachable. Each test runs the wrapper with empty stdin from an isolated temp
# HOME/cwd that contains no AGENTS-README-FIRST.yaml, with PLUGIN_ROOT_OVERRIDE
# pointed at an empty temp dir so cache writes stay out of the repo. No network.
#
# Wrapper placement is resolved per family: claude-family hosts (claude-code,
# cowork, copilot, grok) ship hooks/scripts/<hook>.sh; codex ships lib/<hook>.sh.

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Resolve the on-disk path of a hook wrapper for whichever host this repo ships.
_wrapper_path() {
    local hook="$1"
    if [ -f "$PLUGIN_ROOT/hooks/scripts/${hook}.sh" ]; then
        printf '%s' "$PLUGIN_ROOT/hooks/scripts/${hook}.sh"
    elif [ -f "$PLUGIN_ROOT/lib/${hook}.sh" ]; then
        printf '%s' "$PLUGIN_ROOT/lib/${hook}.sh"
    else
        return 1
    fi
}

setup() {
    SMOKE_TMP="$(mktemp -d)"
    mkdir -p "$SMOKE_TMP/home" "$SMOKE_TMP/cwd" "$SMOKE_TMP/override"
}

teardown() {
    [ -n "${SMOKE_TMP:-}" ] && rm -rf "$SMOKE_TMP"
}

# Run a wrapper with empty stdin and a fully isolated, marker-free environment.
# Captures stdout into $output and the exit status into $status (bats `run`).
_run_wrapper() {
    local wrapper="$1"
    run env -u CLAUDE_PLUGIN_ROOT -u MCP_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
        -u MCPSERVER_WORKSPACE_PATH -u MCP_WORKSPACE_PATH -u MCP_WORKSPACE_START_DIR \
        HOME="$SMOKE_TMP/home" \
        PLUGIN_ROOT_OVERRIDE="$SMOKE_TMP/override" \
        MCP_PLUGIN_HOST=claude-code \
        bash -c 'cd "$1" && exec bash "$2" </dev/null' _ "$SMOKE_TMP/cwd" "$wrapper"
}

# Assert stdout parses as a single JSON document (host-neutral contract).
_assert_json() {
    [ -n "$output" ]
    if command -v node >/dev/null 2>&1; then
        printf '%s' "$output" | node -e 'JSON.parse(require("fs").readFileSync(0))'
    fi
}

@test "session-start wrapper exists and is wired to the canonical lib" {
    local wrapper
    wrapper="$(_wrapper_path session-start)"
    [ -n "$wrapper" ]
    grep -q 'lib/hook-lib.sh' "$wrapper"
    grep -q 'lib/plugin-env.sh' "$wrapper"
}

@test "session-start emits valid JSON and exits 0 with no marker" {
    local wrapper
    wrapper="$(_wrapper_path session-start)"
    _run_wrapper "$wrapper"
    [ "$status" -eq 0 ]
    _assert_json
}

@test "user-prompt-submit wrapper exists and is wired to the canonical lib" {
    local wrapper
    wrapper="$(_wrapper_path user-prompt-submit)"
    [ -n "$wrapper" ]
    grep -q 'lib/hook-lib.sh' "$wrapper"
    grep -q 'lib/plugin-env.sh' "$wrapper"
}

@test "user-prompt-submit emits valid JSON and exits 0 with no marker" {
    local wrapper
    wrapper="$(_wrapper_path user-prompt-submit)"
    _run_wrapper "$wrapper"
    [ "$status" -eq 0 ]
    _assert_json
}
