#!/usr/bin/env bash

# Version 1 backend boundary. Requests and results are JSON objects; adapters
# never expose tool-specific output to the manager or renderer.
FORESTR_BACKEND=${FORESTR_BACKEND:-}
FORESTR_BACKEND_CAPABILITIES=${FORESTR_BACKEND_CAPABILITIES:-}
FORESTR_WORKTRUNK_BIN=${FORESTR_WORKTRUNK_BIN:-}
FORESTR_BACKEND_ENRICH=${FORESTR_BACKEND_ENRICH:-false}
FORESTR_BACKEND_ENRICHMENT_TIMEOUT_MS=${FORESTR_BACKEND_ENRICHMENT_TIMEOUT_MS:-10000}
FORESTR_BACKEND_ENRICHMENT_COLLECTION_TIMEOUT_MS=${FORESTR_BACKEND_ENRICHMENT_COLLECTION_TIMEOUT_MS:-5000}
FORESTR_BACKEND_ENRICHMENT_CONCURRENCY=${FORESTR_BACKEND_ENRICHMENT_CONCURRENCY:-2}
FORESTR_BACKEND_CONFIG_WARNING=${FORESTR_BACKEND_CONFIG_WARNING:-}
FORESTR_BACKEND_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

backend_configured_name() {
    local configured
    configured=$(forestr_config_value backend)
    configured=${configured:-auto}
    case $configured in
        auto|worktrunk|git) printf '%s\n' "$configured" ;;
        *) printf 'Invalid backend: %s (expected auto, worktrunk, or git).\n' "$configured" >&2; return 2 ;;
    esac
}

backend_resolve() {
    local wt_override=${1:-${WORKTRUNK_BIN:-}} configured wt_candidate
    configured=$(backend_configured_name) || return
    if [[ $configured == git ]]; then
        FORESTR_BACKEND=git
        FORESTR_WORKTRUNK_BIN=
        # shellcheck source=./backend_git.sh
        source "$FORESTR_BACKEND_ROOT/backend_git.sh"
        backend_git_resolve
        return
    fi
    if [[ -n $wt_override && ! -x $wt_override ]]; then
        if [[ $configured == worktrunk ]]; then
            printf 'Forestr backend "worktrunk" requires wt; WORKTRUNK_BIN is not executable: %s\n' "$wt_override" >&2
            return 127
        fi
        wt_override=
    fi
    case $configured in
        auto|worktrunk)
            if wt_candidate=$(forestr_find_executable wt "$wt_override"); then
                FORESTR_BACKEND=worktrunk
                FORESTR_WORKTRUNK_BIN=$wt_candidate
                FORESTR_BACKEND_ENRICH=$(forestr_config_bool enrich_backend true)
                FORESTR_BACKEND_ENRICHMENT_TIMEOUT_MS=$(forestr_config_positive_integer worktrunk_enrichment_timeout_ms 10000)
                FORESTR_BACKEND_ENRICHMENT_COLLECTION_TIMEOUT_MS=$(forestr_config_positive_integer worktrunk_enrichment_collection_timeout_ms 5000)
                FORESTR_BACKEND_ENRICHMENT_CONCURRENCY=$(forestr_config_concurrency worktrunk_enrichment_concurrency 2)
                FORESTR_BACKEND_CONFIG_WARNING=
                if (( FORESTR_BACKEND_ENRICHMENT_TIMEOUT_MS < FORESTR_BACKEND_ENRICHMENT_COLLECTION_TIMEOUT_MS )); then
                    FORESTR_BACKEND_CONFIG_WARNING='⚠ worktrunk_enrichment_timeout_ms must be >= worktrunk_enrichment_collection_timeout_ms; using safe defaults (10000/5000 ms).'
                    FORESTR_BACKEND_ENRICHMENT_TIMEOUT_MS=10000
                    FORESTR_BACKEND_ENRICHMENT_COLLECTION_TIMEOUT_MS=5000
                fi
                # GNU timeout is needed only when Worktrunk enrichment is on.
                FORESTR_BACKEND_CAPABILITIES=$($JQ_BIN -cn \
                    --argjson timeout "$FORESTR_BACKEND_ENRICH" \
                    '{version:1,backend:"worktrunk",operations:{open:true,create:true,remove:true,enrich:true},
                      features:{create_clobber:true,remove_stale:true,relocate:true},
                      dependencies:{wt:true,gnu_timeout:$timeout}}')
                # shellcheck source=./backend_worktrunk.sh
                source "$FORESTR_BACKEND_ROOT/backend_worktrunk.sh"
                return 0
            fi
            if [[ $configured == worktrunk ]]; then
                printf 'Forestr backend "worktrunk" requires wt; install it or set WORKTRUNK_BIN.\n' >&2
            else
                FORESTR_BACKEND=git
                FORESTR_WORKTRUNK_BIN=
                # shellcheck source=./backend_git.sh
                source "$FORESTR_BACKEND_ROOT/backend_git.sh"
                backend_git_resolve
                return
            fi
            return 127
            ;;
    esac
}

