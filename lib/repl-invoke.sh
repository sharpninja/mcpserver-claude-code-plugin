#!/usr/bin/env bash
set -uo pipefail

# repl_invoke <method> [params_yaml]
# Sends a YAML request envelope to mcpserver-repl --agent-stdio
# Returns the response payload on stdout, exit 1 on error.
#
# Translation shim: workflow.sessionlog.* methods are not server routes.
# They are plugin-local verbs that update cache/current-turn.yaml so the
# Stop hook can verify completion, and (best-effort) persist a session-log
# turn via the real client.SessionLog.SubmitAsync route.

REPL_INVOKE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPL_INVOKE_PLUGIN_ROOT="${PLUGIN_ROOT_OVERRIDE:-$(cd "$REPL_INVOKE_SCRIPT_DIR/.." && pwd)}"

if ! type resolve_cache_dir >/dev/null 2>&1; then
    # shellcheck source=./resolve-cache-dir.sh
    source "$REPL_INVOKE_SCRIPT_DIR/resolve-cache-dir.sh"
fi

# Cache dir is resolved lazily per-call so workspace context shifts (CWD,
# marker file appearing/moving) do not latch onto a stale path.
_repl_cache_dir() { resolve_cache_dir; }

_repl_yaml_get() {
    # _repl_yaml_get <yaml_text> <key>
    # Returns the inline scalar value (no block-scalar support).
    printf '%s\n' "$1" | grep "^[[:space:]]*$2:" | head -1 | sed "s/^[[:space:]]*$2:[[:space:]]*//"
}

_repl_unquote() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | sed 's/^"\(.*\)"$/\1/; s/^'\''\(.*\)'\''$/\1/')"
    printf '%s' "$value"
}

_repl_yaml_block_get() {
    # _repl_yaml_block_get <yaml_text> <key>
    printf '%s\n' "$1" | awk -v key="$2" '
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*\\|[[:space:]]*$" { capture = 1; next }
        capture {
            if ($0 ~ "^[^[:space:]]") {
                exit
            }
            sub(/^[[:space:]][[:space:]]/, "")
            print
        }
    '
}

_repl_list_block_get() {
    # _repl_list_block_get <yaml_text> <key>
    printf '%s\n' "$1" | awk -v key="$2" '
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*$" { capture = 1; next }
        capture {
            if ($0 ~ "^[^[:space:]]") {
                exit
            }
            sub(/^[[:space:]][[:space:]]/, "")
            print
        }
    '
}

_repl_state_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 1
    grep "^${key}:" "$file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//"
}

_repl_session_state_value() {
    _repl_state_value "$(_repl_cache_dir)/session-state.yaml" "$1"
}

_repl_now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

_repl_response_is_error() {
    printf '%s\n' "${1:-}" | grep -q 'type: error'
}

_repl_response_has_empty_result() {
    printf '%s\n' "${1:-}" | awk '
        /^[[:space:]]*result:[[:space:]]*$/ { in_result = 1; next }
        in_result && /^[[:space:]]*$/ { next }
        in_result && /^    [^[:space:]]/ { found_child = 1; exit }
        in_result && /^[^[:space:]]/ { empty_result = 1; exit }
        END { exit((in_result && !found_child) || empty_result ? 0 : 1) }
    '
}

_repl_response_is_nonempty_success() {
    local response="${1:-}"
    ! _repl_response_is_error "$response" && ! _repl_response_has_empty_result "$response"
}

_repl_path_for_bash() {
    local path_value="$(_repl_unquote "${1:-}")"
    if [ -z "$path_value" ]; then
        return 1
    fi

    if command -v cygpath >/dev/null 2>&1 && printf '%s' "$path_value" | grep -Eq '^[A-Za-z]:[\\/]'; then
        cygpath -u "$path_value"
        return $?
    fi

    printf '%s' "$path_value"
}

_repl_marker_field() {
    local marker_file="$1"
    local field="$2"
    local default_value="${3:-}"

    if [ -n "$marker_file" ] && declare -F parse_marker_field >/dev/null 2>&1; then
        parse_marker_field "$marker_file" "$field" 2>/dev/null || printf '%s' "$default_value"
        return 0
    fi

    printf '%s' "$default_value"
}

