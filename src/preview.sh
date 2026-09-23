#!/usr/bin/env bash

set -euo pipefail

payload=${1:-}
git_bin=${FORESTR_GIT_BIN:-${GIT_BIN:-git}}
jq_bin=${JQ_BIN:-jq}

canonical_directory() {
    (cd "$1" 2>/dev/null && pwd -P)
}

resolve_worktree_key() {
    local checkout=$1 marker gitdir_line admin_dir common_dir
    resolved_key=
    marker=$checkout/.git
    if [[ -d $marker ]]; then
        resolved_key=$(canonical_directory "$marker" || true)
    elif [[ -f $marker ]]; then
        IFS= read -r gitdir_line <"$marker" || return 1
        [[ $gitdir_line == 'gitdir: '* ]] || return 1
        admin_dir=${gitdir_line#gitdir: }
        case $admin_dir in
            /*) admin_dir=$(canonical_directory "$admin_dir" || true) ;;
            *) admin_dir=$(canonical_directory "$checkout/$admin_dir" || true) ;;
        esac
        [[ -n $admin_dir ]] || return 1
        if [[ -f $admin_dir/commondir ]]; then
            IFS= read -r common_dir <"$admin_dir/commondir" || return 1
            case $common_dir in
                /*) resolved_key=$(canonical_directory "$common_dir" || true) ;;
                *) resolved_key=$(canonical_directory "$admin_dir/$common_dir" || true) ;;
            esac
        else
            resolved_key=$admin_dir
        fi
    fi
    [[ -n $resolved_key ]]
}

sanitize_log() {
    "$jq_bin" -Rr 'gsub("[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u061C\u200E-\u200F\u202A-\u202E\u2066-\u2069]"; " ")'
}

fields=()
while IFS= read -r -d '' field; do fields+=("$field"); done < <(
    "$jq_bin" -Rjn --arg payload "$payload" '
        def clean_header:
            gsub("[\u0000-\u001F\u007F-\u009F\u061C\u200E-\u200F\u202A-\u202E\u2066-\u2069]"; " ");
        ($payload | @base64d | fromjson) as $selection |
        [
            ($selection.kind // ""),
            ($selection.canonical_path // $selection.path // ""),
            ($selection.repo_root // ""),
            ($selection.repo_key // ""),
            (($selection.label // $selection.target // "worktree") | clean_header),
            (($selection.repo_name // "repository") | clean_header),
            (($selection.canonical_path // $selection.path // "") | clean_header)
        ] | .[] | ., "\u0000"
    ' 2>/dev/null
)
((${#fields[@]} == 7)) || exit 0
kind=${fields[0]}
[[ $kind == main || $kind == worktree ]] || exit 0
path=${fields[1]}
repo_root=${fields[2]}
repo_key=${fields[3]}
label=${fields[4]}
repo_name=${fields[5]}
display_path=${fields[6]}

canonical_path=$(canonical_directory "$path" || true)
canonical_root=$(canonical_directory "$repo_root" || true)
if [[ -z $canonical_path || -z $canonical_root ]]; then
    printf '\033[2mCommit log unavailable: worktree path no longer exists.\033[0m\n'
    exit 0
fi
if ! resolve_worktree_key "$canonical_path"; then
    printf '\033[2mCommit log unavailable: worktree identity changed.\033[0m\n'
    exit 0
fi
actual_key=$resolved_key

use_root_fallback=false
if [[ -z $repo_key ]]; then
    use_root_fallback=true
else
    provided_key=$(canonical_directory "$repo_key" || true)
    if [[ -z $provided_key ]]; then
        printf '\033[2mCommit log unavailable: worktree identity changed.\033[0m\n'
        exit 0
    fi
    if [[ $provided_key == "$canonical_root" ]]; then
        use_root_fallback=true
    elif [[ $provided_key != "$actual_key" ]]; then
        printf '\033[2mCommit log unavailable: worktree identity changed.\033[0m\n'
        exit 0
    fi
fi
if $use_root_fallback; then
    if ! resolve_worktree_key "$canonical_root"; then
        printf '\033[2mCommit log unavailable: worktree identity changed.\033[0m\n'
        exit 0
    fi
    if [[ $resolved_key != "$actual_key" ]]; then
        printf '\033[2mCommit log unavailable: worktree identity changed.\033[0m\n'
        exit 0
    fi
fi

printf '\033[1m%s  %s\033[0m\n\033[2m%s\033[0m\n\n' "$repo_name" "$label" "$display_path"
if ! "$git_bin" -c i18n.logOutputEncoding=UTF-8 -C "$canonical_path" --no-pager \
    log HEAD --max-count=25 --date=relative --no-show-signature --color=never \
    --pretty=format:'%h %s  %an  %ar' 2>/dev/null \
    | sanitize_log; then
    printf '\033[2mNo commits yet.\033[0m\n'
fi
