#!/usr/bin/env bash

backend_worktrunk_failure() {
    local operation=$1 message=$2
    "$JQ_BIN" -cn --arg operation "$operation" --arg message "$message" \
        '{version:1,operation:$operation,ok:false,message:$message}'
}

backend_adapter_dispatch() {
    local request=$1 operation repo_root target mode force raw path branch
    local collection_timeout_ms
    local -a args
    operation=$($JQ_BIN -r '.operation' <<<"$request")
    repo_root=$($JQ_BIN -r '.repo_root' <<<"$request")
    case $operation in
        open)
            target=$($JQ_BIN -r '.target' <<<"$request")
            mode=$($JQ_BIN -r '.mode' <<<"$request")
            if [[ $mode == create || $mode == force-create ]] \
                && ! "${FORESTR_GIT_BIN:-git}" check-ref-format --branch "$target" >/dev/null 2>&1; then
                backend_worktrunk_failure open "Invalid branch name: $target."
                return 0
            fi
            case $mode in
                create) args=(switch --create "$target") ;;
                force-create) args=(switch --create --clobber "$target") ;;
                open) args=(switch "$target") ;;
            esac
            if ! raw=$("$FORESTR_WORKTRUNK_BIN" -C "$repo_root" "${args[@]}" --no-cd --format=json); then
                backend_worktrunk_failure open "Worktrunk could not open $target."
                return 0
            fi
            if ! path=$($JQ_BIN -er '.path | select(type == "string" and length > 0)' <<<"$raw" 2>/dev/null); then
                backend_worktrunk_failure open "Worktrunk returned no checkout path for $target."
                return 0
            fi
            branch=$($JQ_BIN -r '.branch // "" | strings' <<<"$raw" 2>/dev/null || true)
            "$JQ_BIN" -cn --arg path "$path" --arg branch "$branch" \
                '{version:1,operation:"open",ok:true,path:$path,branch:$branch}'
            ;;
        remove)
            target=$($JQ_BIN -r '.target' <<<"$request")
            force=$($JQ_BIN -r '.force' <<<"$request")
            args=(remove --foreground --format=json)
            [[ $force == true ]] && args+=(--force --force-delete)
            args+=("$target")
            if ! "$FORESTR_WORKTRUNK_BIN" -C "$repo_root" "${args[@]}" >/dev/null; then
                backend_worktrunk_failure remove "Worktrunk did not remove $target."
                return 0
            fi
            printf '{"version":1,"operation":"remove","ok":true,"removed_worktree":true,"branch_outcome":"not_applicable","warning":""}\n'
            ;;
        enrich)
            collection_timeout_ms=$($JQ_BIN -r '.collection_timeout_ms' <<<"$request")
            if ! raw=$("$FORESTR_WORKTRUNK_BIN" -C "$repo_root" list --format=json \
                --config-set 'list.json-schema=2' --config-set 'list.full=false' \
                --config-set "list.timeout-ms=$collection_timeout_ms" 2>/dev/null); then
                backend_worktrunk_failure enrich 'Worktrunk enrichment failed.'
                return 0
            fi
            if ! "$JQ_BIN" -e '.schema == 2 and (.items | type == "array")' >/dev/null 2>&1 <<<"$raw"; then
                backend_worktrunk_failure enrich 'Worktrunk enrichment returned invalid schema-2 JSON.'
                return 0
            fi
            "$JQ_BIN" -c '{version:1,operation:"enrich",ok:true,items:[.items[]?
              | select(.worktree.path != null)
              | {path:.worktree.path,branch:(.branch // ""),head:(.head.short_sha // ""),symbols:(.display.symbols // "")} ]}' <<<"$raw"
            ;;
    esac
}
