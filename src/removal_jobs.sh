#!/usr/bin/env bash

# Durable removal jobs. This file is sourced by manager.sh after the backend and
# runtime tools have been resolved. Job directories are intentionally retained:
# they are the user's audit trail for destructive actions.

removal_state_root() {
    printf '%s\n' "${FORESTR_REMOVAL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/forestr/removals}"
}

removal_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

removal_write_json() {
    local destination=$1 json=$2 temporary
    temporary="$destination.new.$$"
    (umask 077; printf '%s\n' "$json" >"$temporary")
    chmod 600 "$temporary" 2>/dev/null || true
    mv "$temporary" "$destination"
}

removal_update() {
    local job_dir=$1 status=$2 message=$3 extra=${4:-'{}'} current updated
    current=$(cat "$job_dir/record.json" 2>/dev/null || printf '{}')
    updated=$("$jq_bin" -cn --argjson current "$current" --arg status "$status" \
        --arg message "$message" --arg updated_at "$(removal_now)" --argjson extra "$extra" \
        '$current + $extra + {status:$status,message:$message,updated_at:$updated_at}')
    removal_write_json "$job_dir/record.json" "$updated"
}

removal_key() {
    printf '%s\0%s' "$1" "$2" | "$git_bin" hash-object --stdin
}

removal_process_alive() {
    local pid=$1 expected=$2 job_dir=${3:-} actual command
    [[ $pid =~ ^[0-9]+$ && -n $expected ]] || return 1
    actual=$(process_start_token "$pid" 2>/dev/null || true)
    [[ -n $actual && $actual == "$expected" ]] || return 1
    [[ -z $job_dir ]] && return 0
    command=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
    [[ $command == *"manager.sh __removal-worker $job_dir"* ]]
}

removal_detach_runner() {
    if command -v setsid >/dev/null 2>&1; then
        printf 'setsid\n'
    elif [[ -x /usr/bin/perl ]] && /usr/bin/perl -MPOSIX -e 'exit(defined(&POSIX::setsid) ? 0 : 1)'; then
        printf 'perl\n'
    elif command -v perl >/dev/null 2>&1 && perl -MPOSIX -e 'exit(defined(&POSIX::setsid) ? 0 : 1)'; then
        printf 'perl-path\n'
    else
        return 1
    fi
}