_repl_write_requirements_state() {
    local workspace_path="$1"
    local workspace="$2"
    local base_url="$3"
    local cache_dir session_file tmp

    cache_dir="$(_repl_cache_dir)"
    mkdir -p "$cache_dir"
    session_file="${cache_dir}/session-state.yaml"
    tmp="${session_file}.tmp.$$"
    {
        printf 'status: verified\n'
        printf 'workspacePath: "%s"\n' "$workspace_path"
        printf 'workspace: "%s"\n' "$workspace"
        printf 'baseUrl: "%s"\n' "$base_url"
        printf 'timestamp: "%s"\n' "$(_repl_now_iso)"
    } > "$tmp" && mv "$tmp" "$session_file"
}

_repl_requirements_sync_state() {
    local params_yaml="${1:-}"
    local start_dir marker_file marker_workspace marker_workspace_name marker_base_url existing_workspace

    start_dir="$(_repl_unquote "$(_repl_yaml_get "$params_yaml" "workspacePath")")"
    [ -z "$start_dir" ] && start_dir="$(pwd)"
    start_dir="$(_repl_path_for_bash "$start_dir" 2>/dev/null || printf '%s' "$start_dir")"

    if ! declare -F find_marker_file >/dev/null 2>&1 || ! declare -F parse_marker_field >/dev/null 2>&1; then
        # shellcheck source=./marker-resolver.sh
        source "${REPL_INVOKE_SCRIPT_DIR}/marker-resolver.sh" 2>/dev/null || true
    fi

    if ! declare -F find_marker_file >/dev/null 2>&1; then
        return 0
    fi

    marker_file="$(find_marker_file "$start_dir" 2>/dev/null || true)"
    [ -n "$marker_file" ] || return 0

    marker_workspace="$(_repl_unquote "$(parse_marker_field "$marker_file" "workspacePath" 2>/dev/null || true)")"
    marker_workspace_name="$(_repl_unquote "$(parse_marker_field "$marker_file" "workspace" 2>/dev/null || true)")"
    marker_base_url="$(_repl_unquote "$(parse_marker_field "$marker_file" "baseUrl" 2>/dev/null || true)")"
    existing_workspace="$(_repl_unquote "$(_repl_session_state_value "workspacePath")")"

    if [ -n "$marker_workspace" ] && [ "$existing_workspace" != "$marker_workspace" ]; then
        [ -z "$marker_workspace_name" ] && marker_workspace_name="$(basename "$marker_workspace")"
        _repl_write_requirements_state "$marker_workspace" "$marker_workspace_name" "$marker_base_url"
    fi
}

_repl_session_meta() {
    # Echo "sourceType sessionId" extracted from cache/session-state.yaml.
    local f="$(_repl_cache_dir)/session-state.yaml"
    [ -f "$f" ] || return 1
    local sid
    sid="$(grep '^sessionId:' "$f" | head -1 | sed 's/^sessionId:[[:space:]]*//')"
    [ -z "$sid" ] && return 1
    local prefix="${sid%%-*}"
    printf '%s %s' "$prefix" "$sid"
}

_repl_invoke_raw() {
    local method="$1"
    local params_yaml="${2:-}"
    local request_id="req-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $RANDOM)"
    local timeout="${REPL_TIMEOUT:-30}"

    if ! command -v mcpserver-repl >/dev/null 2>&1; then
        echo "ERROR: mcpserver-repl not found on PATH" >&2
        return 1
    fi

    local envelope="type: request
payload:
  requestId: ${request_id}
  method: ${method}"

    if [ -n "$params_yaml" ]; then
        local indented_params
        indented_params=$(echo "$params_yaml" | sed 's/^/    /')
        envelope="${envelope}
  params:
${indented_params}"
    fi

    local response
    if response=$(echo "$envelope" | timeout "$timeout" mcpserver-repl --agent-stdio 2>/dev/null); then
        echo "$response"
        # mcpserver-repl returns 0 even on protocol errors; surface them.
        if echo "$response" | grep -q '^type: error'; then
            return 1
        fi
        return 0
    fi
    echo "ERROR: mcpserver-repl invocation failed for method ${method}" >&2
    return 1
}

