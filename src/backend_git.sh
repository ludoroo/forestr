#!/usr/bin/env bash

# Native Git adapter. It deliberately uses only porcelain commands that apply
# to one selected ref/path; it never deletes directories, rewrites refs, or
# prunes unrelated worktrees.
backend_git_resolve() {
    FORESTR_WORKTRUNK_BIN=
    FORESTR_BACKEND_ENRICH=false
    FORESTR_BACKEND_CAPABILITIES=$($JQ_BIN -cn '
        {version:1,backend:"git",
         operations:{open:true,create:true,remove:true,enrich:false},
         features:{create_clobber:false,remove_stale:true,relocate:false},
         dependencies:{wt:false}}')
}

backend_git_failure() {
    local operation=$1 message=$2
    "$JQ_BIN" -cn --arg operation "$operation" --arg message "$message" \
        '{version:1,operation:$operation,ok:false,message:$message}'
}

backend_sanitize_branch() {
    # Worktrunk's `sanitize` filter preserves Git-valid branch bytes and maps
    # path separators to hyphens. Git itself rejects backslashes in branch
    # names, so slash is the only possible separator after validation.
    printf '%s\n' "${1//\//-}"
}

backend_git_canonical_directory() {
    (cd -- "$1" 2>/dev/null && pwd -P)
}

backend_git_common_dir() {
    local path=$1 common base
    common=$("${FORESTR_GIT_BIN:-git}" -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    case $common in
        /*) ;;
        *) base=$(backend_git_canonical_directory "$path") || return 1; common=$base/$common ;;
    esac
    backend_git_canonical_directory "$common"
}

# Globals populated by backend_git_find_worktree.
BG_WORKTREE_PATH= BG_WORKTREE_CANONICAL= BG_WORKTREE_BRANCH= BG_WORKTREE_DETACHED=false
BG_WORKTREE_PRIMARY=false BG_WORKTREE_PRUNABLE= BG_WORKTREE_LOCKED=
backend_git_find_worktree() {
    local repo=$1 wanted_path=${2:-} wanted_ref=${3:-} file field
    local path= branch= detached=false prunable= locked= primary=true candidate wanted
    local found=false
    file=$(mktemp "${TMPDIR:-/tmp}/forestr-git-worktrees.XXXXXX") || return 1
    if ! "${FORESTR_GIT_BIN:-git}" -C "$repo" worktree list --porcelain -z >"$file"; then
        rm -f "$file"; return 1
    fi
    if [[ -n $wanted_path && -d $wanted_path ]]; then
        wanted=$(backend_git_canonical_directory "$wanted_path" || printf '%s\n' "$wanted_path")
    else
        wanted=$wanted_path
    fi
    emit_git_worktree() {
        [[ -n $path ]] || return 0
        if [[ -d $path ]]; then candidate=$(backend_git_canonical_directory "$path" || printf '%s\n' "$path"); else candidate=$path; fi
        if { [[ -n $wanted_path ]] && [[ $candidate == "$wanted" ]]; } \
            || { [[ -n $wanted_ref ]] && [[ $branch == "$wanted_ref" ]]; } \
            || { [[ -z $wanted_path && -z $wanted_ref && $primary == true ]]; }; then
            BG_WORKTREE_PATH=$path; BG_WORKTREE_CANONICAL=$candidate; BG_WORKTREE_BRANCH=$branch
            BG_WORKTREE_DETACHED=$detached; BG_WORKTREE_PRIMARY=$primary
            BG_WORKTREE_PRUNABLE=$prunable; BG_WORKTREE_LOCKED=$locked
            found=true
        fi
        primary=false; path=; branch=; detached=false; prunable=; locked=
    }
    while IFS= read -r -d '' field; do
        if [[ -z $field ]]; then emit_git_worktree; continue; fi
        case $field in
            'worktree '*) path=${field#worktree } ;;
            'branch '*) branch=${field#branch } ;;
            detached) detached=true ;;
            prunable*) prunable=${field#prunable} ;;
            locked*) locked=${field#locked} ;;
        esac
    done <"$file"
    emit_git_worktree
    rm -f "$file"
    $found
}

backend_git_primary_path() {
    backend_git_find_worktree "$1" || return 1
    [[ $BG_WORKTREE_PRIMARY == true && -n $BG_WORKTREE_PATH ]] || return 1
    printf '%s\n' "$BG_WORKTREE_PATH"
}

backend_git_branch_checkout() {
    local repo=$1 ref=$2
    if backend_git_find_worktree "$repo" '' "$ref"; then
        printf '%s\n' "$BG_WORKTREE_PATH"
        return 0
    fi
    return 1
}

backend_git_validate_repo() {
    local repo=$1 common
    common=$(backend_git_common_dir "$repo") || return 1
    [[ -n $common ]]
}

backend_git_path_for_branch() {
    local repo=$1 branch=$2 root parent name slug path name_max path_max bytes
    root=$(backend_git_primary_path "$repo") || {
        printf 'Git could not identify a primary worktree for path planning.\n' >&2
        return 1
    }
    root=$(backend_git_canonical_directory "$root") || return 1
    parent=${root%/*}; name=${root##*/}; slug=$(backend_sanitize_branch "$branch")
    path=$parent/.$name-$slug
    name_max=$(getconf NAME_MAX "$parent" 2>/dev/null || printf '255\n')
    path_max=$(getconf PATH_MAX "$parent" 2>/dev/null || printf '4096\n')
    bytes=$(LC_ALL=C printf '%s' ".$name-$slug" | wc -c); bytes=${bytes//[[:space:]]/}
    if (( bytes > name_max )); then
        printf 'Checkout basename for branch %s is %s bytes; filesystem limit is %s.\n' "$branch" "$bytes" "$name_max" >&2
        return 1
    fi
    bytes=$(LC_ALL=C printf '%s' "$path" | wc -c); bytes=${bytes//[[:space:]]/}
    if (( bytes >= path_max )); then
        printf 'Checkout path for branch %s is %s bytes; filesystem limit is %s.\n' "$branch" "$bytes" "$path_max" >&2
        return 1
    fi
    printf '%s\n' "$path"
}

backend_git_validate_planned_path() {
    local repo=$1 path=$2 branch=$3 existing_ref
    if [[ -e $path || -L $path ]]; then
        printf 'Checkout path collision for branch %s: %s already exists.\n' "$branch" "$path" >&2
        return 1
    fi
    if backend_git_find_worktree "$repo" "$path"; then
        existing_ref=${BG_WORKTREE_BRANCH:-detached HEAD}
        printf 'Checkout path collision for branch %s: %s is registered for %s.\n' \
            "$branch" "$path" "$existing_ref" >&2
        return 1
    fi
}

backend_git_ref_exists() {
    "${FORESTR_GIT_BIN:-git}" -C "$1" show-ref --verify --quiet "$2"
}

backend_git_add_error() {
    local branch=$1 error_file=$2 detail
    detail=$(sed -n '1{s/^fatal: //;p;}' "$error_file")
    printf 'Git could not materialize %s%s.\n' "$branch" "${detail:+: $detail}"
}

backend_git_resolve_commit() {
    local repo=$1 candidate=$2 resolved
    resolved=$("${FORESTR_GIT_BIN:-git}" -C "$repo" rev-parse --verify --quiet --end-of-options \
        "$candidate^{commit}" 2>/dev/null) || return 1
    [[ $resolved != *$'\n'* && -n $resolved ]] || return 1
    printf '%s\n' "$resolved"
}

backend_git_resolve_base() {
    local repo=$1 explicit=$2 target resolved
    if [[ -n $explicit ]]; then
        if resolved=$(backend_git_resolve_commit "$repo" "$explicit"); then printf '%s\n' "$resolved"; return; fi
        printf 'Could not resolve create base %s to exactly one commit.\n' "$explicit" >&2
        return 1
    fi
    if target=$("${FORESTR_GIT_BIN:-git}" -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) \
        && [[ -n $target ]] && resolved=$(backend_git_resolve_commit "$repo" "$target"); then
        printf '%s\n' "$resolved"; return
    fi
    if resolved=$(backend_git_resolve_commit "$repo" refs/heads/main); then printf '%s\n' "$resolved"; return; fi
    if resolved=$(backend_git_resolve_commit "$repo" refs/heads/master); then printf '%s\n' "$resolved"; return; fi
    if resolved=$(backend_git_resolve_commit "$repo" HEAD); then printf '%s\n' "$resolved"; return; fi
    printf 'Could not resolve a create base from origin/HEAD, main, master, or HEAD.\n' >&2
    return 1
}

backend_git_target_matches_worktree() {
    local target=$1 selected_path=$2 branch=$3 target_canonical
    [[ -n $branch && $target == "$branch" ]] && return 0
    [[ $target == "$selected_path" || $target == "$BG_WORKTREE_PATH" || $target == "$BG_WORKTREE_CANONICAL" ]] && return 0
    if [[ -d $target ]]; then
        target_canonical=$(backend_git_canonical_directory "$target" || true)
        [[ -n $target_canonical && $target_canonical == "$BG_WORKTREE_CANONICAL" ]] && return 0
    fi
    return 1
}

backend_git_verify_created_worktree() {
    local repo=$1 path=$2 ref=$3 repo_common selected_common
    repo_common=$(backend_git_common_dir "$repo" || true)
    selected_common=$(backend_git_common_dir "$path" || true)
    backend_git_find_worktree "$repo" "$path" \
        && [[ $BG_WORKTREE_BRANCH == "$ref" && -n $repo_common && $selected_common == "$repo_common" ]]
}

backend_git_open_existing() {
    local repo=$1 target=$2 selected_path=$3 repo_common selected_common branch
    [[ -n $selected_path ]] || { backend_git_failure open 'The selected worktree has no checkout path.'; return; }
    if ! backend_git_find_worktree "$repo" "$selected_path"; then
        backend_git_failure open "Selected checkout is no longer a registered worktree: $selected_path."
        return
    fi
    [[ -d $BG_WORKTREE_PATH ]] || {
        backend_git_failure open "Selected worktree path is missing or prunable: $BG_WORKTREE_PATH."
        return
    }
    repo_common=$(backend_git_common_dir "$repo" || true)
    selected_common=$(backend_git_common_dir "$BG_WORKTREE_PATH" || true)
    if [[ -z $repo_common || $selected_common != "$repo_common" ]]; then
        backend_git_failure open 'Selected checkout does not belong to the same Git repository.'
        return
    fi
    branch=${BG_WORKTREE_BRANCH#refs/heads/}
    if ! backend_git_target_matches_worktree "$target" "$selected_path" "$branch"; then
        backend_git_failure open "Selected worktree now has branch $branch at $BG_WORKTREE_CANONICAL, not $target."
        return
    fi
    "$JQ_BIN" -cn --arg path "$BG_WORKTREE_CANONICAL" --arg branch "$branch" \
        '{version:1,operation:"open",ok:true,path:$path,branch:$branch}'
}

backend_git_open_local() {
    local repo=$1 branch=$2 ref path checkout error_file
    ref=refs/heads/$branch
    if ! "${FORESTR_GIT_BIN:-git}" check-ref-format --branch "$branch" >/dev/null 2>&1; then
        backend_git_failure open "Invalid branch name: $branch."; return
    fi
    if ! backend_git_ref_exists "$repo" "$ref"; then
        backend_git_failure open "Local branch does not exist: $branch."; return
    fi
    if checkout=$(backend_git_branch_checkout "$repo" "$ref"); then
        backend_git_failure open "Local branch $branch is already checked out at $checkout; select that worktree instead."
        return
    fi
    if ! path=$(backend_git_path_for_branch "$repo" "$branch" 2>&1); then backend_git_failure open "$path"; return; fi
    if ! checkout=$(backend_git_validate_planned_path "$repo" "$path" "$branch" 2>&1); then backend_git_failure open "$checkout"; return; fi
    error_file=$(mktemp "${TMPDIR:-/tmp}/forestr-git-add.XXXXXX")
    # A short branch name makes `worktree add` attach HEAD; --no-guess-remote
    # prevents Git from materializing a same-named remote when the exact local
    # refs/heads branch checked above loses a race. This is intentionally one
    # command so hooks never run in an intermediate detached checkout.
    if ! "${FORESTR_GIT_BIN:-git}" -C "$repo" worktree add --no-guess-remote "$path" "$branch" > /dev/null 2>"$error_file"; then
        checkout=$(backend_git_add_error "$branch" "$error_file"); rm -f "$error_file"
        backend_git_failure open "$checkout"; return
    fi
    rm -f "$error_file"
    if ! backend_git_verify_created_worktree "$repo" "$path" "$ref"; then
        backend_git_failure open "Checkout was created at $path but exact branch verification failed; checkout retained for inspection."
        return
    fi
    "$JQ_BIN" -cn --arg path "$path" --arg branch "$branch" \
        '{version:1,operation:"open",ok:true,path:$path,branch:$branch}'
}

backend_git_open_remote() {
    local repo=$1 target=$2 full_ref=$3 remote=$4 branch ref path detail error_file upstream
    [[ -n $remote && $target == "$remote/"* ]] || {
        backend_git_failure open "Remote selection has inconsistent identity: $target."; return; }
    branch=${target#"$remote/"}; ref=refs/heads/$branch
    [[ $full_ref == "refs/remotes/$remote/$branch" ]] || {
        backend_git_failure open "Remote selection has inconsistent full ref: $full_ref."; return; }
    if ! "${FORESTR_GIT_BIN:-git}" check-ref-format --branch "$branch" >/dev/null 2>&1; then
        backend_git_failure open "Invalid local branch name: $branch."; return
    fi
    if ! backend_git_ref_exists "$repo" "$full_ref"; then
        backend_git_failure open "Remote branch no longer exists: $full_ref."; return
    fi
    if "${FORESTR_GIT_BIN:-git}" -C "$repo" symbolic-ref -q "$full_ref" >/dev/null 2>&1; then
        backend_git_failure open "Symbolic remote refs cannot be materialized: $full_ref."; return
    fi
    if backend_git_ref_exists "$repo" "$ref"; then
        backend_git_failure open "Local branch $branch already exists; select the local branch instead."
        return
    fi
    if ! path=$(backend_git_path_for_branch "$repo" "$branch" 2>&1); then backend_git_failure open "$path"; return; fi
    if ! detail=$(backend_git_validate_planned_path "$repo" "$path" "$branch" 2>&1); then backend_git_failure open "$detail"; return; fi
    error_file=$(mktemp "${TMPDIR:-/tmp}/forestr-git-add.XXXXXX")
    if ! "${FORESTR_GIT_BIN:-git}" -C "$repo" worktree add --track -b "$branch" "$path" "$full_ref" > /dev/null 2>"$error_file"; then
        detail=$(backend_git_add_error "$branch" "$error_file"); rm -f "$error_file"
        backend_git_failure open "$detail"; return
    fi
    rm -f "$error_file"
    upstream=$("${FORESTR_GIT_BIN:-git}" -C "$path" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if ! backend_git_verify_created_worktree "$repo" "$path" "$ref" || [[ $upstream != "$full_ref" ]]; then
        backend_git_failure open "Checkout was created at $path but exact branch or upstream verification failed; checkout retained for inspection."
        return
    fi
    "$JQ_BIN" -cn --arg path "$path" --arg branch "$branch" \
        '{version:1,operation:"open",ok:true,path:$path,branch:$branch}'
}

backend_git_open_create() {
    local repo=$1 branch=$2 create_base=$3 path detail base error_file ref upstream
    ref=refs/heads/$branch
    if ! "${FORESTR_GIT_BIN:-git}" check-ref-format --branch "$branch" >/dev/null 2>&1; then
        backend_git_failure open "Invalid branch name: $branch."; return
    fi
    if backend_git_ref_exists "$repo" "refs/heads/$branch"; then
        backend_git_failure open "Local branch already exists: $branch; select it instead."
        return
    fi
    if ! base=$(backend_git_resolve_base "$repo" "$create_base" 2>&1); then backend_git_failure open "$base"; return; fi
    if ! path=$(backend_git_path_for_branch "$repo" "$branch" 2>&1); then backend_git_failure open "$path"; return; fi
    if ! detail=$(backend_git_validate_planned_path "$repo" "$path" "$branch" 2>&1); then backend_git_failure open "$detail"; return; fi
    error_file=$(mktemp "${TMPDIR:-/tmp}/forestr-git-add.XXXXXX")
    # Conservative initial policy: typed branches never infer tracking, even
    # when the chosen base happens to be a remote-tracking ref.
    if ! "${FORESTR_GIT_BIN:-git}" -C "$repo" worktree add --no-track -b "$branch" "$path" "$base" > /dev/null 2>"$error_file"; then
        detail=$(backend_git_add_error "$branch" "$error_file"); rm -f "$error_file"
        backend_git_failure open "$detail"; return
    fi
    rm -f "$error_file"
    upstream=$("${FORESTR_GIT_BIN:-git}" -C "$path" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if ! backend_git_verify_created_worktree "$repo" "$path" "$ref" || [[ -n $upstream ]]; then
        backend_git_failure open "Checkout was created at $path but exact branch or no-tracking verification failed; checkout retained for inspection."
        return
    fi
    "$JQ_BIN" -cn --arg path "$path" --arg branch "$branch" \
        '{version:1,operation:"open",ok:true,path:$path,branch:$branch}'
}

backend_git_remove_result() {
    local outcome=$1 warning=${2:-}
    "$JQ_BIN" -cn --arg outcome "$outcome" --arg warning "$warning" \
        '{version:1,operation:"remove",ok:true,removed_worktree:true,branch_outcome:$outcome,warning:$warning}'
}

backend_git_remove() {
    local repo=$1 target=$2 selected_path=$3 force=$4 repo_common selected_common branch branch_ref command_repo
    local error_file detail checkout outcome warning command_force=()
    [[ -n $selected_path ]] || { backend_git_failure remove 'The selected worktree has no checkout path.'; return; }
    if ! backend_git_find_worktree "$repo" "$selected_path"; then
        backend_git_failure remove "Selected checkout is not a registered worktree in this repository: $selected_path."
        return
    fi
    if [[ $BG_WORKTREE_PRIMARY == true ]]; then
        backend_git_failure remove 'The primary worktree cannot be removed.'; return
    fi
    command_repo=$(backend_git_primary_path "$repo" || true)
    [[ -n $command_repo && -d $command_repo ]] || {
        backend_git_failure remove 'Git could not identify a stable primary worktree for removal.'; return; }
    if [[ -d $BG_WORKTREE_PATH ]]; then
        repo_common=$(backend_git_common_dir "$repo" || true)
        selected_common=$(backend_git_common_dir "$BG_WORKTREE_PATH" || true)
        if [[ -z $repo_common || $selected_common != "$repo_common" ]]; then
            backend_git_failure remove 'Selected checkout does not belong to the same Git repository.'; return
        fi
    elif [[ -z $BG_WORKTREE_PRUNABLE ]]; then
        backend_git_failure remove 'Selected worktree path is missing but is not safely prunable; use Worktrunk or inspect it manually.'
        return
    fi
    branch=${BG_WORKTREE_BRANCH#refs/heads/}; branch_ref=$BG_WORKTREE_BRANCH
    if ! backend_git_target_matches_worktree "$target" "$selected_path" "$branch"; then
        backend_git_failure remove "Selected worktree now has branch $branch at $BG_WORKTREE_CANONICAL, not $target."; return
    fi
    [[ $force != true ]] || command_force=(--force)
    error_file=$(mktemp "${TMPDIR:-/tmp}/forestr-git-remove.XXXXXX")
    if ! "${FORESTR_GIT_BIN:-git}" -C "$command_repo" worktree remove ${command_force[@]+"${command_force[@]}"} "$BG_WORKTREE_PATH" 2>"$error_file"; then
        detail=$(sed -n '1{s/^fatal: //;p;}' "$error_file"); rm -f "$error_file"
        backend_git_failure remove "Git refused to remove $BG_WORKTREE_PATH${detail:+: $detail}."
        return
    fi
    rm -f "$error_file"
    if [[ -z $branch_ref ]]; then backend_git_remove_result not_applicable; return; fi
    error_file=$(mktemp "${TMPDIR:-/tmp}/forestr-git-branch.XXXXXX")
    if [[ $force == true ]]; then
        "${FORESTR_GIT_BIN:-git}" -C "$command_repo" branch -D -- "$branch" > /dev/null 2>"$error_file" || true
    else
        "${FORESTR_GIT_BIN:-git}" -C "$command_repo" branch -d -- "$branch" > /dev/null 2>"$error_file" || true
    fi
    if ! backend_git_ref_exists "$command_repo" "$branch_ref"; then rm -f "$error_file"; backend_git_remove_result deleted; return; fi
    if checkout=$(backend_git_branch_checkout "$command_repo" "$branch_ref"); then
        outcome=retained_checked_out
        warning="Worktree removed, but branch $branch is now checked out at $checkout and was retained."
    elif [[ $force != true ]] && ! "${FORESTR_GIT_BIN:-git}" -C "$command_repo" merge-base --is-ancestor "$branch_ref" HEAD >/dev/null 2>&1; then
        outcome=retained_unmerged
        warning="Worktree removed, but unmerged branch $branch was retained."
    else
        outcome=retained_failed
        detail=$(sed -n '1{s/^error: //;p;}' "$error_file")
        warning="Worktree removed, but branch $branch was retained${detail:+: $detail}."
    fi
    rm -f "$error_file"
    backend_git_remove_result "$outcome" "$warning"
}

backend_adapter_dispatch() {
    local request=$1 operation repo target mode intent path full_ref remote create_base force
    operation=$($JQ_BIN -r '.operation' <<<"$request")
    repo=$($JQ_BIN -r '.repo_root' <<<"$request")
    if ! backend_git_validate_repo "$repo"; then
        backend_git_failure "$operation" "Not a valid Git repository: $repo."
        return
    fi
    case $operation in
        open)
            target=$($JQ_BIN -r '.target' <<<"$request"); mode=$($JQ_BIN -r '.mode' <<<"$request")
            intent=$($JQ_BIN -r '.intent // (if .mode == "create" or .mode == "force-create" then "create_branch" else "local_branch" end)' <<<"$request")
            path=$($JQ_BIN -r '.path // ""' <<<"$request")
            full_ref=$($JQ_BIN -r '.full_ref // ""' <<<"$request")
            remote=$($JQ_BIN -r '.remote // ""' <<<"$request")
            create_base=$($JQ_BIN -r '.create_base // ""' <<<"$request")
            if [[ $mode == force-create ]]; then
                backend_git_failure open 'Force-create/clobber is not supported by the Git backend; no changes were made.'
                return
            fi
            case $intent in
                existing_worktree) backend_git_open_existing "$repo" "$target" "$path" ;;
                local_branch) backend_git_open_local "$repo" "$target" ;;
                remote_branch) backend_git_open_remote "$repo" "$target" "$full_ref" "$remote" ;;
                create_branch) backend_git_open_create "$repo" "$target" "$create_base" ;;
                *) backend_git_failure open "Unsupported Git open intent: $intent." ;;
            esac
            ;;
        remove)
            target=$($JQ_BIN -r '.target' <<<"$request"); path=$($JQ_BIN -r '.path // ""' <<<"$request")
            force=$($JQ_BIN -r '.force' <<<"$request")
            backend_git_remove "$repo" "$target" "$path" "$force"
            ;;
        enrich)
            backend_git_failure enrich 'The Git backend does not provide enrichment.'
            ;;
    esac
}