# Prints the canonical primary checkout for a repository. Topology probes
# must run here rather than in a linked checkout that may itself be removed.
removal_primary_root() {
    local repo=$1 topology_file first primary
    topology_file=$(mktemp "${TMPDIR:-/tmp}/forestr-removal-primary.XXXXXX") || return 1
    if ! "$git_bin" -C "$repo" worktree list --porcelain -z >"$topology_file" 2>/dev/null; then
        rm -f "$topology_file"; return 1
    fi
    IFS= read -r -d '' first <"$topology_file" || true
    rm -f "$topology_file"
    primary=${first#worktree }
    [[ -n $primary && $first == 'worktree '* ]] || return 1
    canonical_directory "$primary"
}

# Prints registered, absent, or unknown. Git's NUL porcelain keeps path
# identity exact even when it contains whitespace or quoting characters.
removal_registration_state() {
    local repo=$1 wanted=$2 file field path canonical
    file=$(mktemp "${TMPDIR:-/tmp}/forestr-removal-topology.XXXXXX") || { printf 'unknown\n'; return; }
    if ! "$git_bin" -C "$repo" worktree list --porcelain -z >"$file" 2>/dev/null; then
        rm -f "$file"; printf 'unknown\n'; return
    fi
    while IFS= read -r -d '' field; do
        case $field in
            'worktree '*)
                path=${field#worktree }
                canonical=$(canonical_directory "$path" || printf '%s\n' "$path")
                if [[ $path == "$wanted" || $canonical == "$wanted" ]]; then
                    rm -f "$file"; printf 'registered\n'; return
                fi
                ;;
        esac
    done <"$file"
    rm -f "$file"
    # Missing Git registration is not enough: a safety failure can leave the
    # checkout directory in place. Only a missing registration and missing
    # original path authoritatively confirm removal.
    if [[ -e $wanted || -L $wanted ]]; then printf 'present\n'; else printf 'absent\n'; fi
}

removal_popup_message() {
    local popup_state=$1 message=$2 severity=${3:-warning} destination temporary other
    [[ -n $popup_state && -d $popup_state ]] || return 0
    if [[ $severity == error ]]; then destination=error; other=action-warning; else destination=action-warning; other=error; fi
    temporary="$popup_state/$destination.new.$$"
    printf '%s\n' "$message" >"$temporary" 2>/dev/null || return 0
    if [[ -d $popup_state ]]; then
        mv "$temporary" "$popup_state/$destination" 2>/dev/null || true
        rm -f "$popup_state/$other" 2>/dev/null || true
    else
        rm -f "$temporary"
    fi
}

removal_notify_popup() {
    local popup_state=$1 refresh=${2:-false} socket manager_q state_q action
    [[ -n $popup_state && -d $popup_state ]] || return 0
    socket="$popup_state/fzf.sock"; [[ -S $socket ]] || return 0
    manager_q=$(printf '%q' "$plugin_root/manager.sh"); state_q=$(printf '%q' "$popup_state")
    action="transform-footer($bash_q $manager_q __footer $state_q)"
    [[ $refresh != true ]] || action+="+reload($bash_q $manager_q __rows $state_q)"
    "$curl_bin" --silent --show-error --unix-socket "$socket" -X POST http://localhost/ -d "$action" >/dev/null 2>&1 || true
}

removal_final_notification() {
    local status=$1 target=$2 message=$3 title
    if [[ $status == succeeded || $status == warning ]]; then
        title="Forestr removed $target"
    else
        title="Forestr could not remove $target"
    fi
    "$herdr" notification show "$title" --body "$message" --sound none >/dev/null 2>&1 || true
}

# A live popup shows the result in its footer until the next action clears it,
# exactly like any other operation message. Without a popup to show it, the
# result is delivered as a Herdr notification instead.
removal_deliver_result() {
    local popup_state=$1 status=$2 target=$3 message=$4
    if [[ -n $popup_state && -d $popup_state && -S $popup_state/fzf.sock ]]; then
        if [[ $status == failed ]]; then
            removal_popup_message "$popup_state" "$message" error
        else
            removal_popup_message "$popup_state" "$message"
        fi
        start_refresh "$popup_state" true true 2>/dev/null || true
        removal_notify_popup "$popup_state" true
        return 0
    fi
    removal_final_notification "$status" "$target" "$message"
}

removal_focus_parent() {
    local job_dir=$1 record source repo_root repo_name root_workspace_id source_json create_json
    record=$(cat "$job_dir/record.json")
    source=$("$jq_bin" -r '.source' <<<"$record")
    [[ $source == true ]] || return 0
    repo_root=$("$jq_bin" -r '.primary_repo_root // .repo_root' <<<"$record")
    repo_name=$("$jq_bin" -r '.repo_name' <<<"$record")
    if ! source_json=$("$herdr" worktree list --cwd "$repo_root"); then
        printf 'Herdr could not resolve the root workspace before removal; the worktree was retained.\n' >&2
        return 1
    fi
    repo_root=$("$jq_bin" -r '.result.source.repo_root // empty' <<<"$source_json"); repo_root=${repo_root:-$("$jq_bin" -r '.primary_repo_root // .repo_root' <<<"$record")}
    repo_name=$("$jq_bin" -r '.result.source.repo_name // empty' <<<"$source_json"); repo_name=${repo_name:-$("$jq_bin" -r '.repo_name' <<<"$record")}
    root_workspace_id=$("$jq_bin" -r '.result.source.source_workspace_id // empty' <<<"$source_json")
    if [[ -z $root_workspace_id ]]; then
        if ! create_json=$("$herdr" workspace create --cwd "$repo_root" --label "${repo_name%.git}" --no-focus); then
            printf 'Herdr could not create the root workspace before removal; the worktree was retained.\n' >&2
            return 1
        fi
        root_workspace_id=$("$jq_bin" -r '.result.workspace.workspace_id // .result.workspace.id // empty' <<<"$create_json")
    fi
    if [[ -z $root_workspace_id ]] || ! "$herdr" workspace focus "$root_workspace_id" >/dev/null; then
        printf 'Herdr could not focus the root workspace before removal; the worktree was retained.\n' >&2
        return 1
    fi
    removal_update "$job_dir" running 'Parent workspace focused; safety checks, hooks, and file deletion are running.' \
        "$("$jq_bin" -cn --arg root "$repo_root" --arg id "$root_workspace_id" '{parent_repo_root:$root,parent_workspace_id:$id}')"
}

removal_workspace_record_for_path() {
    local wanted=$1 workspace_json record candidate_path candidate_id candidate_canonical
    workspace_json=$("$herdr" workspace list 2>/dev/null) || return 2
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        candidate_path=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .path')
        candidate_id=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .id')
        candidate_canonical=$(canonical_directory "$candidate_path" || printf '%s\n' "$candidate_path")
        if [[ -n $candidate_canonical && $candidate_canonical == "$wanted" ]]; then
            "$jq_bin" -cn --arg id "$candidate_id" --arg path "$candidate_path" '{id:$id,path:$path}'
            return 0
        fi
    done < <("$jq_bin" -r '.result.workspaces[]? | select(.worktree.checkout_path != null)
        | {path:.worktree.checkout_path,id:.workspace_id} | tojson | @base64' <<<"$workspace_json")
    return 1
}

removal_workspace_id_for_path() {
    local wanted=$1 selected_path=${2:-$wanted} workspace_json record candidate_path candidate_id candidate_canonical
    workspace_json=$("$herdr" workspace list 2>/dev/null) || return 2
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        candidate_path=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .path')
        candidate_id=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .id')
        candidate_canonical=$(canonical_directory "$candidate_path" || printf '%s\n' "$candidate_path")
        if [[ $candidate_path == "$selected_path" || $candidate_path == "$wanted" \
            || ( -n $candidate_canonical && $candidate_canonical == "$wanted" ) ]]; then
            printf '%s\n' "$candidate_id"
            return 0
        fi
    done < <("$jq_bin" -r '.result.workspaces[]? | select(.worktree.checkout_path != null)
        | {path:.worktree.checkout_path,id:.workspace_id} | tojson | @base64' <<<"$workspace_json")
    return 1
}

removal_close_workspace_for_path() {
    local repo_root=$1 path=$2 expected_id=${3:-} selected_path=${4:-$path} current_id topology workspace_status=0
    topology=$(removal_registration_state "$repo_root" "$path")
    [[ $topology == absent ]] || return 1
    current_id=$(removal_workspace_id_for_path "$path" "$selected_path") || workspace_status=$?
    [[ $workspace_status -ne 2 ]] || return 1
    [[ $workspace_status -eq 0 ]] || return 0
    [[ -z $expected_id || $current_id == "$expected_id" ]] || return 1
    # Re-probe immediately before closure so a concurrently recreated
    # worktree can never lose its workspace.
    topology=$(removal_registration_state "$repo_root" "$path")
    [[ $topology == absent ]] || return 1
    "$herdr" workspace close "$current_id" >/dev/null
}

removal_close_recorded_workspace() {
    local record repo_root path selected_path workspace_id
    record=$(cat "$1/record.json")
    repo_root=$("$jq_bin" -r '.primary_repo_root // .repo_root' <<<"$record")
    path=$("$jq_bin" -r '.path' <<<"$record")
    selected_path=$("$jq_bin" -r '.workspace_path // .selected_path // .path' <<<"$record")
    workspace_id=$("$jq_bin" -r '.workspace_id // empty' <<<"$record")
    removal_close_workspace_for_path "$repo_root" "$path" "$workspace_id" "$selected_path"
}

removal_release_lock() {
    local job_dir=$1 record lock
    record=$(cat "$job_dir/record.json" 2>/dev/null || printf '{}')
    lock=$("$jq_bin" -r '.lock_dir // empty' <<<"$record")
    [[ -z $lock ]] || rmdir "$lock" 2>/dev/null || true
}

queue_removal_job() {
    local popup_state=$1 payload=$2 force=${3:-false} selection repo_root repo_key repo_name kind target path canonical
    local workspace_id workspace_path workspace_record workspace_status=0 source=false primary topology key root locks lock_dir jobs id job_dir request record pid token detach_runner perl_bin created_epoch
    selection=$(decode_row "$payload") || { printf 'Invalid worktree selection.\n' >"$popup_state/error"; return 1; }
    repo_root=$("$jq_bin" -r '.repo_root // empty' <<<"$selection")
    repo_name=$("$jq_bin" -r '.repo_name // empty' <<<"$selection")
    repo_key=$("$jq_bin" -r '.repo_key // .repo_root // empty' <<<"$selection")
    repo_key=$(canonical_directory "$repo_key" || printf '%s\n' "$repo_key")
    kind=$("$jq_bin" -r '.kind // empty' <<<"$selection")
    target=$("$jq_bin" -r '.target // empty' <<<"$selection")
    path=$("$jq_bin" -r '.path // empty' <<<"$selection")
    if [[ $kind != worktree || -z $repo_root || -z $path ]]; then
        printf 'Select a linked worktree before removing.\n' >"$popup_state/error"; return 1
    fi
    canonical=$(canonical_directory "$path" || printf '%s\n' "$path")
    workspace_record=$(removal_workspace_record_for_path "$canonical" 2>/dev/null) || workspace_status=$?
    if [[ $workspace_status -eq 2 ]]; then
        printf 'Herdr could not snapshot workspace identity; no removal was queued.\n' >"$popup_state/error"
        return 1
    fi
    [[ -n $workspace_record ]] || workspace_record='{}'
    workspace_id=$("$jq_bin" -r '.id // empty' <<<"$workspace_record")
    workspace_path=$("$jq_bin" -r '.path // empty' <<<"$workspace_record")
    if [[ -n $workspace_id && $workspace_id == "$manager_source_workspace_id" ]] || \
       [[ -n $manager_source_canonical && $canonical == "$manager_source_canonical" ]]; then source=true; fi
    primary=$(removal_primary_root "$repo_root" || true)
    if [[ -z $primary ]]; then
        printf 'Git could not identify a stable primary worktree; no removal was queued.\n' >"$popup_state/error"; return 1
    fi
    topology=$(removal_registration_state "$primary" "$canonical")
    if [[ $topology != registered ]]; then
        printf 'The selected checkout is no longer a registered worktree; no removal was queued.\n' >"$popup_state/error"
        return 1
    fi
    if ! detach_runner=$(removal_detach_runner); then
        printf 'Forestr could not start a popup-independent removal worker (setsid or Perl POSIX is required).\n' >"$popup_state/error"
        return 1
    fi
    root=$(removal_state_root); jobs="$root/jobs"; locks="$root/active"
    (umask 077; mkdir -p "$jobs" "$locks") || { printf 'Forestr could not create its removal state directory.\n' >"$popup_state/error"; return 1; }
    chmod 700 "$root" "$jobs" "$locks" 2>/dev/null || true
    key=$(removal_key "$repo_key" "$canonical"); lock_dir="$locks/$key"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        printf 'A removal job is already active for this worktree.\n' >"$popup_state/error"; return 1
    fi
    id="$(date -u '+%Y%m%dT%H%M%S')-$$-${RANDOM:-0}"; job_dir="$jobs/$id"
    created_epoch=$(date '+%s')
    if ! mkdir "$job_dir"; then rmdir "$lock_dir"; return 1; fi
    chmod 700 "$lock_dir" "$job_dir" 2>/dev/null || true
    request=$("$jq_bin" -cn --arg repo_root "$repo_root" --arg target "$target" --arg path "$path" --argjson force "$force" \
        '{version:1,operation:"remove",repo_root:$repo_root,target:$target,path:$path,force:$force}')
    (umask 077; printf '%s\n' "$request" >"$job_dir/request.json"; : >"$job_dir/backend.log"; : >"$job_dir/action.log")
    chmod 600 "$job_dir/request.json" "$job_dir/backend.log" "$job_dir/action.log" 2>/dev/null || true
    record=$("$jq_bin" -cn --arg id "$id" --arg created_at "$(removal_now)" --argjson created_epoch "$created_epoch" --arg repo_root "$repo_root" \
        --arg repo_key "$repo_key" --arg repo_name "$repo_name" --arg path "$canonical" --arg selected_path "$path" --arg target "$target" --arg primary "$primary" \
        --arg workspace_id "$workspace_id" --arg workspace_path "$workspace_path" --arg lock_dir "$lock_dir" --argjson source "$source" --argjson force "$force" \
        '{version:1,id:$id,status:"queued",message:"Removal queued; safety checks, hooks, and file deletion are running. Closing this popup will not cancel it.",created_at:$created_at,created_epoch:$created_epoch,updated_at:$created_at,repo_root:$repo_root,repo_key:$repo_key,repo_name:$repo_name,path:$path,selected_path:$selected_path,target:$target,primary_repo_root:$primary,workspace_id:$workspace_id,workspace_path:$workspace_path,lock_dir:$lock_dir,source:$source,force:$force}')
    removal_write_json "$job_dir/record.json" "$record"
    removal_popup_message "$popup_state" 'Removal queued. Safety checks, hooks, and file deletion are running; closing this popup will not cancel it.'
    (
        cd "$primary" || exit 1
        case $detach_runner in
            setsid)
                nohup setsid "$bash_bin" -c \
                    'job=$1; shift; for ((i=0; i<500; i++)); do [[ -e $job/launched ]] && break; sleep 0.01; done; exec "$@"' \
                    _ "$job_dir" "$bash_bin" "$plugin_root/manager.sh" __removal-worker "$job_dir" "$popup_state" \
                    </dev/null >>"$job_dir/action.log" 2>&1 &
                ;;
            perl)
                nohup /usr/bin/perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- \
                    "$bash_bin" -c 'job=$1; shift; for ((i=0; i<500; i++)); do [[ -e $job/launched ]] && break; sleep 0.01; done; exec "$@"' \
                    _ "$job_dir" "$bash_bin" "$plugin_root/manager.sh" __removal-worker "$job_dir" "$popup_state" \
                    </dev/null >>"$job_dir/action.log" 2>&1 &
                ;;
            *)
                perl_bin=$(command -v perl)
                nohup "$perl_bin" -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- \
                    "$bash_bin" -c 'job=$1; shift; for ((i=0; i<500; i++)); do [[ -e $job/launched ]] && break; sleep 0.01; done; exec "$@"' \
                    _ "$job_dir" "$bash_bin" "$plugin_root/manager.sh" __removal-worker "$job_dir" "$popup_state" \
                    </dev/null >>"$job_dir/action.log" 2>&1 &
                ;;
        esac
        printf '%s\n' "$!" >"$job_dir/launch.pid"
    )
    read -r pid <"$job_dir/launch.pid" || pid=
    token=$(process_start_token "$pid" 2>/dev/null || true)
    # The worker can outrun this parent after the bounded launch handshake.
    # Publish launcher identity only while the record is still queued; never
    # regress running or terminal state back to queued.
    record=$(cat "$job_dir/record.json")
    record=$("$jq_bin" -cn --argjson current "$record" --argjson pid "${pid:-0}" --arg token "$token" \
        --arg updated_at "$(removal_now)" \
        '$current | if .status == "queued" then . + {pid:$pid,start_token:$token,updated_at:$updated_at} else . end')
    removal_write_json "$job_dir/record.json" "$record"
    : >"$job_dir/launched"
    printf '%s\n' "$id"
}