_repl_invoke_raw_in_workspace() {
    local method="$1"
    local params_yaml="${2:-}"
    local request_id="req-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $RANDOM)"
    local timeout="${REPL_TIMEOUT:-30}"

    if ! command -v mcpserver-repl >/dev/null 2>&1; then
        echo "ERROR: mcpserver-repl not found on PATH" >&2
        return 1
    fi

    local workspace_path workspace_cwd base_url envelope indented_params response exit_code
    workspace_path="$(_repl_unquote "$(_repl_session_state_value "workspacePath")")"
    base_url="$(_repl_unquote "$(_repl_session_state_value "baseUrl")")"
    workspace_cwd="$(_repl_path_for_bash "$workspace_path" 2>/dev/null || printf '%s' "$(pwd)")"
    [ -z "$workspace_cwd" ] && workspace_cwd="$(pwd)"

    envelope="type: request
payload:
  requestId: ${request_id}
  method: ${method}"

    if [ -n "$params_yaml" ]; then
        indented_params="$(printf '%s\n' "$params_yaml" | sed 's/^/    /')"
        envelope="${envelope}
  params:
${indented_params}"
    fi

    response="$(
        printf '%s\n' "$envelope" | (
            cd "$workspace_cwd" || exit 1
            if [ -n "$workspace_path" ]; then
                export MCP_WORKSPACE_PATH="$workspace_path"
                export MCP_WORKSPACE="$workspace_path"
                export MCPSERVER_WORKSPACE_PATH="$workspace_path"
            fi
            if [ -n "$base_url" ]; then
                export MCP_SERVER_URL="$base_url"
                export MCPSERVER_BASE_URL="$base_url"
            fi
            if command -v timeout >/dev/null 2>&1; then
                timeout "$timeout" mcpserver-repl --agent-stdio
            else
                mcpserver-repl --agent-stdio
            fi
        ) 2>/dev/null
    )"

    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        printf '%s\n' "$response"
        if _repl_response_is_error "$response"; then
            return 1
        fi
        return 0
    fi

    echo "ERROR: mcpserver-repl invocation failed for method ${method}" >&2
    return 1
}

_repl_param_text() {
    local params_yaml="$1"
    local key="$2"
    local value
    value="$(_repl_yaml_block_get "$params_yaml" "$key")"
    if [ -z "$value" ]; then
        value="$(_repl_yaml_get "$params_yaml" "$key")"
    fi
    printf '%s' "$value"
}

_repl_first_param_text() {
    local params_yaml="$1"
    shift
    local key value
    for key in "$@"; do
        value="$(_repl_param_text "$params_yaml" "$key")"
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 0
}

_repl_yaml_field() {
    local indent="$1"
    local key="$2"
    local value="${3:-}"

    if [[ "$value" == *$'\n'* ]]; then
        printf '%s%s: |\n' "$indent" "$key"
        printf '%s\n' "$value" | sed "s/^/${indent}  /"
    elif [ -n "$value" ]; then
        printf '%s%s: %s\n' "$indent" "$key" "$value"
    else
        printf '%s%s: ""\n' "$indent" "$key"
    fi
}

_repl_requirement_list_field() {
    local params_yaml="$1"
    local key="$2"
    local single_key="$3"
    local indent="$4"
    local list_block single_value

    list_block="$(_repl_list_block_get "$params_yaml" "$key")"
    if [ -n "$list_block" ]; then
        printf '%s%s:\n' "$indent" "$key"
        printf '%s\n' "$list_block" | sed "s/^/${indent}  /"
        return 0
    fi

    single_value="$(_repl_yaml_get "$params_yaml" "$single_key")"
    if [ -n "$single_value" ]; then
        printf '%s%s:\n' "$indent" "$key"
        printf '%s  - %s\n' "$indent" "$single_value"
        return 0
    fi

    printf '%s%s: []\n' "$indent" "$key"
}

_repl_requirements_workflow_doc_type() {
    case "$(_repl_unquote "${1:-}")" in
        functional) printf 'fr' ;;
        technical) printf 'tr' ;;
        testing) printf 'test' ;;
        mapping) printf 'matrix' ;;
        "") printf 'all' ;;
        *) printf '%s' "$(_repl_unquote "${1:-}")" ;;
    esac
}

_repl_requirements_typed_doc_type() {
    case "$(_repl_unquote "${1:-}")" in
        fr) printf 'functional' ;;
        tr) printf 'technical' ;;
        test) printf 'testing' ;;
        matrix) printf 'mapping' ;;
        "") printf 'all' ;;
        *) printf '%s' "$(_repl_unquote "${1:-}")" ;;
    esac
}

