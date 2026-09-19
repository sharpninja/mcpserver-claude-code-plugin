#!/usr/bin/env bats

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/memory/SKILL.md"
DESCRIPTOR="$PLUGIN_ROOT/memory-descriptor.json"

@test "memory skill exists and loads" {
    [ -s "$SKILL" ]
    head -1 "$SKILL" | grep -q "^---$"
    grep -q "^name: memory" "$SKILL"
    grep -q "memory_remember" "$SKILL"
    grep -q "memory_recall" "$SKILL"
    grep -q "memory_explore" "$SKILL"
    grep -q "memory_consolidate" "$SKILL"
    grep -q "memory_promote" "$SKILL"
    grep -q "workflow.memory.remember" "$SKILL"
    grep -q "workflow.memory.recall" "$SKILL"
    grep -q "workflow.memory.list" "$SKILL"
    grep -q "lib/repl-invoke.ps1" "$SKILL"
    grep -q "skills/memory/scripts/invoke.ps1" "$SKILL"
    grep -qi "injection" "$SKILL"
    grep -qi "fallback" "$SKILL"
    grep -q "does not register native MCP" "$SKILL"
}

@test "memory descriptor exists and lists required verbs" {
    [ -s "$DESCRIPTOR" ]
    grep -q '"host": "claude-code"' "$DESCRIPTOR"
    grep -q "memory_remember" "$DESCRIPTOR"
    grep -q "memory_recall" "$DESCRIPTOR"
    grep -q "memory_explore" "$DESCRIPTOR"
    grep -q "memory_consolidate" "$DESCRIPTOR"
    grep -q "memory_promote" "$DESCRIPTOR"
    grep -q "workflow.memory.remember" "$DESCRIPTOR"
    grep -q "workflow.memory.list" "$DESCRIPTOR"
    grep -q "injection" "$DESCRIPTOR"
    grep -q "fallback" "$DESCRIPTOR"
    grep -q "workflowMethods" "$DESCRIPTOR"
}

@test "user-prompt-submit hook wires memory-descriptor injection" {
    local hook="$PLUGIN_ROOT/hooks/scripts/user-prompt-submit.ps1"
    local helper="$PLUGIN_ROOT/hooks/scripts/memory-context.ps1"
    [ -s "$hook" ]
    [ -s "$helper" ]
    grep -q "memory-context.ps1" "$hook"
    grep -q "Add-McpRequiredMemoryToHookOutput" "$hook"
    grep -q "memory-descriptor.json" "$helper"
    grep -q "workflow.memory.list" "$helper"
    grep -q "REQUIRED MEMORIES" "$helper"
}
