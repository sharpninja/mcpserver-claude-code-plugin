#!/usr/bin/env bats
# Backfilled from plugins/mcpserver/tests/hooks/stop-gate.test.sh in the
# marketplace mirror. Guards the contract between the workflow.sessionlog.*
# shim in lib/repl-invoke.sh and the Stop hook (hooks/scripts/stop-gate.sh).
#
# Original regression: shim never flipped current-turn.yaml status, so
# stop-gate.sh blocked every Stop with the in_progress reason. This suite
# exercises both sides plus their end-to-end contract.

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$PLUGIN_ROOT/lib/repl-invoke.sh"
STOP_GATE="$PLUGIN_ROOT/hooks/scripts/stop-gate.sh"
source "$PLUGIN_ROOT/tests/cache-scope-helper.bash"

setup() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/cache" "$SANDBOX/workspace"

    export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
    export PLUGIN_ROOT_OVERRIDE="$SANDBOX"
    unset CLAUDE_STOP_HOOK_ACTIVE
    init_test_cache "$SANDBOX/workspace" "ClaudeCode-20260419T000000Z-test"
}

teardown() {
    rm -rf "$SANDBOX"
}

write_turn() {
    local status="${1:-in_progress}" edits="${2:-0}" build="${3:-unknown}"
    cat > "$(test_cache_file current-turn.yaml)" <<EOF
turnRequestId: req-test-stop-001
queryTitle: Stop gate test
openedAt: 2026-04-19T00:00:00Z
status: ${status}
codeEdits: ${edits}
lastBuildStatus: ${build}
EOF
}

run_stop_gate() {
    bash "$STOP_GATE" </dev/null 2>/dev/null
}

@test "no turn file → schema-valid no-op output" {
    rm -f "$(test_cache_file current-turn.yaml)"
    out="$(run_stop_gate)"
    # Stop pass-through must not emit a hookSpecificOutput.status (Claude Code
    # rejects it as "(root): Invalid input"). The canonical allow output is {}.
    [ "$out" = "{}" ]
}

@test "in_progress turn → self-heal emits no-op (not block)" {
    write_turn "in_progress"
    out="$(run_stop_gate)"
    [ "$out" = "{}" ]
    echo "$out" | grep -qvF '"decision":"block"'
}

@test "in_progress self-heal flips turn to completed" {
    write_turn "in_progress"
    run_stop_gate >/dev/null
    status_after="$(grep '^status:' "$(test_cache_file current-turn.yaml)" | head -1 | sed 's/^status:[[:space:]]*//')"
    [ "$status_after" = "completed" ]
}

@test "completed turn (clean build) → schema-valid no-op output" {
    write_turn "completed"
    out="$(run_stop_gate)"
    [ "$out" = "{}" ]
}

@test "completed turn with failed build + edits → decision:block" {
    write_turn "completed" 3 "failed"
    out="$(run_stop_gate)"
    echo "$out" | grep -qF '"decision":"block"'
    echo "$out" | grep -qF "code edit"
}

@test "accept-failure marker unblocks failed-build stop" {
    write_turn "completed" 3 "failed"
    touch "$(test_cache_file turn-accept-failure.marker)"
    out="$(run_stop_gate)"
    [ "$out" = "{}" ]
}

@test "accept-failure marker is consumed (deleted) after use" {
    write_turn "completed" 3 "failed"
    touch "$(test_cache_file turn-accept-failure.marker)"
    run_stop_gate >/dev/null
    [ ! -f "$(test_cache_file turn-accept-failure.marker)" ]
}

@test "end-to-end: shim's completeTurn flips cache so stop-gate passes" {
    write_turn "in_progress"

    cat > "$(test_cache_file session-state.yaml)" <<EOF
status: verified
sessionId: ClaudeCode-20260419T000000Z-test
workspacePath: "/tmp/ws"
workspace: "test"
baseUrl: "http://localhost:1"
timestamp: "2026-04-19T00:00:00Z"
EOF

    # shellcheck source=/dev/null
    ( source "$LIB" && repl_invoke "workflow.sessionlog.completeTurn" "requestId: req-test-stop-001
response: |
  E2E test response." ) >/dev/null 2>&1

    status_after="$(grep '^status:' "$(test_cache_file current-turn.yaml)" | head -1 | sed 's/^status:[[:space:]]*//')"
    [ "$status_after" = "completed" ]

    out="$(run_stop_gate)"
    [ "$out" = "{}" ]
}

@test "CLAUDE_STOP_HOOK_ACTIVE=true short-circuits with schema-valid no-op" {
    write_turn "in_progress"
    export CLAUDE_STOP_HOOK_ACTIVE=true
    out="$(run_stop_gate)"
    unset CLAUDE_STOP_HOOK_ACTIVE
    [ "$out" = "{}" ]
}

@test "in_progress self-heal with codexJsonlPath passes and uses JSONL enrichment" {
    command -v node >/dev/null 2>&1 || skip "node not available"
    FIXTURES="$PLUGIN_ROOT/tests/fixtures"
    # Write turn file that references a real JSONL fixture
    cat > "$(test_cache_file current-turn.yaml)" <<EOF
turnRequestId: req-test-stop-jsonl-001
queryTitle: Stop gate JSONL test
openedAt: 2026-04-19T00:00:00Z
status: in_progress
codeEdits: 0
lastBuildStatus: unknown
codexJsonlPath: "${FIXTURES}/parent-rollout.jsonl"
EOF
    out="$(run_stop_gate)"
    # Self-heal must pass regardless of JSONL enrichment outcome
    [ "$out" = "{}" ]
    # Turn file status must be flipped to completed
    status_after="$(grep '^status:' "$(test_cache_file current-turn.yaml)" | head -1 | sed 's/^status:[[:space:]]*//')"
    [ "$status_after" = "completed" ]
}