_repl_requirements_workflow_params() {
    local operation="$1"
    local params_yaml="${2:-}"
    local format doc_type

    if [ "$operation" != "generateDocument" ]; then
        printf '%s' "$params_yaml"
        return 0
    fi

    format="$(_repl_yaml_get "$params_yaml" "format")"
    [ -z "$format" ] && format="markdown"
    doc_type="$(_repl_requirements_workflow_doc_type "$(_repl_yaml_get "$params_yaml" "docType")")"

    printf 'format: %s\n' "$format"
    printf 'docType: %s\n' "$doc_type"
}

_repl_requirements_typed_method() {
    case "$1" in
        listFr) printf 'client.Requirements.ListFrAsync' ;;
        getFr) printf 'client.Requirements.GetFrAsync' ;;
        createFr) printf 'client.Requirements.CreateFrAsync' ;;
        updateFr) printf 'client.Requirements.UpdateFrAsync' ;;
        deleteFr) printf 'client.Requirements.DeleteFrAsync' ;;
        listTr) printf 'client.Requirements.ListTrAsync' ;;
        getTr) printf 'client.Requirements.GetTrAsync' ;;
        createTr) printf 'client.Requirements.CreateTrAsync' ;;
        updateTr) printf 'client.Requirements.UpdateTrAsync' ;;
        deleteTr) printf 'client.Requirements.DeleteTrAsync' ;;
        listTest) printf 'client.Requirements.ListTestAsync' ;;
        getTest) printf 'client.Requirements.GetTestAsync' ;;
        createTest) printf 'client.Requirements.CreateTestAsync' ;;
        updateTest) printf 'client.Requirements.UpdateTestAsync' ;;
        deleteTest) printf 'client.Requirements.DeleteTestAsync' ;;
        listMappings) printf 'client.Requirements.ListMappingsAsync' ;;
        createMapping) printf 'client.Requirements.UpsertMappingAsync' ;;
        deleteMapping) printf 'client.Requirements.DeleteMappingAsync' ;;
        generateDocument) printf 'client.Requirements.GenerateAsync' ;;
        ingestDocument) printf 'client.Requirements.IngestAsync' ;;
        *) return 1 ;;
    esac
}

_repl_requirements_typed_params() {
    local operation="$1"
    local params_yaml="${2:-}"
    local id title body fr_id doc_type format content documents_block source_format preferred_wiki_format

    case "$operation" in
        listFr|listTr|listTest|listMappings)
            return 0
            ;;
        getFr|getTr|getTest|deleteFr|deleteTr|deleteTest)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            printf 'id: %s\n' "$id"
            ;;
        createFr)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            title="$(_repl_yaml_get "$params_yaml" "title")"
            body="$(_repl_first_param_text "$params_yaml" "description" "body")"
            printf 'request:\n'
            _repl_yaml_field "  " "id" "$id"
            _repl_yaml_field "  " "title" "$title"
            _repl_yaml_field "  " "body" "$body"
            ;;
        updateFr)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            title="$(_repl_yaml_get "$params_yaml" "title")"
            body="$(_repl_first_param_text "$params_yaml" "description" "body")"
            printf 'id: %s\nrequest:\n' "$id"
            _repl_yaml_field "  " "title" "$title"
            _repl_yaml_field "  " "body" "$body"
            ;;
        createTr)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            title="$(_repl_yaml_get "$params_yaml" "title")"
            body="$(_repl_first_param_text "$params_yaml" "description" "body")"
            printf 'request:\n'
            _repl_yaml_field "  " "id" "$id"
            _repl_yaml_field "  " "title" "$title"
            _repl_yaml_field "  " "body" "$body"
            ;;
        updateTr)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            title="$(_repl_yaml_get "$params_yaml" "title")"
            body="$(_repl_first_param_text "$params_yaml" "description" "body")"
            printf 'id: %s\nrequest:\n' "$id"
            _repl_yaml_field "  " "title" "$title"
            _repl_yaml_field "  " "body" "$body"
            ;;
        createTest)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            body="$(_repl_first_param_text "$params_yaml" "description" "condition")"
            printf 'request:\n'
            _repl_yaml_field "  " "id" "$id"
            _repl_yaml_field "  " "condition" "$body"
            ;;
        updateTest)
            id="$(_repl_yaml_get "$params_yaml" "id")"
            body="$(_repl_first_param_text "$params_yaml" "description" "condition")"
            printf 'id: %s\nrequest:\n' "$id"
            _repl_yaml_field "  " "condition" "$body"
            ;;
        createMapping)
            fr_id="$(_repl_yaml_get "$params_yaml" "frId")"
            printf 'frId: %s\nrequest:\n' "$fr_id"
            _repl_requirement_list_field "$params_yaml" "trIds" "trId" "  "
            _repl_requirement_list_field "$params_yaml" "testIds" "testId" "  "
            ;;
        deleteMapping)
            fr_id="$(_repl_yaml_get "$params_yaml" "frId")"
            printf 'frId: %s\n' "$fr_id"
            ;;
        generateDocument)
            doc_type="$(_repl_requirements_typed_doc_type "$(_repl_yaml_get "$params_yaml" "docType")")"
            format="$(_repl_yaml_get "$params_yaml" "format")"
            [ -z "$format" ] && format="markdown"
            printf 'doc: %s\n' "$doc_type"
            printf 'format: %s\n' "$format"
            ;;
        ingestDocument)
            content="$(_repl_param_text "$params_yaml" "content")"
            documents_block="$(_repl_list_block_get "$params_yaml" "documents")"
            source_format="$(_repl_yaml_get "$params_yaml" "sourceFormat")"
            preferred_wiki_format="$(_repl_yaml_get "$params_yaml" "preferredWikiFormat")"
            printf 'request:\n'
            if [ -n "$documents_block" ]; then
                [ -z "$source_format" ] && source_format="wiki"
                _repl_yaml_field "  " "sourceFormat" "$source_format"
                if [ -n "$preferred_wiki_format" ]; then
                    _repl_yaml_field "  " "preferredWikiFormat" "$preferred_wiki_format"
                fi
                printf '  documents:\n'
                printf '%s\n' "$documents_block" | sed 's/^/    /'
            else
                _repl_yaml_field "  " "functionalMarkdown" "$content"
                _repl_yaml_field "  " "technicalMarkdown" "$content"
                _repl_yaml_field "  " "testingMarkdown" "$content"
                _repl_yaml_field "  " "mappingMarkdown" "$content"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