run_removal_job() {
    local job_dir=$1 popup_state=${2:-} record target status=0 output message final pid token warning backend_result
    [[ -f $job_dir/record.json && -f $job_dir/request.json ]] || return 2
    record=$(cat "$job_dir/record.json"); target=$("$jq_bin" -r '.target' <<<"$record")
    pid=$$; token=$(process_start_token "$$" 2>/dev/null || true)
    removal_update "$job_dir" running 'Safety checks, hooks, and file deletion are running. Closing the popup will not cancel this removal.' \
        "$("$jq_bin" -cn --argjson pid "$pid" --arg token "$token" '{pid:$pid,start_token:$token}')"
    removal_popup_message "$popup_state" 'Safety checks, hooks, and file deletion are running; closing this popup will not cancel the removal.'
    removal_notify_popup "$popup_state"
    record=$(cat "$job_dir/record.json")
    # The durable record, not the continued existence of popup state, is the
    # authority for source-workspace lifecycle in the detached process.
    if [[ $("$jq_bin" -r '.source' <<<"$record") == true ]]; then
        manager_source_workspace_id=$("$jq_bin" -r '.workspace_id // empty' <<<"$record")
        manager_source_checkout_path=$("$jq_bin" -r '.path' <<<"$record")
        manager_source_canonical=$manager_source_checkout_path
    fi
    export FORESTR_REMOVAL_BACKEND_LOG="$job_dir/backend.log"
    FORESTR_REMOVAL_PROBE_ROOT=$("$jq_bin" -r '.primary_repo_root // .repo_root' <<<"$record")
    FORESTR_REMOVAL_WORKSPACE_PATH=$("$jq_bin" -r '.workspace_path // .selected_path // .path' <<<"$record")
    export FORESTR_REMOVAL_PROBE_ROOT FORESTR_REMOVAL_WORKSPACE_PATH
    set +e
    output=$(remove_target \
        "$("$jq_bin" -r '.repo_root' <<<"$record")" "$("$jq_bin" -r '.repo_name' <<<"$record")" worktree \
        "$("$jq_bin" -r '.target' <<<"$record")" "$("$jq_bin" -r '.selected_path // .path' <<<"$record")" \
        "$("$jq_bin" -r '.force' <<<"$record")" 2>&1)
    status=$?
    set -e
    [[ -z $output ]] || printf '%s\n' "$output" >>"$job_dir/action.log"
    record=$(cat "$job_dir/record.json")
    if [[ $status -eq 0 || $status -eq 10 ]]; then
        backend_result=$(sed -n 's/^result: //p' "$job_dir/backend.log" | tail -n 1)
        if [[ -n $backend_result ]] && "$jq_bin" -e '.ok == true' >/dev/null 2>&1 <<<"$backend_result"; then
            warning=$("$jq_bin" -r '.warning // empty' <<<"$backend_result")
        else
            # A failed/interrupted backend can still be authoritatively
            # reconciled as removed. Keep that warning, but ignore routine
            # backend progress on ordinary successful removals.
            warning=$(sed $'s/\033\\[[0-9;]*m//g' "$job_dir/action.log" | tail -n 1)
        fi
        if [[ -n $warning ]]; then final=warning; message=$warning; else final=succeeded; message="Removed $target."; fi
    else
        message=$(sed $'s/\033\\[[0-9;]*m//g' "$job_dir/action.log" | tail -n 1)
        message=${message:-"Removal of $target failed; the worktree was retained."}; final=failed
    fi
    removal_update "$job_dir" "$final" "$message" "$("$jq_bin" -cn --arg finished_at "$(removal_now)" '{finished_at:$finished_at}')"
    removal_release_lock "$job_dir"
    removal_deliver_result "$popup_state" "$final" "$target" "$message"
}