backend_capabilities() {
    [[ -n $FORESTR_BACKEND_CAPABILITIES ]] || {
        printf 'Forestr backend has not been resolved.\n' >&2
        return 2
    }
    printf '%s\n' "$FORESTR_BACKEND_CAPABILITIES"
}

backend_validate_request() {
    "$JQ_BIN" -e '
      .version == 1 and (.operation | IN("open","remove","enrich"))
      and (.repo_root | type == "string" and length > 0)
      and (if .operation == "open" then
             (.target | type == "string" and length > 0) and (.mode | IN("open","create","force-create"))
             and ((.intent // "local_branch") | IN("existing_worktree","local_branch","remote_branch","create_branch"))
             and ((.path // "") | type == "string") and ((.full_ref // "") | type == "string")
             and ((.remote // "") | type == "string") and ((.create_base // "") | type == "string")
           elif .operation == "remove" then
             (.target | type == "string" and length > 0) and (.force | type == "boolean")
             and ((.path // "") | type == "string")
           else
             (.timeout_bin | type == "string" and length > 0)
             and (.timeout_ms | type == "number" and . > 0 and floor == .)
             and (.collection_timeout_ms | type == "number" and . > 0 and floor == .)
           end)
    ' >/dev/null 2>&1 <<<"$1"
}

backend_validate_result() {
    local operation=$1 result=$2
    "$JQ_BIN" -e --arg operation "$operation" '
      .version == 1 and .operation == $operation and (.ok | type == "boolean")
      and (if .ok == false then (.message | type == "string" and length > 0)
           elif $operation == "open" then
             (.path | type == "string" and length > 0) and (.branch | type == "string")
           elif $operation == "remove" then
             (.removed_worktree == true) and (.branch_outcome | IN("deleted","not_applicable",
               "retained_unmerged","retained_checked_out","retained_failed"))
             and (.warning | type == "string")
           elif $operation == "enrich" then
             (.items | type == "array") and all(.items[];
               (.path | type == "string" and length > 0)
               and (.branch | type == "string") and (.head | type == "string")
               and (.symbols | type == "string"))
           else false end)
    ' >/dev/null 2>&1 <<<"$result"
}

backend_dispatch() {
    local request=$1 operation result status=0
    if ! backend_validate_request "$request"; then
        printf 'Forestr rejected an invalid backend request.\n' >&2
        return 2
    fi
    operation=$($JQ_BIN -r '.operation' <<<"$request")
    result=$(backend_adapter_dispatch "$request") || status=$?
    if (( status != 0 )); then
        return "$status"
    fi
    if ! backend_validate_result "$operation" "$result"; then
        printf 'Forestr backend "%s" returned an invalid %s result.\n' "${FORESTR_BACKEND:-unknown}" "$operation" >&2
        return 2
    fi
    printf '%s\n' "$result"
}
