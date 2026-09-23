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
            (($selection.repo_name // "repository") | clean_header)
        ] | .[] | ., "\u0000"
    ' 2>/dev/null
)
((${#fields[@]} == 6)) || exit 0
kind=${fields[0]}
[[ $kind == main || $kind == worktree ]] || exit 0
path=${fields[1]}
repo_root=${fields[2]}
repo_key=${fields[3]}
label=${fields[4]}
repo_name=${fields[5]}
preview_columns=${FZF_PREVIEW_COLUMNS:-80}
[[ $preview_columns =~ ^[0-9]+$ ]] || preview_columns=80
((preview_columns >= 44)) || preview_columns=44
changes_width=13
if ((preview_columns >= 72)); then
    show_author=true
    author_width=14
    age_width=12
    subject_width=$((preview_columns - 55))
else
    show_author=false
    author_width=0
    age_width=10
    subject_width=$((preview_columns - 37))
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

printf '\033[1m%s\033[0m \033[2m/\033[0m \033[1;35m%s\033[0m\n' "$repo_name" "$label"
if $show_author; then
    printf '\033[35m%-8s\033[0m  \033[2m%-*s  %-*s  %*s  %*s\033[0m\n' \
        COMMIT "$subject_width" SUBJECT "$author_width" AUTHOR "$age_width" WHEN "$changes_width" CHANGES
else
    printf '\033[35m%-8s\033[0m  \033[2m%-*s  %*s  %*s\033[0m\n' \
        COMMIT "$subject_width" SUBJECT "$age_width" WHEN "$changes_width" CHANGES
fi
if ! LC_ALL=C "$git_bin" -c i18n.logOutputEncoding=UTF-8 -C "$canonical_path" --no-pager \
    log HEAD --max-count=25 --date=relative --no-show-signature --color=never \
    --shortstat --no-renames --pretty=format:'%x1e%h%x1f%s%x1f%an%x1f%ar' 2>/dev/null \
    | "$jq_bin" -Rrs --argjson subject_width "$subject_width" \
        --argjson author_width "$author_width" --argjson age_width "$age_width" \
        --argjson changes_width "$changes_width" --argjson show_author "$show_author" '
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
            def grapheme_width:
                explode as $codepoints |
                if ([$codepoints[] | select(. >= 127462 and . <= 127487)] | length) >= 2 then 2
                elif any($codepoints[]; . == 65039 or . == 8419) then 2
                else [$codepoints[] | codepoint_width] | max // 0 end;
            def display_width: [scan("\\X") | grapheme_width] | add // 0;
            def take_width($width):
                reduce (scan("\\X")) as $grapheme
                    ({text: "", width: 0, full: true}; ($grapheme | grapheme_width) as $next_width |
                     if .full and (.width + $next_width <= $width) then
                         .text += $grapheme | .width += $next_width
                     else .full = false end) |
                .text;
            def truncate($width):
                if display_width > $width then take_width($width - 1) + "…" else . end;
            def fit($width):
                clean | truncate($width) as $value |
                $value + (" " * ($width - ($value | display_width)));
            def fit_right($width):
                clean | truncate($width) as $value |
                (" " * ($width - ($value | display_width))) + $value;
            def compact_count:
                if . >= 1000000 then (((. / 100000) | round) / 10 | tostring) + "m"
                elif . >= 1000 then (((. / 100) | round) / 10 | tostring) + "k"
                else tostring end;
            if length == 0 then empty else
            split("\u001e")[] | select(length > 0) as $record |
            ($record | split("\n")[0] | split("\u001f")) as $metadata |
            select(($metadata | length) >= 4 and ($metadata[0] | test("^[0-9a-f]+$"))) |
            ($metadata[0] | fit(8)) as $hash |
            ($metadata[1:-2] | join(" ") | fit($subject_width)) as $subject |
            ($metadata[-2] | fit($author_width)) as $author |
            ($metadata[-1] | fit_right($age_width)) as $age |
            ($record | ([scan("([0-9]+) insertion")][0][0] // "0") | tonumber) as $additions |
            ($record | ([scan("([0-9]+) deletion")][0][0] // "0") | tonumber) as $deletions |
            (if $additions == 0 and $deletions == 0 then
                "\u001b[2m" + ("—" | fit_right($changes_width)) + "\u001b[0m"
             else
                "\u001b[32m" + (("+" + ($additions | compact_count)) | fit_right(6)) + "\u001b[0m " +
                "\u001b[31m" + (("-" + ($deletions | compact_count)) | fit_right(6)) + "\u001b[0m"
             end) as $changes |
            "\u001b[1;35m" + $hash + "\u001b[0m  " +
            "\u001b[1m" + $subject + "\u001b[0m  " +
            (if $show_author then "\u001b[36m" + $author + "\u001b[0m  " else "" end) +
            "\u001b[2m" + $age + "\u001b[0m  " + $changes
            end
        '; then
    printf '\033[2mNo commits yet.\033[0m\n'
fi