_repl_requirements_normalize_generate_response() {
    local response="${1:-}"
    local request_id content_type file_name format doc_type generated_at decoded content_base64

    if ! printf '%s\n' "$response" | awk '
        /^[[:space:]]*content:[[:space:]]*$/ { in_content = 1; next }
        in_content && /^[[:space:]]*-[[:space:]]*[0-9]+[[:space:]]*$/ { found = 1; exit }
        in_content && /^[^[:space:]]|^[[:space:]]*[[:alpha:]_][[:alnum:]_]*:/ { in_content = 0 }
        END { exit(found ? 0 : 1) }
    '; then
        printf '%s\n' "$response"
        return 0
    fi

    request_id="$(printf '%s\n' "$response" | grep '^[[:space:]]*requestId:' | head -1 | sed 's/^[[:space:]]*requestId:[[:space:]]*//')"
    content_type="$(printf '%s\n' "$response" | grep '^[[:space:]]*contentType:' | head -1 | sed 's/^[[:space:]]*contentType:[[:space:]]*//')"
    file_name="$(printf '%s\n' "$response" | grep '^[[:space:]]*fileName:' | head -1 | sed 's/^[[:space:]]*fileName:[[:space:]]*//')"
    format="$(printf '%s\n' "$response" | grep '^[[:space:]]*format:' | head -1 | sed 's/^[[:space:]]*format:[[:space:]]*//')"
    doc_type="$(printf '%s\n' "$response" | grep '^[[:space:]]*docType:' | head -1 | sed 's/^[[:space:]]*docType:[[:space:]]*//')"
    generated_at="$(printf '%s\n' "$response" | grep '^[[:space:]]*generatedAt:' | head -1 | sed 's/^[[:space:]]*generatedAt:[[:space:]]*//')"
    [ -z "$content_type" ] && content_type="text/markdown"

    decoded="$(printf '%s\n' "$response" | awk '
        /^[[:space:]]*content:[[:space:]]*$/ { in_content = 1; next }
        in_content && /^[[:space:]]*-[[:space:]]*[0-9]+[[:space:]]*$/ {
            value = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            print value
            next
        }
        in_content && /^[^[:space:]]|^[[:space:]]*[[:alpha:]_][[:alnum:]_]*:/ { in_content = 0 }
    ' | while IFS= read -r byte_value; do
        printf "\\$(printf '%03o' "$byte_value")"
    done)"

    if printf '%s\n' "$content_type" | grep -qi 'zip' || printf '%s\n' "$file_name" | grep -qi '\.zip$'; then
        content_base64="$(printf '%s' "$decoded" | base64 | tr -d '\r\n')"
        [ -z "$file_name" ] && file_name="requirements-documents.zip"
        [ -z "$format" ] && format="markdown"
        [ -z "$doc_type" ] && doc_type="all"
        [ -z "$generated_at" ] && generated_at="$(_repl_now_iso)"

        printf 'type: result\npayload:\n'
        if [ -n "$request_id" ]; then
            printf '  requestId: %s\n' "$request_id"
        fi
        printf '  result:\n'
        printf '    contentBase64: %s\n' "$content_base64"
        printf '    contentType: %s\n' "$content_type"
        printf '    fileName: %s\n' "$file_name"
        printf '    format: %s\n' "$format"
        printf '    docType: %s\n' "$doc_type"
        printf '    generatedAt: %s\n' "$generated_at"
        return 0
    fi

    printf 'type: result\npayload:\n'
    if [ -n "$request_id" ]; then
        printf '  requestId: %s\n' "$request_id"
    fi
    printf '  result:\n'
    printf '    content: |\n'
    printf '%s\n' "$decoded" | sed 's/^/      /'
    printf '    contentType: %s\n' "$content_type"
    if [ -n "$format" ]; then
        printf '    format: %s\n' "$format"
    fi
    if [ -n "$doc_type" ]; then
        printf '    docType: %s\n' "$doc_type"
    fi
}

