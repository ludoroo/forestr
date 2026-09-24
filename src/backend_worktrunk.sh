#!/usr/bin/env bash

backend_worktrunk_failure() {
    local operation=$1 message=$2
    "$JQ_BIN" -cn --arg operation "$operation" --arg message "$message" \
        '{version:1,operation:$operation,ok:false,message:$message}'
}

backend_adapter_dispatch() {
    local request=$1 operation repo_root target mode force raw path branch removal_ref
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
            path=$($JQ_BIN -r '.path // empty' <<<"$request")
            removal_ref=${path:-$target}
            args=(remove --foreground --format=json)
            [[ $force == true ]] && args+=(--force --force-delete)
            args+=("$removal_ref")
            if ! raw=$("$FORESTR_WORKTRUNK_BIN" -C "$repo_root" "${args[@]}"); then
                backend_worktrunk_failure remove "Worktrunk did not remove $target."
                return 0
            fi
            # Worktrunk emits a JSON array even for one target. Foreground
            # removal must return the final branch outcome; accepting a
            # deferred/background result would make workspace reconciliation
            # race an operation whose result is still unknown.
            if ! "$JQ_BIN" -e '
                type == "array" and length == 1
                and .[0].kind == "worktree"
                and (.[0].path | type == "string" and length > 0)
                and (.[0].branch_outcome | IN("deleted","not_attempted","retained_unmerged",
                    "retained_checked_out","retained_raced","retained_failed"))
            ' >/dev/null 2>&1 <<<"$raw"; then
                backend_worktrunk_failure remove "Worktrunk returned an incomplete removal result for $target."
                return 0
            fi
            "$JQ_BIN" -c --arg target "$target" '
                .[0].branch_outcome as $outcome
                | {
                    version: 1,
                    operation: "remove",
                    ok: true,
                    removed_worktree: true,
                    branch_outcome: (if $outcome == "not_attempted" then "not_applicable" else $outcome end),
                    warning: (
                        if $outcome == "retained_unmerged" then
                            "Worktree removed, but unmerged branch " + $target + " was retained."
                        elif $outcome == "retained_checked_out" then
                            "Worktree removed, but branch " + $target + " is checked out elsewhere and was retained."
                        elif $outcome == "retained_raced" then
                            "Worktree removed, but branch " + $target + " changed during removal and was retained."
                        elif $outcome == "retained_failed" then
                            "Worktree removed, but Worktrunk could not delete branch " + $target + "."
                        else "" end
                    )
                }
            ' <<<"$raw"
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
              | {
                  path:.worktree.path,
                  branch:(.branch // ""),
                  head:(.head.short_sha // ""),
                  symbols:(.display.symbols // ""),
                  status:{
                    staged:(if .worktree.prunable != null then false
                            elif .worktree.changes == null then null else (.worktree.changes.staged // false) end),
                    modified:(if .worktree.prunable != null then false
                              elif .worktree.changes == null then null else (.worktree.changes.modified // false) end),
                    untracked:(if .worktree.prunable != null then false
                               elif .worktree.changes == null then null else (.worktree.changes.untracked // false) end),
                    worktree_state:(
                      if .worktree.prunable != null then "prunable"
                      elif (.worktree.changes == null or .worktree.changes.conflicted == null) then "unresolved"
                      elif .worktree.changes.conflicted then "conflicted"
                      elif ((.worktree | has("operation")) and .worktree.operation == null) then "unresolved"
                      elif ((.worktree.operation // "") != "") then "operation"
                      elif (.worktree.locked // false) then "locked"
                      elif (.worktree.detached // false) then "detached"
                      elif ((.worktree.duplicate_branch // false) or (.worktree.branch_mismatch // false)) then "warning"
                      else "" end),
                    branch_state:(
                      if .worktree.prunable != null then ""
                      elif .display.state != null then .display.state
                      elif (.worktree.main // false) then "is_main"
                      elif .default_branch == null then "unresolved"
                      elif (.default_branch.ahead == null or .default_branch.behind == null
                            or .default_branch.orphan == null or .default_branch.merge_conflicts == null
                            or ((.default_branch | has("integration")) and .default_branch.integration == null))
                        then "unresolved"
                      else "" end),
                    remote_state:(
                      if .worktree.prunable != null then ""
                      elif ((has("upstream")) and .upstream == null) then "unresolved"
                      elif ((.upstream.ahead // 0) > 0 and (.upstream.behind // 0) > 0) then "diverged"
                      elif ((.upstream.ahead // 0) > 0) then "ahead"
                      elif ((.upstream.behind // 0) > 0) then "behind"
                      elif .upstream != null then "synced"
                      else "" end),
                    marker:(if .worktree.prunable != null then ""
                            elif has("marker") then .marker else "" end)
                  }
                } ]}' <<<"$raw"
            ;;
    esac
}
