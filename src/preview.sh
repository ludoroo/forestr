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
preview_columns=${FZF_PREVIEW_COLUMNS:-80}
[[ $preview_columns =~ ^[0-9]+$ ]] || preview_columns=80
if ((preview_columns >= 44)); then
    author_width=14
    age_width=12
    subject_width=$((preview_columns - 40))
else
    ((preview_columns >= 32)) || preview_columns=32
    author_width=8
    age_width=8
    subject_width=$((preview_columns - 30))
fi

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

printf '\033[1;35mCOMMITS\033[0m  \033[1m%s / %s\033[0m\n' "$repo_name" "$label"
printf '\033[2m%s\033[0m\n' "$display_path"
printf '\033[35m%-8s\033[0m  \033[2m%-*s  %-*s  %*s\033[0m\n' \
    COMMIT "$subject_width" SUBJECT "$author_width" AUTHOR "$age_width" WHEN
if ! "$git_bin" -c i18n.logOutputEncoding=UTF-8 -C "$canonical_path" --no-pager \
    log HEAD --max-count=25 --date=relative --no-show-signature --color=never \
    --pretty=format:'%h%n%s%n%an%n%ar' 2>/dev/null \
    | "$jq_bin" -Rrs --argjson subject_width "$subject_width" \
        --argjson author_width "$author_width" --argjson age_width "$age_width" '
            def clean:
                gsub("[\u0000-\u001F\u007F-\u009F\u061C\u200E-\u200F\u202A-\u202E\u2066-\u2069]"; " ");
            def codepoint_width:
                if (. >= 768 and . <= 879) or (. >= 6832 and . <= 6911)
                    or (. >= 7616 and . <= 7679) or (. >= 8400 and . <= 8447)
                    or (. >= 65056 and . <= 65071) then 0
                elif (. >= 4352 and . <= 4447) or (. >= 8986 and . <= 8987)
                    or (. >= 9001 and . <= 9002) or (. >= 11904 and . <= 42191)
                    or (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255)
                    or (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65131)
                    or (. >= 65281 and . <= 65376) or (. >= 65504 and . <= 65510)
                    or (. >= 127744 and . <= 129535) or (. >= 131072 and . <= 196605) then 2
                else 1 end;
            def display_width: explode | map(codepoint_width) | add // 0;
            def take_width($width):
                reduce (explode[]) as $codepoint
                    ({text: [], width: 0, full: true}; ($codepoint | codepoint_width) as $next_width |
                     if .full and (.width + $next_width <= $width) then
                         .text += [$codepoint] | .width += $next_width
                     else .full = false end) |
                .text | implode;
            def truncate($width):
                if display_width > $width then take_width($width - 1) + "…" else . end;
            def fit($width):
                clean | truncate($width) as $value |
                $value + (" " * ($width - ($value | display_width)));
            def fit_right($width):
                clean | truncate($width) as $value |
                (" " * ($width - ($value | display_width))) + $value;
            if length == 0 then empty else
            split("\n") as $lines |
            range(0; ($lines | length); 4) as $index |
            ($lines[$index] // "" | fit(8)) as $hash |
            ($lines[$index + 1] // "" | fit($subject_width)) as $subject |
            ($lines[$index + 2] // "" | fit($author_width)) as $author |
            ($lines[$index + 3] // "" | fit_right($age_width)) as $age |
            "\u001b[1;35m" + $hash + "\u001b[0m  " +
            "\u001b[1m" + $subject + "\u001b[0m  " +
            "\u001b[36m" + $author + "\u001b[0m  " +
            "\u001b[2m" + $age + "\u001b[0m"
            end
        '; then
    printf '\033[2mNo commits yet.\033[0m\n'
fi