_repl_requirements_generate_http_fallback() {
    local params_yaml="${1:-}"
    local format doc_type workspace_path workspace_path_bash base_url marker_file api_key

    format="$(_repl_yaml_get "$params_yaml" "format")"
    [ -z "$format" ] && format="markdown"
    [ "$format" = "wiki" ] || return 1

    if ! command -v curl >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        return 1
    fi

    doc_type="$(_repl_requirements_typed_doc_type "$(_repl_yaml_get "$params_yaml" "docType")")"
    workspace_path="$(_repl_unquote "$(_repl_session_state_value "workspacePath")")"
    base_url="${MCPSERVER_BASE_URL:-$(_repl_unquote "$(_repl_session_state_value "baseUrl")")}"

    workspace_path_bash="$(_repl_path_for_bash "$workspace_path" 2>/dev/null || true)"
    if ! declare -F find_marker_file >/dev/null 2>&1 || ! declare -F parse_marker_field >/dev/null 2>&1; then
        # shellcheck source=./marker-resolver.sh
        source "${REPL_INVOKE_SCRIPT_DIR}/marker-resolver.sh" 2>/dev/null || true
    fi
    marker_file=""
    if [ -n "$workspace_path_bash" ] && declare -F find_marker_file >/dev/null 2>&1; then
        marker_file="$(find_marker_file "$workspace_path_bash" 2>/dev/null || true)"
    fi

    api_key="${MCPSERVER_API_KEY:-$(_repl_marker_field "$marker_file" "apiKey" "")}"
    [ -z "$workspace_path" ] && workspace_path="${MCPSERVER_WORKSPACE_PATH:-$(_repl_marker_field "$marker_file" "workspacePath" "")}"
    [ -z "$base_url" ] && base_url="$(_repl_marker_field "$marker_file" "baseUrl" "")"
    [ -z "$api_key" ] && return 1
    [ -z "$workspace_path" ] && return 1
    [ -z "$base_url" ] && return 1

    local tmp_body tmp_headers url content_type content_base64 curl_status cache_dir
    cache_dir="$(_repl_cache_dir)"
    mkdir -p "$cache_dir"
    tmp_body="${cache_dir}/requirements-generate.$$.$RANDOM.body"
    tmp_headers="${cache_dir}/requirements-generate.$$.$RANDOM.headers"
    url="${base_url%/}/mcpserver/requirements/generate?doc=${doc_type}&format=${format}"

    curl -fsSL \
        -D "$tmp_headers" \
        -o "$tmp_body" \
        -H "X-Api-Key: ${api_key}" \
        -H "X-Workspace-Path: ${workspace_path}" \
        "$url" >/dev/null 2>&1
    curl_status=$?
    if [ $curl_status -ne 0 ]; then
        rm -f "$tmp_body" "$tmp_headers"
        return $curl_status
    fi

    content_type="$(grep -i '^content-type:' "$tmp_headers" 2>/dev/null | head -1 | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r')"
    content_type="${content_type%%;*}"
    [ -z "$content_type" ] && content_type="application/zip"
    content_base64="$(base64 < "$tmp_body" | tr -d '\r\n')"
    rm -f "$tmp_body" "$tmp_headers"

    printf 'type: result\npayload:\n'
    printf '  result:\n'
    printf '    contentBase64: %s\n' "$content_base64"
    printf '    contentType: %s\n' "$content_type"
    if printf '%s\n' "$content_type" | grep -qi 'zip'; then
        printf '    fileName: requirements-wiki-documents.zip\n'
    fi
    printf '    format: %s\n' "$format"
    printf '    docType: %s\n' "$doc_type"
    printf '    generatedAt: %s\n' "$(_repl_now_iso)"
}

