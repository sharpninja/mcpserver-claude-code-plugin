#!/usr/bin/env bats

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "mutable internal TODO cache state is ignored by git" {
    run git -C "$PLUGIN_ROOT" check-ignore cache/internal-todo.yaml
    [ "$status" -eq 0 ]

    run git -C "$PLUGIN_ROOT" ls-files --error-unmatch cache/internal-todo.yaml
    [ "$status" -ne 0 ]
}
