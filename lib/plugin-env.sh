#!/usr/bin/env bash
# plugin-env.sh - host knob defaults for the claude-code plugin (generated).
MCP_PLUGIN_HOST="${MCP_PLUGIN_HOST:-claude-code}"
# shellcheck source=./plugin-env.template.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugin-env.template.sh"