reconcile_removal_jobs() {
    local popup_state=${1:-} root job record status pid token topology source message target launch_pid launch_token created_epoch age
    root=$(removal_state_root); [[ -d $root/jobs ]] || return 0
    for job in "$root"/jobs/*; do
        [[ -f $job/record.json ]] || continue
        record=$("$jq_bin" -ce 'select(type == "object")' "$job/record.json" 2>/dev/null) || continue
        status=$("$jq_bin" -r '.status // empty' <<<"$record")
        [[ $status == queued || $status == running ]] || continue
        pid=$("$jq_bin" -r '.pid // 0' <<<"$record"); token=$("$jq_bin" -r '.start_token // empty' <<<"$record")
        removal_process_alive "$pid" "$token" "$job" && continue
        if [[ $pid == 0 && -s $job/launch.pid ]]; then
            read -r launch_pid <"$job/launch.pid" || launch_pid=
            launch_token=$(process_start_token "$launch_pid" 2>/dev/null || true)
            removal_process_alive "$launch_pid" "$launch_token" "$job" && continue
        fi
        # Another popup can observe the record during the tiny setup window.
        # Give the detached launcher time to publish/replace its PID; genuinely
        # abandoned setup records are reconciled after they age one minute.
        if [[ $pid == 0 && ! -e $job/launched ]]; then
            created_epoch=$("$jq_bin" -r '.created_epoch // 0' <<<"$record")
            if [[ $created_epoch =~ ^[0-9]+$ && $created_epoch -gt 0 ]]; then
                age=$(( $(date '+%s') - created_epoch ))
                (( age >= 60 )) || continue
            fi
        fi
        topology=$(removal_registration_state "$("$jq_bin" -r '.primary_repo_root // .repo_root' <<<"$record")" "$("$jq_bin" -r '.path' <<<"$record")")
        target=$("$jq_bin" -r '.target' <<<"$record")
        case $topology in
            registered|present)
                message="Interrupted removal of $target left the worktree registered or present, so its workspace was retained."
                status=failed
                ;;
            absent)
                source=$("$jq_bin" -r '.source' <<<"$record")
                if [[ $source == true ]] && ! removal_focus_parent "$job" >>"$job/action.log" 2>&1; then
                    message="Removal of $target completed, but Forestr could not focus its parent; the stale workspace was retained."
                    status=failed
                elif removal_close_recorded_workspace "$job" >>"$job/action.log" 2>&1; then
                    message="Removal of $target was interrupted after Git stopped registering it and its path disappeared; Forestr reconciled the matching workspace."
                    status=warning
                else
                    message="Removal of $target completed, but the matching workspace could not be safely revalidated and was retained."
                    status=failed
                fi
                ;;
            *) message="Interrupted removal of $target could not be reconciled with Git; the workspace was retained."; status=failed ;;
        esac
        removal_update "$job" "$status" "$message" "$("$jq_bin" -cn --arg finished_at "$(removal_now)" '{finished_at:$finished_at,reconciled:true}')"
        removal_release_lock "$job"
        removal_final_notification "$status" "$target" "$message"
        # Recovery at launch is a fresh event: show it once in the opening popup.
        if [[ -n $popup_state ]]; then
            if [[ $status == failed ]]; then removal_popup_message "$popup_state" "$message" error
            else removal_popup_message "$popup_state" "$message"
            fi
        fi
    done
}

latest_removal_record() {
    local root candidate record filter=${1:-.}
    root=$(removal_state_root); [[ -d $root/jobs ]] || return 0
    while IFS= read -r candidate; do
        [[ -f $candidate/record.json ]] || continue
        if record=$("$jq_bin" -ce "select(type == \"object\") | select($filter)" "$candidate/record.json" 2>/dev/null); then
            printf '%s\n' "$record"
            return 0
        fi
    done < <(find "$root/jobs" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort -r)
}

latest_removal_message() {
    local record message
    record=$(latest_removal_record); [[ -n $record ]] || return 0
    message=$("$jq_bin" -r '.message // empty' <<<"$record")
    [[ -z $message ]] || printf '%s\n' "$message"
}

# Only in-flight jobs are worth restating in an otherwise idle footer. Final
# results were already delivered once (footer or notification) and must not
# haunt every later render or launch.
restore_active_removal_status() {
    local popup_state=$1 record message
    record=$(latest_removal_record '.status == "queued" or .status == "running"'); [[ -n $record ]] || return 0
    message=$("$jq_bin" -r '.message // empty' <<<"$record")
    [[ -z $message ]] || removal_popup_message "$popup_state" "$message"
}