_repl_workflow_requirements() {
    local method="$1"
    local params_yaml="${2:-}"
    local operation="${method#workflow.requirements.}"
    local workflow_params typed_method typed_params response status

    _repl_requirements_typed_method "$operation" >/dev/null || {
        _repl_invoke_raw "$method" "$params_yaml"
        return $?
    }

    _repl_requirements_sync_state "$params_yaml"

    workflow_params="$(_repl_requirements_workflow_params "$operation" "$params_yaml")"
    response="$(_repl_invoke_raw_in_workspace "$method" "$workflow_params" 2>&1)"
    status=$?
    if [ $status -eq 0 ] && _repl_response_is_nonempty_success "$response"; then
        printf '%s\n' "$response"
        return 0
    fi

    typed_method="$(_repl_requirements_typed_method "$operation")"
    typed_params="$(_repl_requirements_typed_params "$operation" "$params_yaml")"
    response="$(_repl_invoke_raw_in_workspace "$typed_method" "$typed_params" 2>&1)"
    status=$?
    if [ $status -eq 0 ] && _repl_response_is_nonempty_success "$response"; then
        if [ "$operation" = "generateDocument" ]; then
            _repl_requirements_normalize_generate_response "$response"
        else
            printf '%s\n' "$response"
        fi
        return 0
    fi

    if [ "$operation" = "generateDocument" ]; then
        response="$(_repl_requirements_generate_http_fallback "$params_yaml" 2>&1)"
        status=$?
        if [ $status -eq 0 ] && _repl_response_is_nonempty_success "$response"; then
            printf '%s\n' "$response"
            return 0
        fi
    fi

    printf '%s\n' "$response"
    return $status
}

_repl_persist_turn() {
    # _repl_persist_turn <requestId> <queryTitle> <status> <responseText> [actionsYamlBlock]
    # Best-effort SubmitAsync. Returns 0 on success, non-zero on persist failure.
    local req_id="$1"
    local title="$2"
    local status="$3"
    local response_text="$4"
    local actions_block="${5:-}"

    local meta sourceType sessionId
    if ! meta="$(_repl_session_meta)"; then
        return 1
    fi
    sourceType="${meta%% *}"
    sessionId="${meta##* }"

    local resp_indented
    resp_indented="$(printf '%s' "$response_text" | sed 's/^/      /')"

    local actions_yaml=""
    if [ -n "$actions_block" ]; then
        actions_yaml="$(printf '%s' "$actions_block" | sed 's/^/      /')"
    fi

    local params="sessionLog:
  sourceType: ${sourceType}
  sessionId: ${sessionId}
  title: ${title}
  status: in_progress
  turns:
    - requestId: ${req_id}
      queryTitle: ${title}
      status: ${status}
      response: |
${resp_indented}"

    if [ -n "$actions_yaml" ]; then
        params="${params}
      actions:
${actions_yaml}"
    fi

    _repl_invoke_raw "client.SessionLog.SubmitAsync" "$params" >/dev/null 2>&1
}

_repl_workflow_begin_turn() {
    # No-op shim: user-prompt-submit.sh already wrote current-turn.yaml.
    return 0
}

_repl_workflow_append_actions() {
    # Increment codeEdits counter when params include filePath: lines.
    local params="$1"
    local turn_file="$(_repl_cache_dir)/current-turn.yaml"
    [ -f "$turn_file" ] || return 0

    # grep -c exits 1 on no-match; fall back to 0 so pipefail doesn't bubble.
    local added
    added="$(printf '%s\n' "$params" | grep -c '^[[:space:]]*filePath:' || true)"
    added="${added:-0}"
    [ "$added" -gt 0 ] || return 0

    local current
    current="$(grep '^codeEdits:' "$turn_file" | head -1 | sed 's/^codeEdits:[[:space:]]*//')"
    current="${current:-0}"
    local new=$((current + added))

    # Cross-platform sed -i (BSD vs GNU). Use a temp file for portability on Git-Bash.
    local tmp="${turn_file}.tmp.$$"
    awk -v n="$new" '
        /^codeEdits:/ { print "codeEdits: " n; next }
        { print }
    ' "$turn_file" > "$tmp" && mv "$tmp" "$turn_file"

    # Best-effort persist actions to server.
    local req_id title
    req_id="$(grep '^turnRequestId:' "$turn_file" | head -1 | sed 's/^turnRequestId:[[:space:]]*//')"
    title="$(grep '^queryTitle:' "$turn_file" | head -1 | sed 's/^queryTitle:[[:space:]]*//')"
    _repl_persist_turn "$req_id" "$title" "in_progress" "Actions appended." "$params" || true
    return 0
}

_repl_workflow_complete_turn() {
    # Flip status -> completed and persist response summary.
    local params="$1"
    local turn_file="$(_repl_cache_dir)/current-turn.yaml"
    [ -f "$turn_file" ] || return 0

    local req_id title response_text
    req_id="$(grep '^turnRequestId:' "$turn_file" | head -1 | sed 's/^turnRequestId:[[:space:]]*//')"
    title="$(grep '^queryTitle:' "$turn_file" | head -1 | sed 's/^queryTitle:[[:space:]]*//')"
    response_text="$(printf '%s\n' "$params" | sed -n '/^[[:space:]]*response:[[:space:]]*|/,$p' | sed '1d' | sed 's/^[[:space:]]\{0,8\}//')"
    if [ -z "$response_text" ]; then
        response_text="$(_repl_yaml_get "$params" 'response')"
    fi
    [ -z "$response_text" ] && response_text="(no response provided)"

    local tmp="${turn_file}.tmp.$$"
    awk '
        /^status:/ { print "status: completed"; next }
        { print }
    ' "$turn_file" > "$tmp" && mv "$tmp" "$turn_file"

    _repl_persist_turn "$req_id" "$title" "completed" "$response_text" "" || true
    return 0
}

_repl_workflow_open_session() {
    # No-op shim: session-start.sh already wrote session-state.yaml.
    return 0
}

repl_invoke() {
    local method="$1"
    local params_yaml="${2:-}"

    case "$method" in
        workflow.sessionlog.beginTurn)
            _repl_workflow_begin_turn
            return $?
            ;;
        workflow.sessionlog.appendActions)
            _repl_workflow_append_actions "$params_yaml"
            return $?
            ;;
        workflow.sessionlog.completeTurn)
            _repl_workflow_complete_turn "$params_yaml"
            return $?
            ;;
        workflow.sessionlog.openSession)
            _repl_workflow_open_session
            return $?
            ;;
        workflow.requirements.*)
            _repl_workflow_requirements "$method" "$params_yaml"
            return $?
            ;;
    esac

    _repl_invoke_raw "$method" "$params_yaml"
}

# Build envelope without sending (kept for testing/cache).
repl_build_envelope() {
    local method="$1"
    local params_yaml="${2:-}"
    local request_id="req-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $RANDOM)"

    local envelope="type: request
payload:
  requestId: ${request_id}
  method: ${method}"

    if [ -n "$params_yaml" ]; then
        local indented_params
        indented_params=$(echo "$params_yaml" | sed 's/^/    /')
        envelope="${envelope}
  params:
${indented_params}"
    fi

    echo "$envelope"
}

export -f repl_invoke repl_build_envelope _repl_first_param_text _repl_invoke_raw _repl_invoke_raw_in_workspace _repl_list_block_get _repl_marker_field _repl_param_text _repl_path_for_bash _repl_persist_turn _repl_requirement_list_field _repl_requirements_generate_http_fallback _repl_requirements_normalize_generate_response _repl_requirements_sync_state _repl_requirements_typed_doc_type _repl_requirements_typed_method _repl_requirements_typed_params _repl_requirements_workflow_doc_type _repl_requirements_workflow_params _repl_response_has_empty_result _repl_response_is_error _repl_response_is_nonempty_success _repl_session_meta _repl_session_state_value _repl_state_value _repl_unquote _repl_yaml_block_get _repl_yaml_field _repl_yaml_get _repl_cache_dir _repl_workflow_begin_turn _repl_workflow_append_actions _repl_workflow_complete_turn _repl_workflow_open_session _repl_workflow_requirements _repl_write_requirements_state 2>/dev/null || true
