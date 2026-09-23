#!/usr/bin/env bash

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'Forestr requires Bash 4 or newer (associative arrays are used).\n' >&2
    exit 2
fi

plugin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./lib.sh
source "$plugin_root/lib.sh"
# shellcheck source=./backend.sh
source "$plugin_root/backend.sh"
forestr_load_config

require_executable() {
    local name=$1 override=${2:-} candidate
    if [[ -n $override && ! -x $override ]]; then
        printf 'Forestr %s override is not executable: %s\n' "$name" "$override" >&2
        exit 127
    fi
    if ! candidate=$(forestr_find_executable "$name" "$override"); then
        printf 'Forestr requires %s; install it or set its explicit *_BIN override.\n' "$name" >&2
        exit 127
    fi
    printf '%s\n' "$candidate"
}

herdr=$(require_executable herdr "${HERDR_BIN_PATH:-${HERDR_BIN:-}}")
fzf_bin=$(require_executable fzf "${FZF_BIN:-}")
git_bin=$(require_executable git "${GIT_BIN:-}")
jq_bin=$(require_executable jq "${JQ_BIN:-}")
export JQ_BIN=$jq_bin
export FORESTR_GIT_BIN=$git_bin
curl_bin=$(require_executable curl "${CURL_BIN:-}")
bash_bin=$(require_executable bash "${FORESTR_BASH_BIN:-${BASH:-}}")
if ! "$bash_bin" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
    printf 'Forestr requires Bash 4 or newer (FORESTR_BASH_BIN=%s).\n' "$bash_bin" >&2
    exit 2
fi
printf -v bash_q '%q' "$bash_bin"
if [[ $bash_q != "$bash_bin" ]]; then
    printf 'Forestr requires a Bash executable path without whitespace or shell metacharacters (FORESTR_BASH_BIN=%s).\n' "$bash_bin" >&2
    exit 2
fi
export FORESTR_BASH_BIN=$bash_bin
backend_resolve "${WORKTRUNK_BIN:-}" || exit $?

verify_runtime_tools() {
    if ! "$curl_bin" --help all 2>&1 | grep -q -- '--unix-socket'; then
        printf 'Forestr requires curl with Unix-socket support (CURL_BIN=%s).\n' "$curl_bin" >&2
        return 1
    fi
}
case ${1:-} in __*) ;; *) verify_runtime_tools || exit 2 ;; esac

active_repo_root=${ACTIVE_REPO_ROOT:-}
if [[ -z $active_repo_root ]]; then
    active_repo_root=$("$git_bin" rev-parse --show-toplevel 2>/dev/null || true)
fi
manager_source_workspace_id=${MANAGER_SOURCE_WORKSPACE_ID:-}
manager_source_checkout_path=${MANAGER_SOURCE_CHECKOUT_PATH:-$active_repo_root}
create_scope=$(forestr_create_scope "${CREATE_SCOPE:-config}")
create_base=$(forestr_config_value create_base)
backend_capabilities_json=$(backend_capabilities)
backend_create_clobber=$($jq_bin -r '.features.create_clobber // false' <<<"$backend_capabilities_json")
backend_remove_stale=$($jq_bin -r '.features.remove_stale // false' <<<"$backend_capabilities_json")
enrich_backend=$FORESTR_BACKEND_ENRICH
enrichment_collection_timeout_ms=$FORESTR_BACKEND_ENRICHMENT_COLLECTION_TIMEOUT_MS
enrichment_concurrency=$FORESTR_BACKEND_ENRICHMENT_CONCURRENCY

forestr_load_config
status_icon_staged=${FORESTR_CONFIG_VALUES[status_icon_staged]:-+}
status_icon_modified=${FORESTR_CONFIG_VALUES[status_icon_modified]:-!}
status_icon_untracked=${FORESTR_CONFIG_VALUES[status_icon_untracked]:-?}
status_icon_unresolved=${FORESTR_CONFIG_VALUES[status_icon_unresolved]:-·}
status_icon_conflicted=${FORESTR_CONFIG_VALUES[status_icon_conflicted]:-✘}
status_icon_operation=${FORESTR_CONFIG_VALUES[status_icon_operation]:-↻}
status_icon_prunable=${FORESTR_CONFIG_VALUES[status_icon_prunable]:-⊟}
status_icon_locked=${FORESTR_CONFIG_VALUES[status_icon_locked]:-⊞}
status_icon_detached=${FORESTR_CONFIG_VALUES[status_icon_detached]:-⊘}
status_icon_warning=${FORESTR_CONFIG_VALUES[status_icon_warning]:-⚑}
status_icon_main=${FORESTR_CONFIG_VALUES[status_icon_main]:-^}
status_icon_orphan=${FORESTR_CONFIG_VALUES[status_icon_orphan]:-∅}
status_icon_empty=${FORESTR_CONFIG_VALUES[status_icon_empty]:-_}
status_icon_integrated=${FORESTR_CONFIG_VALUES[status_icon_integrated]:-⊂}
status_icon_would_conflict=${FORESTR_CONFIG_VALUES[status_icon_would_conflict]:-✗}
status_icon_same_commit=${FORESTR_CONFIG_VALUES[status_icon_same_commit]:-–}
status_icon_diverged=${FORESTR_CONFIG_VALUES[status_icon_diverged]:-↕}
status_icon_ahead=${FORESTR_CONFIG_VALUES[status_icon_ahead]:-↑}
status_icon_behind=${FORESTR_CONFIG_VALUES[status_icon_behind]:-↓}
status_icon_remote_synced=${FORESTR_CONFIG_VALUES[status_icon_remote_synced]:-|}
status_icon_remote_ahead=${FORESTR_CONFIG_VALUES[status_icon_remote_ahead]:-⇡}
status_icon_remote_behind=${FORESTR_CONFIG_VALUES[status_icon_remote_behind]:-⇣}
status_icon_remote_diverged=${FORESTR_CONFIG_VALUES[status_icon_remote_diverged]:-⇅}
status_icons_json=$($jq_bin -cn \
    --arg staged "$status_icon_staged" --arg modified "$status_icon_modified" --arg untracked "$status_icon_untracked" \
    --arg unresolved "$status_icon_unresolved" --arg conflicted "$status_icon_conflicted" --arg operation "$status_icon_operation" \
    --arg prunable "$status_icon_prunable" --arg locked "$status_icon_locked" --arg detached "$status_icon_detached" \
    --arg warning "$status_icon_warning" --arg main "$status_icon_main" --arg orphan "$status_icon_orphan" \
    --arg empty "$status_icon_empty" --arg integrated "$status_icon_integrated" \
    --arg would_conflict "$status_icon_would_conflict" --arg same_commit "$status_icon_same_commit" \
    --arg diverged "$status_icon_diverged" --arg ahead "$status_icon_ahead" --arg behind "$status_icon_behind" \
    --arg remote_synced "$status_icon_remote_synced" --arg remote_ahead "$status_icon_remote_ahead" \
    --arg remote_behind "$status_icon_remote_behind" --arg remote_diverged "$status_icon_remote_diverged" \
    '{staged:$staged,modified:$modified,untracked:$untracked,unresolved:$unresolved,
      conflicted:$conflicted,operation:$operation,
      prunable:$prunable,locked:$locked,detached:$detached,warning:$warning,main:$main,orphan:$orphan,
      empty:$empty,integrated:$integrated,would_conflict:$would_conflict,same_commit:$same_commit,
      diverged:$diverged,ahead:$ahead,behind:$behind,remote_synced:$remote_synced,
      remote_ahead:$remote_ahead,remote_behind:$remote_behind,remote_diverged:$remote_diverged}')

pause_after_error() {
    # Worker actions run with no terminal. Only offer an interactive pause when
    # this function is used by a genuine foreground invocation.
    [[ -t 0 && -t 2 ]] || return 0
    printf ' Press any key to continue.' >&2
    read -r -n 1 || true
    printf '\n' >&2
}

canonical_directory() {
    (cd "$1" 2>/dev/null && pwd -P)
}
manager_source_canonical=$(canonical_directory "$manager_source_checkout_path" || true)

active_repository_key() {
    local active_canonical active_git_dir active_key
    [[ -n $active_repo_root ]] || return 0
    active_canonical=$(canonical_directory "$active_repo_root" || true)
    [[ -n $active_canonical ]] || return 0
    active_git_dir=$("$git_bin" -C "$active_canonical" rev-parse --git-common-dir 2>/dev/null || true)
    case $active_git_dir in
        /*) active_key=$active_git_dir ;;
        "") active_key=$active_canonical ;;
        *) active_key=$active_canonical/$active_git_dir ;;
    esac
    canonical_directory "$active_key" || printf '%s\n' "$active_key"
}

active_repository_record() {
    local root key name
    [[ -n $active_repo_root ]] || return 0
    root=$(canonical_directory "$active_repo_root" || true)
    key=$(active_repository_key)
    [[ -n $root && -n $key ]] || return 0
    name=${root##*/}
    "$jq_bin" -Rnr --arg root "$root" --arg key "$key" --arg name "$name" \
        '{repo_root:$root,repo_key:$key,repo_name:$name} | tojson | @base64'
}

# One encoded JSON record per repository. The active repository is first, then
# repositories recovered from Herdr workspace metadata. Canonical roots/common
# directories prevent a linked checkout from being discovered twice.
repository_records() {
    local warnings_file=${1:-/dev/null} workspace_file=${2:-}
    local workspace_json records record repo_root repo_key canonical_root canonical_key active_canonical
    local active_name active_key existing encoded active_record=""
    local -a seen_roots=() seen_keys=() others=()

    active_key=$(active_repository_key)
    if [[ -n $workspace_file ]]; then
        workspace_json=$(cat "$workspace_file")
    elif ! workspace_json=$("$herdr" workspace list 2>/dev/null); then
        printf 'Herdr could not list workspaces; only the active repository is shown.\n' >>"$warnings_file"
        workspace_json='{}'
    fi
    records=$("$jq_bin" -r '
        .result.workspaces[]? | .worktree? // empty
        | select(.repo_root != null and .repo_root != "")
        | {repo_root: .repo_root, repo_key: (.repo_key // .repo_root),
           repo_name: (.repo_name // (.repo_root | split("/") | last))}
        | tojson | @base64
    ' <<<"$workspace_json")

    while IFS= read -r record; do
        [[ -n $record ]] || continue
        repo_root=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .repo_root')
        repo_key=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .repo_key')
        canonical_root=$(canonical_directory "$repo_root" || true)
        canonical_key=$(canonical_directory "$repo_key" || printf '%s\n' "$repo_key")
        [[ -n $canonical_root ]] || continue
        existing=false
        for repo_root in "${seen_roots[@]}"; do
            [[ $repo_root != "$canonical_root" ]] || { existing=true; break; }
        done
        if ! $existing; then
            for repo_key in "${seen_keys[@]}"; do
                [[ $repo_key != "$canonical_key" ]] || { existing=true; break; }
            done
        fi
        $existing && continue
        seen_roots+=("$canonical_root")
        seen_keys+=("$canonical_key")
        encoded=$("$jq_bin" -Rnr --arg record "$record" --arg root "$canonical_root" --arg key "$canonical_key" '
            ($record | @base64d | fromjson) + {repo_root: $root, repo_key: $key} | tojson | @base64')
        if [[ -n $active_key && $canonical_key == "$active_key" ]]; then active_record=$encoded; else others+=("$encoded"); fi
    done <<<"$records"

    if [[ -n $active_key && -z $active_record ]]; then
        active_canonical=$(canonical_directory "$active_repo_root")
        active_name=${active_canonical##*/}
        active_record=$("$jq_bin" -Rnr --arg root "$active_canonical" --arg key "$active_key" --arg name "$active_name" \
            '{repo_root: $root, repo_key: $key, repo_name: $name} | tojson | @base64')
    fi
    [[ -z $active_record ]] || printf '%s\n' "$active_record"
    [[ ${#others[@]} -eq 0 ]] || printf '%s\n' "${others[@]}"
}

table_jq_defs='
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
        explode as $codepoints
        | if ([$codepoints[] | select(. >= 127462 and . <= 127487)] | length) >= 2 then 2
          elif any($codepoints[]; . == 65039 or . == 8419) then 2
          else [$codepoints[] | codepoint_width] | max // 0 end;
    def display_width: [scan("\\X") | grapheme_width] | add // 0;
    def take_width(n): reduce (scan("\\X")) as $grapheme
        ({text: "", width: 0, full: true}; ($grapheme | grapheme_width) as $width
         | if .full and (.width + $width <= n)
           then .text += $grapheme | .width += $width else .full = false end)
        | .text;
    def pad(n): tostring as $text | ($text | display_width) as $width
        | if $width >= n then $text else $text + ([range(n - $width)] | map(" ") | join("")) end;
    def trunc(n): tostring as $text
        | if ($text | display_width) > n then ($text | take_width(n - 1)) + "…" else $text end;
    def cell(n): trunc(n) | pad(n);
    def tilde($home): tostring
        | if $home != "" and (. == $home or startswith($home + "/")) then "~" + .[($home | length):] else . end;
'

header_row() {
    # This ASCII-only row is constant; avoid starting jq during both the direct
    # seed and initial snapshot setup.
    printf '\t\t  REPOSITORY         BRANCH                             STATE      HEAD       PATH\n'
}

render_row() {
    local payload=$1 identity=$2 marker=$3 repo_name=$4 target=$5 state=$6 head=$7 path=$8
    "$jq_bin" -Rnr --arg payload "$payload" --arg identity "$identity" --arg marker "$marker" --arg repo "$repo_name" \
        --arg target "$target" --arg state "$state" --arg head "$head" --arg path "$path" \
        --arg home "${HOME:-}" "$table_jq_defs"'
        [$payload, $identity, ([$marker, ($repo | cell(18)), ($target | cell(34)), ($state | cell(10)),
                    ($head | cell(10)), ($path | tilde($home))] | join(" "))] | @tsv'
}

render_worktrunk_status() {
    local item=$1
    "$jq_bin" -r --argjson icons "$status_icons_json" "$table_jq_defs"'
        if (.status | type) != "object" then (.symbols // "")
        else
            .status as $status |
            def flag($value; $icon):
                (if $value == null then $icons.unresolved
                 elif $value then $icon else "" end) | cell(1);
            (($status.staged == null and $status.modified == null and $status.untracked == null)) as $changes_unresolved |
            ((if $changes_unresolved then $icons.unresolved | cell(1)
              else flag($status.staged; $icons.staged) end)) as $staged |
            ((if $changes_unresolved then "" | cell(1)
              else flag($status.modified; $icons.modified) end)) as $modified |
            ((if $changes_unresolved then "" | cell(1)
              else flag($status.untracked; $icons.untracked) end)) as $untracked |
            ((if $status.worktree_state == "unresolved" then $icons.unresolved
              else ($icons[$status.worktree_state] // "") end) | cell(1)) as $worktree |
            ((if $status.branch_state == "unresolved" then $icons.unresolved
              elif $status.branch_state == "is_main" then $icons.main
              else ($icons[$status.branch_state] // "") end) | cell(1)) as $branch |
            ((if $status.remote_state == "unresolved" then $icons.unresolved
              else ($icons["remote_" + $status.remote_state] // "") end) | cell(1)) as $remote |
            ((if $status.marker == null then $icons.unresolved
              else $status.marker end) | cell(2)) as $marker |
            $staged + $modified + $untracked + $worktree + $branch + $remote + $marker
        end
    ' <<<"$item"
}

# Parse Git's NUL-delimited porcelain format. This keeps spaces, tabs and other
# quoted-path edge cases out of the parser and performs no status/history work.
worktree_rows_for_repository() {
    local record=$1 repository repo_root repo_key repo_name porcelain primary=true
    local field path="" head="" branch="" locked="" prunable="" detached=false
    local target label kind marker state payload canonical_path identity
    repository=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson')
    repo_root=$("$jq_bin" -r '.repo_root' <<<"$repository")
    repo_key=$("$jq_bin" -r '.repo_key' <<<"$repository")
    repo_name=$("$jq_bin" -r '.repo_name' <<<"$repository")
    porcelain=$(mktemp "${TMPDIR:-/tmp}/forestr-worktree-porcelain.XXXXXX")
    if ! "$git_bin" -C "$repo_root" worktree list --porcelain -z >"$porcelain"; then rm -f "$porcelain"; return 1; fi

    emit_worktree_record() {
        [[ -n $path ]] || return 0
        if [[ -n $branch ]]; then
            target=${branch#refs/heads/}; label=$target
        else
            target=$path; label='(detached HEAD)'; detached=true
        fi
        kind=worktree; $primary && kind=main
        canonical_path=$(canonical_directory "$path" || printf '%s\n' "$path")
        if [[ -n $manager_source_canonical && $canonical_path == "$manager_source_canonical" ]]; then marker=@
        elif $primary; then marker=^
        else marker=+
        fi
        state=""
        $detached && state=detached
        [[ -z $locked ]] || state=${state:+$state,}locked
        [[ -z $prunable ]] || state=${state:+$state,}prunable
        payload=$("$jq_bin" -cn --arg kind "$kind" --arg target "${target}" --arg path "$path" \
            --arg canonical_path "$canonical_path" --arg repo_root "$repo_root" --arg repo_key "$repo_key" \
            --arg repo_name "$repo_name" --arg marker "$marker" --arg row_label "$label" --arg state "$state" \
            --arg head "${head:0:10}" \
            '{contract_version:1,kind:$kind,target:$target,path:$path,canonical_path:$canonical_path,repo_root:$repo_root,
              repo_key:$repo_key,repo_name:$repo_name,marker:$marker,"label":$row_label,state:$state,head:$head}' \
            | base64 | tr -d '\n')
        identity=$(printf '%s\0%s' "$repo_key" "$canonical_path" | base64 | tr -d '\n')
        render_row "$payload" "$identity" "$marker" "$repo_name" "$label" "$state" "${head:0:10}" "$path"
        primary=false; path=""; head=""; branch=""; locked=""; prunable=""; detached=false
    }

    while IFS= read -r -d '' field; do
        if [[ -z $field ]]; then emit_worktree_record; continue; fi
        case $field in
            'worktree '*) path=${field#worktree } ;;
            'HEAD '*) head=${field#HEAD } ;;
            'branch '*) branch=${field#branch } ;;
            detached) detached=true ;;
            locked*) locked=${field#locked} ;;
            prunable*) prunable=${field#prunable} ;;
        esac
    done <"$porcelain"
    emit_worktree_record
    rm -f "$porcelain"
}

manage_rows() {
    local warnings_file=${1:-/dev/null} repositories record repo_name repo_key error
    local active_record="" emitted_key=""
    header_row

    # The invoking repository reaches fzf before the Herdr metadata query used
    # for global discovery. That query can add repositories but cannot delay the
    # first local skeleton row.
    active_record=$(active_repository_record)
    if [[ -n $active_record ]]; then
        emitted_key=$("$jq_bin" -Rnr --arg record "$active_record" '$record | @base64d | fromjson | .repo_key')
        if ! worktree_rows_for_repository "$active_record"; then
            repo_name=$("$jq_bin" -Rnr --arg record "$active_record" '$record | @base64d | fromjson | .repo_name')
            printf '⚠ %s: Git could not list worktrees.\n' "$repo_name" >>"$warnings_file"
        fi
    fi

    repositories=$(repository_records "$warnings_file")
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        repo_key=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .repo_key')
        [[ -z $emitted_key || $repo_key != "$emitted_key" ]] || continue
        repo_name=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .repo_name')
        if ! worktree_rows_for_repository "$record"; then
            error="⚠ $repo_name: Git could not list worktrees."
            grep -Fqx -- "$error" "$warnings_file" 2>/dev/null || printf '%s\n' "$error" >>"$warnings_file"
        fi
    done <<<"$repositories"
}

active_seed_row() {
    local repo_root repo_key repo_name path kind marker label payload identity
    repo_root=$(canonical_directory "$active_repo_root" || true)
    repo_key=$(active_repository_key)
    path=${manager_source_canonical:-$repo_root}
    [[ -n $repo_root && -n $repo_key && -n $path ]] || return 0
    repo_name=${repo_root##*/}; kind=worktree; marker=+
    [[ $path != "$repo_root" ]] || { kind=main; marker=^; }
    [[ -z $manager_source_canonical || $path != "$manager_source_canonical" ]] || marker=@
    label=${path##*/}
    payload=$("$jq_bin" -cn --arg kind "$kind" --arg target "$path" --arg path "$path" \
        --arg canonical_path "$path" --arg repo_root "$repo_root" --arg repo_key "$repo_key" \
        --arg repo_name "$repo_name" --arg marker "$marker" --arg row_label "$label" \
        '{contract_version:1,kind:$kind,target:$target,path:$path,canonical_path:$canonical_path,repo_root:$repo_root,
          repo_key:$repo_key,repo_name:$repo_name,marker:$marker,"label":$row_label,state:"open",head:""}' \
        | base64 | tr -d '\n')
    identity=$(printf '%s\0%s' "$repo_key" "$path" | base64 | tr -d '\n')
    render_row "$payload" "$identity" "$marker" "$repo_name" "$label" open "" "$path"
}

herdr_seed_rows() {
    local workspace_file=$1 record checkout repo_root repo_key repo_name canonical_path canonical_root canonical_key
    local kind marker label payload identity
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        checkout=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson|.checkout_path')
        repo_root=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson|.repo_root')
        repo_key=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson|.repo_key')
        repo_name=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson|.repo_name')
        canonical_path=$(canonical_directory "$checkout" || true)
        canonical_root=$(canonical_directory "$repo_root" || true)
        canonical_key=$(canonical_directory "$repo_key" || printf '%s\n' "$repo_key")
        [[ -n $canonical_path && -n $canonical_root && -n $canonical_key ]] || continue
        kind=worktree; marker=+
        [[ $canonical_path != "$canonical_root" ]] || { kind=main; marker=^; }
        [[ -z $manager_source_canonical || $canonical_path != "$manager_source_canonical" ]] || marker=@
        label=${canonical_path##*/}
        payload=$("$jq_bin" -cn --arg kind "$kind" --arg target "$canonical_path" --arg path "$checkout" \
            --arg canonical_path "$canonical_path" --arg repo_root "$canonical_root" --arg repo_key "$canonical_key" \
            --arg repo_name "$repo_name" --arg marker "$marker" --arg row_label "$label" \
            '{contract_version:1,kind:$kind,target:$target,path:$path,canonical_path:$canonical_path,repo_root:$repo_root,
              repo_key:$repo_key,repo_name:$repo_name,marker:$marker,"label":$row_label,state:"open",head:""}' \
            | base64 | tr -d '\n')
        identity=$(printf '%s\0%s' "$canonical_key" "$canonical_path" | base64 | tr -d '\n')
        render_row "$payload" "$identity" "$marker" "$repo_name" "$label" open "" "$checkout"
    done < <("$jq_bin" -r '.result.workspaces[]?.worktree? // empty
        | select(.checkout_path != null and .checkout_path != "" and .repo_root != null)
        | {checkout_path,repo_root,repo_key:(.repo_key // .repo_root),
           repo_name:(.repo_name // (.repo_root|split("/")|last))} | tojson | @base64' "$workspace_file")
}

merge_snapshot_rows() {
    local snapshot=$1 additions=$2 temporary="$snapshot.new" payload identity display
    local -A replacements=() emitted=()
    while IFS=$'\t' read -r payload identity display; do
        [[ -n $identity ]] || continue
        replacements["$identity"]="$payload"$'\t'"$identity"$'\t'"$display"
    done <"$additions"
    header_row >"$temporary"
    if [[ -f $snapshot ]]; then
        while IFS=$'\t' read -r payload identity display; do
            [[ -n $identity ]] || continue
            if [[ -n ${replacements[$identity]+x} ]]; then
                printf '%s\n' "${replacements[$identity]}" >>"$temporary"; emitted["$identity"]=1
            else
                printf '%s\t%s\t%s\n' "$payload" "$identity" "$display" >>"$temporary"
            fi
        done <"$snapshot"
    fi
    while IFS=$'\t' read -r payload identity display; do
        [[ -n $identity && -z ${emitted[$identity]+x} ]] || continue
        printf '%s\t%s\t%s\n' "$payload" "$identity" "$display" >>"$temporary"; emitted["$identity"]=1
    done <"$additions"
    mv "$temporary" "$snapshot"
}

current_generation() { cat "$1/generation" 2>/dev/null || printf '0\n'; }

generation_warnings_file() { printf '%s/warnings.%s\n' "$1" "$2"; }

reset_generation_warnings() {
    local file
    file=$(generation_warnings_file "$1" "$2")
    : >"$file"
}

append_generation_warning() {
    local state_dir=$1 generation=$2 warning=$3 file
    [[ $(current_generation "$state_dir") == "$generation" ]] || return 0
    file=$(generation_warnings_file "$state_dir" "$generation")
    grep -Fqx -- "$warning" "$file" 2>/dev/null || printf '%s\n' "$warning" >>"$file"
}

process_start_token() {
    local pid=$1 token
    token=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
    token=${token//[[:space:]]/}
    [[ -n $token ]] || return 1
    printf '%s\n' "$token"
}

producer_process_matches() {
    local pid=$1 state_dir=$2 generation=$3 token=$4 current_token command
    current_token=$(process_start_token "$pid" 2>/dev/null || true)
    [[ -n $current_token && $current_token == "$token" ]] || return 1
    command=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
    [[ $command == *"manager.sh __produce $state_dir $generation"* ]]
}

terminate_producer() {
    local pid=$1 pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null || true)
    pgid=${pgid//[[:space:]]/}
    if [[ -n $pgid && $pgid == "$pid" ]]; then
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    else
        kill "$pid" 2>/dev/null || true
    fi
}

acquire_producer_lock() {
    local state_dir=$1 attempts=0 max_attempts=1000
    while [[ -d $state_dir ]]; do
        mkdir "$state_dir/producer.lock" 2>/dev/null && return 0
        (( attempts += 1 ))
        (( attempts < max_attempts )) || return 1
        sleep 0.005
    done
    return 1
}

release_producer_lock() { rmdir "$1/producer.lock" 2>/dev/null || true; }

stop_producer() {
    local state_dir=$1 pid generation token should_kill=false
    if ! acquire_producer_lock "$state_dir"; then
        # A stale/contended lock must not defeat teardown. producer.pid is
        # atomically published, so an unlocked fallback is safe when paired
        # with the recorded process start token and completed-generation guard.
        [[ -d $state_dir && -f $state_dir/producer.pid ]] || return 0
        read -r pid generation token <"$state_dir/producer.pid" || return 0
        if [[ -n ${pid:-} && -n ${generation:-} && ! -e $state_dir/completed.$generation ]]; then
            if producer_process_matches "$pid" "$state_dir" "$generation" "$token"; then
                terminate_producer "$pid"
            fi
        fi
        return 0
    fi
    [[ ! -f $state_dir/producer.pid ]] || read -r pid generation token <"$state_dir/producer.pid"
    rm -f "$state_dir/producer.pid"
    if [[ -n ${pid:-} && -n ${generation:-} && ! -e $state_dir/completed.$generation ]]; then
        producer_process_matches "$pid" "$state_dir" "$generation" "$token" && should_kill=true
    fi
    release_producer_lock "$state_dir"
    if $should_kill; then
        terminate_producer "$pid"
    fi
}

register_producer() {
    local state_dir=$1 generation=$2 pid=$3 token temporary
    token=$(process_start_token "$pid" 2>/dev/null || true)
    [[ -n $token ]] || return 0
    if ! acquire_producer_lock "$state_dir"; then
        # The parent could not publish ownership (normally because teardown
        # removed the state directory). Terminate only the exact process whose
        # start token was captured above; never leave an untracked producer.
        if producer_process_matches "$pid" "$state_dir" "$generation" "$token"; then
            terminate_producer "$pid"
        fi
        return 0
    fi
    if [[ $(current_generation "$state_dir") == "$generation" && ! -e $state_dir/completed.$generation ]]; then
        temporary="$state_dir/producer.pid.new.$$"
        printf '%s %s %s\n' "$pid" "$generation" "$token" >"$temporary"
        mv "$temporary" "$state_dir/producer.pid"
    fi
    release_producer_lock "$state_dir"
}

complete_producer() {
    local state_dir=$1 generation=$2 pid record_generation token own_token
    own_token=$(process_start_token "$$" 2>/dev/null || true)
    acquire_producer_lock "$state_dir" || return 0
    [[ ! -f $state_dir/producer.pid ]] || read -r pid record_generation token <"$state_dir/producer.pid"
    if [[ ${pid:-} == "$$" && ${record_generation:-} == "$generation" && ${token:-} == "$own_token" \
        && $(current_generation "$state_dir") == "$generation" ]]; then
        rm -f "$state_dir/producer.pid"
    fi
    : >"$state_dir/completed.$generation"
    release_producer_lock "$state_dir"
}

render_fake_search_bar() {
    local state_dir=$1 mode=$2 search hint columns divider
    search=$(cat "$state_dir/search" 2>/dev/null || printf false)
    [[ $search != true && $mode != new ]] || return 0
    case $mode in
        manage) hint='/ search worktrees' ;;
        repository) hint='/ search repositories' ;;
        source) hint='/ search branches' ;;
        *) return 0 ;;
    esac
    columns=${FZF_COLUMNS:-80}
    [[ $columns =~ ^[0-9]+$ ]] || columns=80
    (( columns >= 24 )) || columns=24
    (( columns <= 500 )) || columns=500
    # fzf reserves cells for section padding; leave enough room to avoid its
    # trailing truncation marker on a nominally full-width divider.
    columns=$((columns - 4))
    printf -v divider '%*s' "$columns" ''
    divider=${divider// /─}
    printf '\033[2;90m%s\033[0m\n\033[2;90m%s\033[0m\n' "$hint" "$divider"
}

render_header() {
    local state_dir=$1 generation mode repository repo_name force base scope
    generation=$(current_generation "$state_dir")
    mode=$(cat "$state_dir/mode" 2>/dev/null || printf manage)
    render_fake_search_bar "$state_dir" "$mode"
    [[ $mode != manage ]] || cat "$(generation_warnings_file "$state_dir" "$generation")" 2>/dev/null || true
    case $mode in
        manage) ;;
        repository)
            cat "$state_dir/repository-warnings" 2>/dev/null || true
            ;;
        source|new)
            if [[ -s $state_dir/repository ]]; then
                repository=$(decode_row "$(cat "$state_dir/repository")" || printf '{}')
                repo_name=$("$jq_bin" -r '.repo_name // "repository"' <<<"$repository")
                if [[ $mode == source ]]; then
                    scope=$(cat "$state_dir/scope" 2>/dev/null || printf local)
                    printf '%s · %s\n' "$repo_name" "$scope"
                else
                    force=$(cat "$state_dir/force" 2>/dev/null || printf false)
                    base=${create_base:-default}
                    printf '%s · base %s\n' "$repo_name" "$base"
                    [[ $force != true ]] || printf '⚠ CLOBBER MODE: an existing destination may be replaced.\n'
                fi
            fi
            ;;
    esac
}

wrapped_status_message() {
    local file=$1 width=$2
    awk -v width="$width" '
      function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
      }
      function take_line(    candidate, cut, i, result) {
        if (length(message) <= width) {
          result = message
          message = ""
          return result
        }
        candidate = substr(message, 1, width + 1)
        cut = 0
        for (i = width; i >= 1; i--) {
          if (substr(candidate, i, 1) == " ") { cut = i; break }
        }
        if (cut < int(width / 3)) cut = width
        result = trim(substr(message, 1, cut))
        message = trim(substr(message, cut + 1))
        return result
      }
      NF {
        line = trim($0)
        if (line != "") message = message (message == "" ? "" : " ") line
      }
      END {
        first = take_line()
        if (length(message) <= width) {
          second = message
        } else {
          width--
          second = take_line() "…"
        }
        print first
        print second
      }
    ' "$file"
}

render_footer() {
    local state_dir=$1 mode search footer file color columns width line
    mode=$(cat "$state_dir/mode" 2>/dev/null || printf manage)
    search=$(cat "$state_dir/search" 2>/dev/null || printf false)
    footer="$state_dir/$mode.footer"
    [[ $search != true || $mode == new ]] || footer="$state_dir/$mode.search.footer"
    columns=${FZF_COLUMNS:-80}
    [[ $columns =~ ^[0-9]+$ ]] || columns=80
    (( columns >= 24 )) || columns=24
    (( columns <= 500 )) || columns=500
    width=$((columns - 4))
    file=
    if [[ -s $state_dir/error ]]; then
        file="$state_dir/error"; color=31
    elif [[ -s $state_dir/action-warning ]]; then
        file="$state_dir/action-warning"; color=33
    fi
    if [[ -n $file ]]; then
        while IFS= read -r line; do
            if [[ -n $line ]]; then printf '\033[%sm%s\033[0m\n' "$color" "$line"; else printf ' \n'; fi
        done < <(wrapped_status_message "$file" "$width")
    else
        # Keep both status rows allocated even when there is no message.
        printf ' \n \n'
    fi
    cat "$footer" 2>/dev/null || true
}

screen_rows() {
    local state_dir=$1 generation=${2:-$(current_generation "$state_dir")} mode
    mode=$(cat "$state_dir/mode" 2>/dev/null || printf manage)
    case $mode in
        repository) repository_rows "$state_dir" ;;
        source) source_rows "$(cat "$state_dir/repository")" "$(cat "$state_dir/scope")" ;;
        new) new_rows "$(cat "$state_dir/repository")" ;;
        *)
            if [[ -f $state_dir/snapshot.$(current_generation "$state_dir") ]]; then
                cat "$state_dir/snapshot.$(current_generation "$state_dir")"
            elif [[ -f $state_dir/snapshot.$generation ]]; then
                cat "$state_dir/snapshot.$generation"
            else
                header_row
            fi
            ;;
    esac
}

background_rows() {
    # Async manage notifications always re-read mode. A stale producer can
    # refresh the current wizard screen, but can never replace it with manage
    # rows or alter its query/input.
    screen_rows "$1" "$2"
}

notify_manage_snapshot() {
    local state_dir=$1 generation=$2 socket="$state_dir/fzf.sock" action manager_q state_q
    [[ ${MANAGER_BACKGROUND_NOTIFY:-true} == true ]] || return 0
    [[ $(current_generation "$state_dir") == "$generation" ]] || return 0
    [[ $(cat "$state_dir/mode" 2>/dev/null || printf manage) == manage ]] || return 0
    for _ in {1..100}; do [[ -S $socket ]] && break; sleep 0.01; done
    [[ -S $socket ]] || return 0
    manager_q=$(printf '%q' "$plugin_root/manager.sh"); state_q=$(printf '%q' "$state_dir")
    action="transform-header($bash_q $manager_q __header $state_q)+transform-footer($bash_q $manager_q __footer $state_q)+reload($bash_q $manager_q __background-rows $state_q $generation)"
    "$curl_bin" --silent --show-error --unix-socket "$socket" -X POST http://localhost/ -d "$action" >/dev/null 2>&1 || true
}

enriched_rows_for_repository() {
    local snapshot=$1 record=$2 result=$3 repository repo_key item encoded backend_path canonical_path
    local payload identity display row current_path merged marker repo_name label state head path
    local -A by_path=()
    repository=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson')
    repo_key=$("$jq_bin" -r '.repo_key' <<<"$repository")
    while IFS= read -r encoded; do
        [[ -n $encoded ]] || continue
        item=$("$jq_bin" -Rnr --arg i "$encoded" '$i|@base64d|fromjson')
        backend_path=$("$jq_bin" -r '.path // empty' <<<"$item")
        canonical_path=$(canonical_directory "$backend_path" || printf '%s\n' "$backend_path")
        [[ -n $canonical_path ]] || continue
        by_path["$canonical_path"]=$encoded
    done < <("$jq_bin" -r '.items[]? | select(.path != null) | tojson | @base64' "$result")

    while IFS=$'\t' read -r payload identity display; do
        [[ -n $identity ]] || continue
        row=$(decode_row "$payload") || continue
        [[ $("$jq_bin" -r '.repo_key' <<<"$row") == "$repo_key" ]] || continue
        current_path=$("$jq_bin" -r '.canonical_path // .path' <<<"$row")
        encoded=${by_path[$current_path]:-}; [[ -n $encoded ]] || continue
        item=$("$jq_bin" -Rnr --arg i "$encoded" '$i|@base64d|fromjson')
        state=$(render_worktrunk_status "$item")
        merged=$("$jq_bin" -cn --argjson row "$row" --argjson backend_item "$item" --arg backend_state "$state" '
            $row + {
              target: (if $backend_item.branch == "" then $row.target else $backend_item.branch end),
              "label": (if $backend_item.branch == "" then $row.label else $backend_item.branch end),
              head: (if $backend_item.head == "" then $row.head else $backend_item.head end),
              state: (if ($backend_item.status | type) == "object" then $backend_state
                      else ([$backend_state, ($row.state // empty)]
                            | map(select(length > 0)) | unique | join(",")) end)
            }')
        payload=$(printf '%s' "$merged" | base64 | tr -d '\n')
        marker=$("$jq_bin" -r '.marker' <<<"$merged"); repo_name=$("$jq_bin" -r '.repo_name' <<<"$merged")
        label=$("$jq_bin" -r '.label' <<<"$merged"); state=$("$jq_bin" -r '.state' <<<"$merged")
        head=$("$jq_bin" -r '.head' <<<"$merged"); path=$("$jq_bin" -r '.path' <<<"$merged")
        render_row "$payload" "$identity" "$marker" "$repo_name" "$label" "$state" "$head" "$path"
    done <"$snapshot"
}

produce_manage_layers() {
    local state_dir=$1 generation=$2
    local snapshot="$state_dir/snapshot.$generation"
    local workspace_file="$state_dir/workspaces.$generation.json" seed_rows="$state_dir/seed.$generation.rows"
    local records_file="$state_dir/repositories.$generation" record repo_name repo_root rows result additions status request
    local -a batch_records=() batch_results=() batch_pids=()
    trap 'trap - TERM INT HUP; [[ ${#batch_pids[@]} -eq 0 ]] || kill "${batch_pids[@]}" 2>/dev/null || true; exit 0' TERM INT HUP

    if ! "$herdr" workspace list >"$workspace_file" 2>/dev/null; then
        printf '{}\n' >"$workspace_file"
        append_generation_warning "$state_dir" "$generation" \
            '⚠ Herdr could not list workspaces; only the active repository is shown.'
    fi
    herdr_seed_rows "$workspace_file" >"$seed_rows"
    merge_snapshot_rows "$snapshot" "$seed_rows"
    notify_manage_snapshot "$state_dir" "$generation"
    repository_records "$(generation_warnings_file "$state_dir" "$generation")" "$workspace_file" >"$records_file"

    while IFS= read -r record; do
        [[ -n $record && $(current_generation "$state_dir") == "$generation" ]] || continue
        rows=$(mktemp "$state_dir/git.$generation.XXXXXX")
        if worktree_rows_for_repository "$record" >"$rows"; then
            merge_snapshot_rows "$snapshot" "$rows"
            notify_manage_snapshot "$state_dir" "$generation"
        else
            repo_name=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson|.repo_name')
            append_generation_warning "$state_dir" "$generation" "⚠ $repo_name: Git could not list worktrees."
        fi
        rm -f "$rows"
    done <"$records_file"

    [[ $enrich_backend == true && $(current_generation "$state_dir") == "$generation" ]] || return 0
    run_enrichment_batch() {
        local i
        for ((i=0; i<${#batch_pids[@]}; i++)); do
            status=0; wait "${batch_pids[$i]}" || status=$?
            result=${batch_results[$i]}; record=${batch_records[$i]}
            if [[ $status -eq 0 ]] && "$jq_bin" -e '.version == 1 and .operation == "enrich" and .ok == true and (.items | type == "array")' "$result" >/dev/null 2>&1; then
                additions="$result.rows"
                enriched_rows_for_repository "$snapshot" "$record" "$result" >"$additions"
                merge_snapshot_rows "$snapshot" "$additions"
                notify_manage_snapshot "$state_dir" "$generation"
                rm -f "$additions"
            fi
            rm -f "$result"
        done
        batch_records=(); batch_results=(); batch_pids=()
    }
    while IFS= read -r record; do
        [[ -n $record && $(current_generation "$state_dir") == "$generation" ]] || continue
        result=$(mktemp "$state_dir/backend.$generation.XXXXXX")
        repo_root=$("$jq_bin" -Rnr --arg r "$record" '$r|@base64d|fromjson|.repo_root')
        request=$("$jq_bin" -cn --arg repo_root "$repo_root" \
            --argjson collection_timeout_ms "$enrichment_collection_timeout_ms" \
            '{version:1,operation:"enrich",repo_root:$repo_root,
              collection_timeout_ms:$collection_timeout_ms}')
        backend_dispatch "$request" >"$result" 2>/dev/null &
        batch_records+=("$record"); batch_results+=("$result"); batch_pids+=("$!")
        [[ ${#batch_pids[@]} -lt $enrichment_concurrency ]] || run_enrichment_batch
    done <"$records_file"
    [[ ${#batch_pids[@]} -eq 0 ]] || run_enrichment_batch
}

start_refresh() {
    local state_dir=$1 force_topology=${2:-false} preserve_messages=${3:-false}
    local generation snapshot seed mode producer_pid monitor_was_on=false
    stop_producer "$state_dir"
    generation=$(( $(current_generation "$state_dir") + 1 ))
    printf '%s\n' "$generation" >"$state_dir/generation"
    $preserve_messages || rm -f "$state_dir/error" "$state_dir/action-warning"
    reset_generation_warnings "$state_dir" "$generation"
    mode=$(cat "$state_dir/mode" 2>/dev/null || printf manage)
    if [[ $mode != manage && $force_topology != true ]]; then
        : >"$state_dir/completed.$generation"
        return 0
    fi
    snapshot="$state_dir/snapshot.$generation"; seed="$state_dir/active.$generation.rows"
    active_seed_row >"$seed"; header_row >"$snapshot"; merge_snapshot_rows "$snapshot" "$seed"; rm -f "$seed"
    # Bash job control gives the producer its own process group on Linux and
    # macOS without relying on the Linux-only setsid utility.
    [[ $- != *m* ]] || monitor_was_on=true
    set -m
    "$bash_bin" "$plugin_root/manager.sh" __produce "$state_dir" "$generation" \
        </dev/null >"$state_dir/producer.$generation.log" 2>&1 &
    producer_pid=$!
    $monitor_was_on || set +m
    register_producer "$state_dir" "$generation" "$producer_pid"
}

repository_header() { printf '\t\t  REPOSITORY                 ROOT\n'; }
source_header() { printf '\t\t  SOURCE                                     TYPE       HEAD\n'; }
new_header() { printf '\t\t  NEW BRANCH INPUT\n'; }

repository_rows() {
    local state_dir=$1 records record repository repo_root repo_key repo_name payload identity preferred_key marker line
    local preferred="" preferred_record="" output=""
    [[ ! -s $state_dir/preferred-repository ]] || preferred=$(cat "$state_dir/preferred-repository")
    if [[ -n $preferred ]]; then
        preferred_key=$(decode_row "$preferred" | "$jq_bin" -r '.repo_key // empty' 2>/dev/null || true)
    else
        preferred_key=""
    fi
    : >"$state_dir/repository-warnings"
    records=$(repository_records "$state_dir/repository-warnings")
    repository_header
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        repository=$(decode_row "$record")
        repo_root=$("$jq_bin" -r '.repo_root' <<<"$repository")
        repo_key=$("$jq_bin" -r '.repo_key' <<<"$repository")
        repo_name=$("$jq_bin" -r '.repo_name' <<<"$repository")
        marker=' '
        [[ -z $preferred_key || $repo_key != "$preferred_key" ]] || marker='›'
        payload=$record
        identity=$(printf 'repository\0%s' "$repo_key" | base64 | tr -d '\n')
        line=$(printf '%s\t%s\t%s %-26s %s' "$payload" "$identity" "$marker" "$repo_name" "$repo_root")
        if [[ $marker == '›' ]]; then preferred_record=$line$'\n'; else output+=$line$'\n'; fi
    done <<<"$records"
    [[ -z $preferred_record ]] || printf '%s' "$preferred_record"
    printf '%s' "$output"
}

# Source candidates are deliberately generated only after selecting an explicit
# repository. for-each-ref is local plumbing: it never fetches or invokes the
# backend, and its result is independent of the pane that launched Forestr.
source_rows() {
    local record=$1 scope=$2 repository repo_root repo_key repo_name line ref sha symref kind target payload remote branch
    local worktrees field branch_file refs_file identity
    local -a ref_namespaces
    repository=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson')
    repo_root=$("$jq_bin" -r '.repo_root' <<<"$repository")
    repo_key=$("$jq_bin" -r '.repo_key' <<<"$repository")
    repo_name=$("$jq_bin" -r '.repo_name' <<<"$repository")
    source_header
    payload=$("$jq_bin" -cn --arg repo_root "$repo_root" --arg repo_key "$repo_key" --arg repo_name "$repo_name" \
        '{contract_version:1,kind:"new",target:"",path:"",repo_root:$repo_root,repo_key:$repo_key,repo_name:$repo_name}' \
        | base64 | tr -d '\n')
    identity=$(printf '%s\0new' "$repo_key" | base64 | tr -d '\n')
    printf '%s\t%s\t  + Create a new branch…\n' "$payload" "$identity"
    branch_file=$(mktemp "${TMPDIR:-/tmp}/forestr-worktree-branches.XXXXXX")
    refs_file=$(mktemp "${TMPDIR:-/tmp}/forestr-worktree-refs.XXXXXX")
    : >"$branch_file"
    if "$git_bin" -C "$repo_root" worktree list --porcelain -z >"$refs_file.worktrees"; then
        while IFS= read -r -d '' field; do
            [[ $field != 'branch refs/heads/'* ]] || printf '%s\n' "${field#branch refs/heads/}" >>"$branch_file"
        done <"$refs_file.worktrees"
    fi
    case $scope in
        local) ref_namespaces=(refs/heads) ;;
        remote) ref_namespaces=(refs/remotes) ;;
        both) ref_namespaces=(refs/heads refs/remotes) ;;
    esac
    # Avoid %(objectname:short): abbreviating every object scans the object
    # database and is several seconds slower in repositories with many refs.
    "$git_bin" -C "$repo_root" for-each-ref --format='%(refname)%09%(objectname)%09%(symref)' \
        "${ref_namespaces[@]}" >"$refs_file"
    while IFS=$'\t' read -r ref sha symref; do
        remote=; branch=
        case $ref in
            refs/heads/*)
                [[ $scope == local || $scope == both ]] || continue
                target=${ref#refs/heads/}; kind=local
                grep -Fqx -- "$target" "$branch_file" && continue
                ;;
            refs/remotes/*)
                [[ $scope == remote || $scope == both ]] || continue
                [[ -z $symref ]] || continue
                target=${ref#refs/remotes/}; kind=remote
                remote=${target%%/*}; branch=${target#*/}
                [[ -n $remote && -n $branch && $branch != "$target" ]] || continue
                ;;
            *) continue ;;
        esac
        payload=$("$jq_bin" -cn --arg kind "$kind" --arg target "$target" --arg repo_root "$repo_root" \
            --arg repo_key "$repo_key" --arg repo_name "$repo_name" --arg full_ref "$ref" \
            --arg remote "${remote:-}" \
            '{contract_version:1,kind:$kind,target:$target,path:"",repo_root:$repo_root,repo_key:$repo_key,
              repo_name:$repo_name,full_ref:$full_ref,remote:$remote}' | base64 | tr -d '\n')
        identity=$(printf '%s\0%s' "$repo_key" "$ref" | base64 | tr -d '\n')
        if [[ $kind == local ]]; then
            printf '%s\t%s\tL %-42s local      %s\n' "$payload" "$identity" "$target" "${sha:0:10}"
        else
            printf '%s\t%s\tR %-42s remote     %s\n' "$payload" "$identity" "$target" "${sha:0:10}"
        fi
    done <"$refs_file"
    rm -f "$branch_file" "$refs_file" "$refs_file.worktrees"
}

new_rows() {
    local record=$1 repository repo_root repo_key repo_name payload identity
    repository=$(decode_row "$record")
    repo_root=$("$jq_bin" -r '.repo_root' <<<"$repository")
    repo_key=$("$jq_bin" -r '.repo_key' <<<"$repository")
    repo_name=$("$jq_bin" -r '.repo_name' <<<"$repository")
    new_header
    payload=$("$jq_bin" -cn --arg repo_root "$repo_root" --arg repo_key "$repo_key" --arg repo_name "$repo_name" \
        '{contract_version:1,kind:"new_input",target:"",path:"",repo_root:$repo_root,repo_key:$repo_key,repo_name:$repo_name}' \
        | base64 | tr -d '\n')
    identity=$(printf '%s\0new-input' "$repo_key" | base64 | tr -d '\n')
    printf '%s\t%s\t  Type a branch name, then press Enter (Esc returns)\n' "$payload" "$identity"
}

decode_row() {
    local payload=$1
    [[ -n $payload ]] || return 1
    "$jq_bin" -Rn --arg payload "$payload" '$payload | @base64d | fromjson' 2>/dev/null
}

workspace_id_for_path() {
    local wanted=$1 workspace_json record candidate_path candidate_id candidate_canonical
    workspace_json=$("$herdr" workspace list 2>/dev/null || true)
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        candidate_path=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .path')
        candidate_id=$("$jq_bin" -Rnr --arg record "$record" '$record | @base64d | fromjson | .id')
        candidate_canonical=$(canonical_directory "$candidate_path" || printf '%s\n' "$candidate_path")
        if [[ -n $candidate_canonical && $candidate_canonical == "$wanted" ]]; then printf '%s\n' "$candidate_id"; return 0; fi
    done < <("$jq_bin" -r '.result.workspaces[]? | select(.worktree.checkout_path != null)
        | {path:.worktree.checkout_path,id:.workspace_id} | tojson | @base64' <<<"$workspace_json")
}

open_target() {
    local repo_root=$1 target=$2 mode=$3 intent=${4:-local_branch} selected_path=${5:-} full_ref=${6:-} remote=${7:-}
    local request result worktree_path resolved_branch message
    local source_json herdr_repo_root root_workspace_id repo_label workspace_id canonical_worktree canonical_root
    local -a open_args
    request=$("$jq_bin" -cn --arg repo_root "$repo_root" --arg target "$target" --arg mode "$mode" \
        --arg intent "$intent" --arg path "$selected_path" --arg full_ref "$full_ref" --arg remote "$remote" \
        --arg create_base "$create_base" \
        '{version:1,operation:"open",repo_root:$repo_root,target:$target,mode:$mode,intent:$intent,
          path:$path,full_ref:$full_ref,remote:$remote,create_base:$create_base}')
    if ! result=$(backend_dispatch "$request"); then
        printf '\033[31mForestr backend could not process %s.\033[0m' "$target" >&2; pause_after_error; return 1
    fi
    if [[ $("$jq_bin" -r '.ok' <<<"$result") != true ]]; then
        message=$("$jq_bin" -r '.message' <<<"$result")
        printf '\033[31m%s\033[0m' "$message" >&2; pause_after_error; return 1
    fi
    worktree_path=$("$jq_bin" -r '.path' <<<"$result")
    resolved_branch=$("$jq_bin" -r '.branch' <<<"$result")
    canonical_worktree=$(canonical_directory "$worktree_path") || {
        printf '\033[31mForestr backend returned a checkout path that could not be resolved.\033[0m' >&2; pause_after_error; return 1; }
    workspace_id=$(workspace_id_for_path "$canonical_worktree")
    if [[ -n $workspace_id ]]; then
        if ! "$herdr" workspace focus "$workspace_id" >/dev/null; then
            printf '\033[31mHerdr could not focus workspace %s. The checkout was retained.\033[0m' "$workspace_id" >&2
            pause_after_error; return 1
        fi
        return 0
    fi
    if ! source_json=$("$herdr" worktree list --cwd "$repo_root"); then
        printf '\033[31mWorktree created, but Herdr could not inspect its repository. The checkout was retained.\033[0m' >&2
        pause_after_error; return 1
    fi
    herdr_repo_root=$("$jq_bin" -r '.result.source.repo_root // empty' <<<"$source_json")
    root_workspace_id=$("$jq_bin" -r '.result.source.source_workspace_id // empty' <<<"$source_json")
    repo_label=$("$jq_bin" -r '.result.source.repo_name // empty' <<<"$source_json")
    if [[ -z $herdr_repo_root ]]; then printf '\033[31mHerdr could not resolve the repository root.\033[0m' >&2; pause_after_error; return 1; fi
    if [[ -z $root_workspace_id ]] && ! "$herdr" workspace create --cwd "$herdr_repo_root" --label "${repo_label%.git}" --no-focus >/dev/null; then
        printf '\033[31mWorktree created, but Herdr could not create its parent workspace. The checkout was retained.\033[0m' >&2
        pause_after_error; return 1
    fi
    canonical_root=$(canonical_directory "$herdr_repo_root")
    open_args=(worktree open --cwd "$herdr_repo_root" --path "$worktree_path")
    [[ $canonical_worktree == "$canonical_root" ]] || open_args+=(--label "${resolved_branch:-$target}")
    open_args+=(--focus)
    if ! "$herdr" "${open_args[@]}"; then
        printf '\033[31mHerdr could not open the worktree workspace. The checkout was retained.\033[0m' >&2
        pause_after_error; return 1
    fi
}

remove_target() {
    local repo_root=$1 repo_name=$2 kind=$3 target=$4 worktree_path=$5 force=${6:-false}
    local canonical_path workspace_id source_canonical is_source=false source_json root_workspace_id
    local resolved_repo_root resolved_repo_name create_json request result message warning
    if [[ $kind != worktree || -z $worktree_path ]]; then
        printf '\033[33mSelect a linked worktree before removing.\033[0m' >&2; pause_after_error; return 1
    fi
    if ! canonical_path=$(canonical_directory "$worktree_path"); then
        if [[ $backend_remove_stale != true ]]; then
            printf '\033[31mThe %s backend cannot safely remove a missing or prunable worktree path; no changes were made.\033[0m' "$FORESTR_BACKEND" >&2
            pause_after_error; return 1
        fi
        canonical_path=$worktree_path
    fi
    workspace_id=$(workspace_id_for_path "$canonical_path")
    source_canonical=$(canonical_directory "$manager_source_checkout_path" || printf '%s\n' "$manager_source_checkout_path")
    if [[ -n $workspace_id && $workspace_id == "$manager_source_workspace_id" ]] || [[ -n $source_canonical && $source_canonical == "$canonical_path" ]]; then is_source=true; fi
    resolved_repo_root=$repo_root; resolved_repo_name=$repo_name; root_workspace_id=
    if $is_source; then
        if ! source_json=$("$herdr" worktree list --cwd "$repo_root"); then
            printf '\033[31mHerdr could not resolve the root workspace before removal; the worktree was retained.\033[0m' >&2
            pause_after_error; return 1
        fi
        resolved_repo_root=$("$jq_bin" -r '.result.source.repo_root // empty' <<<"$source_json")
        resolved_repo_name=$("$jq_bin" -r '.result.source.repo_name // empty' <<<"$source_json")
        root_workspace_id=$("$jq_bin" -r '.result.source.source_workspace_id // empty' <<<"$source_json")
        resolved_repo_root=${resolved_repo_root:-$repo_root}; resolved_repo_name=${resolved_repo_name:-$repo_name}
    fi
    request=$("$jq_bin" -cn --arg repo_root "$repo_root" --arg target "$target" --arg path "$worktree_path" \
        --argjson force "$force" \
        '{version:1,operation:"remove",repo_root:$repo_root,target:$target,path:$path,force:$force}')
    if ! result=$(backend_dispatch "$request"); then
        printf '\033[31mForestr backend could not remove %s.\033[0m' "$target" >&2; pause_after_error; return 1
    fi
    if [[ $("$jq_bin" -r '.ok' <<<"$result") != true ]]; then
        message=$("$jq_bin" -r '.message' <<<"$result")
        printf '\033[31m%s\033[0m' "$message" >&2; pause_after_error; return 1
    fi
    warning=$("$jq_bin" -r '.warning // empty' <<<"$result")
    if [[ -n $warning ]]; then
        printf '\033[33m%s\033[0m\n' "$warning" >&2
        if $is_source; then
            "$herdr" notification show 'Forestr removed worktree' --body "$warning" --sound none >/dev/null 2>&1 || true
        fi
    fi
    if $is_source; then
        if [[ -z $root_workspace_id ]]; then
            if ! create_json=$("$herdr" workspace create --cwd "$resolved_repo_root" --label "${resolved_repo_name%.git}" --no-focus); then
                printf '\033[31mWorktree removed, but Herdr could not create its root workspace.\033[0m' >&2; pause_after_error; return 1
            fi
            root_workspace_id=$("$jq_bin" -r '.result.workspace.workspace_id // .result.workspace.id // empty' <<<"$create_json")
        fi
        if [[ -z $root_workspace_id ]] || ! "$herdr" workspace focus "$root_workspace_id" >/dev/null; then
            printf '\033[31mWorktree removed, but Herdr could not focus its root workspace.\033[0m' >&2; pause_after_error; return 1
        fi
    fi
    if [[ -n $workspace_id ]] && ! "$herdr" workspace close "$workspace_id" >/dev/null; then
        printf '\033[31mWorktree removed, but Herdr could not close workspace %s.\033[0m' "$workspace_id" >&2; pause_after_error; return 1
    fi
    $is_source && return 10
    return 0
}

capture_action() {
    local state_dir=$1; shift
    local temporary="$state_dir/error.new.$$" output status=0
    rm -f "$state_dir/error" "$state_dir/action-warning" "$temporary"
    "$@" </dev/null >/dev/null 2>"$temporary" || status=$?
    output=$(sed $'s/\\033\\[[0-9;]*m//g' "$temporary")
    if [[ $status -ne 0 && $status -ne 10 ]]; then
        printf '%s\n' "${output:-The worktree action failed without an error message.}" >"$state_dir/error"
        cat "$state_dir/error" >&2
    elif [[ -n $output ]]; then
        printf '%s\n' "$output" >"$state_dir/action-warning"
    fi
    rm -f "$temporary"
    return "$status"
}

# Worker entrypoints are used by fzf reload/transform actions. They never open
# another popup; the parent invocation owns the one persistent fzf process.
case ${1:-} in
    __produce)
        status=0
        produce_manage_layers "$2" "$3" || status=$?
        complete_producer "$2" "$3"
        exit "$status"
        ;;
    __refresh)
        if [[ $(cat "$2/mode" 2>/dev/null || printf manage) == manage ]]; then start_refresh "$2"
        else rm -f "$2/error" "$2/action-warning"
        fi
        exit 0
        ;;
    __background-rows)
        background_rows "$2" "$3"; exit 0
        ;;
    __header)
        render_header "$2"; exit 0
        ;;
    __footer)
        render_footer "$2"; exit 0
        ;;
    __worktrunk-status)
        item=${2:-}; [[ -n $item ]] || item='{}'
        render_worktrunk_status "$item"; exit 0
        ;;
    __preview-toggle)
        state_dir=$2
        if [[ $(cat "$state_dir/mode" 2>/dev/null || printf manage) != manage ]]; then exit 0; fi
        if [[ $(cat "$state_dir/preview" 2>/dev/null || printf true) == true ]]; then
            printf 'false\n' >"$state_dir/preview"; printf 'hide-preview\n'
        else
            printf 'true\n' >"$state_dir/preview"; printf 'show-preview\n'
        fi
        exit 0
        ;;
    __preview-restore)
        if [[ $(cat "$2/preview" 2>/dev/null || printf true) == true ]]; then printf 'show-preview\n'; else printf 'hide-preview\n'; fi
        exit 0
        ;;
    __search-mode)
        case ${3:-false} in true|false) printf '%s\n' "$3" >"$2/search" ;; *) exit 1 ;; esac
        exit 0
        ;;
    __rows)
        state_dir=$2
        mode=$(cat "$state_dir/mode" 2>/dev/null || printf manage)
        if [[ $mode != manage ]]; then
            screen_rows "$state_dir"
        elif [[ -f $state_dir/snapshot.$(current_generation "$state_dir") ]]; then
            background_rows "$state_dir" "$(current_generation "$state_dir")"
        else
            : >"$state_dir/warnings"
            manage_rows "$state_dir/warnings"
        fi
        exit 0
        ;;
    __enter-repository)
        state_dir=$2 payload=${3:-}
        if selection=$(decode_row "$payload" 2>/dev/null); then
            "$jq_bin" -r '{repo_root,repo_key,repo_name} | tojson | @base64' <<<"$selection" >"$state_dir/preferred-repository"
        elif active=$(active_repository_record); then
            [[ -z $active ]] || printf '%s\n' "$active" >"$state_dir/preferred-repository"
        fi
        printf 'repository\n' >"$state_dir/mode"; printf 'false\n' >"$state_dir/search"
        rm -f "$state_dir/error" "$state_dir/action-warning"
        exit 0
        ;;
    __select-repository)
        state_dir=$2 payload=${3:-}
        selection=$(decode_row "$payload") || exit 1
        "$jq_bin" -e '.repo_root | type == "string" and length > 0' <<<"$selection" >/dev/null || exit 1
        "$jq_bin" -r '{repo_root,repo_key,repo_name} | tojson | @base64' <<<"$selection" >"$state_dir/repository"
        cp "$state_dir/repository" "$state_dir/preferred-repository"
        printf 'source\n' >"$state_dir/mode"; printf '%s\n' "$create_scope" >"$state_dir/scope"; printf 'false\n' >"$state_dir/force"
        printf 'false\n' >"$state_dir/search"
        rm -f "$state_dir/error" "$state_dir/action-warning"
        exit 0
        ;;
    __new-mode)
        state_dir=$2 force=${3:-false}
        [[ $(cat "$state_dir/mode" 2>/dev/null || true) == source ]] || exit 1
        if [[ $force == true && $backend_create_clobber != true ]]; then
            printf 'Force-create/clobber is not supported by the %s backend; no changes were made.\n' "$FORESTR_BACKEND" >"$state_dir/error"
            exit 1
        fi
        [[ -s $state_dir/repository ]] || exit 1
        printf '%s\n' "$force" >"$state_dir/force"; printf 'new\n' >"$state_dir/mode"; printf 'false\n' >"$state_dir/search"
        rm -f "$state_dir/error" "$state_dir/action-warning"
        exit 0
        ;;
    __manage-mode)
        printf 'manage\n' >"$2/mode"; printf 'false\n' >"$2/search"; rm -f "$2/error" "$2/action-warning"
        exit 0
        ;;
    __repository-mode)
        printf 'repository\n' >"$2/mode"; printf 'false\n' >"$2/search"; rm -f "$2/error" "$2/action-warning"
        exit 0
        ;;
    __source-mode)
        printf 'source\n' >"$2/mode"; printf 'false\n' >"$2/search"; rm -f "$2/error" "$2/action-warning"
        exit 0
        ;;
    __kind)
        decode_row "${2:-}" | "$jq_bin" -r '.kind // empty'
        exit 0
        ;;
    __scope)
        [[ $(cat "$2/mode" 2>/dev/null || true) == source ]] || exit 1
        printf '%s\n' "$(forestr_create_scope "$3")" >"$2/scope"; rm -f "$2/error"; exit 0
        ;;
    __open)
        state_dir=$2 payload=${3:-}
        rm -f "$state_dir/error" "$state_dir/action-warning"
        selection=$(decode_row "$payload" || printf '{}')
        repo_root=$("$jq_bin" -r '.repo_root // empty' <<<"$selection")
        target=$("$jq_bin" -r '.target // empty' <<<"$selection")
        kind=$("$jq_bin" -r '.kind // empty' <<<"$selection")
        selected_path=$("$jq_bin" -r '.canonical_path // .path // empty' <<<"$selection")
        full_ref=$("$jq_bin" -r '.full_ref // empty' <<<"$selection")
        remote=$("$jq_bin" -r '.remote // empty' <<<"$selection")
        open_mode=open
        case $kind in
            main|worktree) intent=existing_worktree ;;
            local) intent=local_branch ;;
            remote) intent=remote_branch ;;
            *) exit 1 ;;
        esac
        [[ -n $repo_root && -n $target ]] || exit 1
        set +e
        capture_action "$state_dir" open_target "$repo_root" "$target" "$open_mode" "$intent" \
            "$selected_path" "$full_ref" "$remote"
        status=$?
        set -e
        if [[ $status -ne 0 && $(cat "$state_dir/mode" 2>/dev/null || printf manage) == manage ]]; then
            # Manage-mode failures may follow a partial backend mutation; keep
            # its established topology refresh behavior. Source rows are lazy
            # and re-read Git directly, so wizard errors remain on-screen.
            start_refresh "$state_dir" true true
        fi
        exit "$status"
        ;;
    __create)
        state_dir=$2 query=${3:-}
        [[ $(cat "$state_dir/mode" 2>/dev/null || true) == new ]] || exit 1
        if [[ -z $query ]]; then
            printf 'Enter a non-empty branch name.\n' >"$state_dir/error"
            exit 1
        fi
        repository=$(decode_row "$(cat "$state_dir/repository")") || exit 1
        repo_root=$("$jq_bin" -r '.repo_root // empty' <<<"$repository")
        open_mode=create
        [[ $(cat "$state_dir/force") != true ]] || open_mode=force-create
        set +e
        capture_action "$state_dir" open_target "$repo_root" "$query" "$open_mode" create_branch
        status=$?
        set -e
        exit "$status"
        ;;
    __remove)
        state_dir=$2 payload=${3:-} force=${4:-false}
        rm -f "$state_dir/error"
        selection=$(decode_row "$payload") || exit 1
        set +e
        capture_action "$state_dir" remove_target \
            "$("$jq_bin" -r '.repo_root' <<<"$selection")" "$("$jq_bin" -r '.repo_name' <<<"$selection")" \
            "$("$jq_bin" -r '.kind' <<<"$selection")" "$("$jq_bin" -r '.target' <<<"$selection")" \
            "$("$jq_bin" -r '.path' <<<"$selection")" "$force"
        status=$?
        set -e
        if [[ $status -ne 10 ]]; then
            # A new generation starts synchronously with a clean seed snapshot,
            # so the upcoming reload cannot select a removed stale row. Refresh
            # failures too: Git may have succeeded before a later Herdr step.
            start_refresh "$state_dir" true true
        fi
        exit "$status"
        ;;
esac

config_error=false
key_down=$(forestr_key key_down j) || config_error=true
key_up=$(forestr_key key_up k) || config_error=true
key_first=$(forestr_key key_first g) || config_error=true
key_last=$(forestr_key key_last G) || config_error=true
key_search=$(forestr_key key_search /) || config_error=true
key_open=$(forestr_key key_open enter) || config_error=true
key_create=$(forestr_key key_create c) || config_error=true
key_new=$(forestr_key key_new n) || config_error=true
key_back=$(forestr_key key_back h) || config_error=true
key_force_create=$(forestr_key key_force_create C) || config_error=true
key_remove=$(forestr_key key_remove d) || config_error=true
key_force_remove=$(forestr_key key_force_remove D) || config_error=true
key_local=$(forestr_key key_local l) || config_error=true
key_remote=$(forestr_key key_remote r) || config_error=true
key_both=$(forestr_key key_both b) || config_error=true
key_preview=$(forestr_key key_preview p) || config_error=true
key_refresh=$(forestr_key key_refresh ctrl-r) || config_error=true
key_quit=$(forestr_key key_quit q) || config_error=true
key_normal=$(forestr_key key_normal esc) || config_error=true
$config_error && { sleep 3; exit 1; }
key_names=(key_down key_up key_first key_last key_search key_open key_create key_new key_back key_force_create key_remove key_force_remove key_local key_remote key_both key_preview key_refresh key_quit key_normal)
key_values=("$key_down" "$key_up" "$key_first" "$key_last" "$key_search" "$key_open" "$key_create" "$key_new" "$key_back" "$key_force_create" "$key_remove" "$key_force_remove" "$key_local" "$key_remote" "$key_both" "$key_preview" "$key_refresh" "$key_quit" "$key_normal")
for ((i=0; i<${#key_values[@]}; i++)); do
    for ((j=i+1; j<${#key_values[@]}; j++)); do
        if [[ ${key_values[$i]} == "${key_values[$j]}" ]]; then
            printf '\033[31mDuplicate keys: %s and %s both use %s.\033[0m\n' "${key_names[$i]}" "${key_names[$j]}" "${key_values[$i]}" >&2
            sleep 3; exit 1
        fi
    done
done
if [[ $key_normal != esc ]]; then
    for ((i=0; i<${#key_values[@]}-1; i++)); do
        if [[ ${key_values[$i]} == esc ]]; then
            printf '\033[31mThe esc key is reserved for modal navigation.\033[0m\n' >&2
            sleep 3; exit 1
        fi
    done
fi

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/forestr.XXXXXX")
fzf_pid=
cleanup() {
    stop_producer "$state_dir"
    [[ -z $fzf_pid ]] || kill "$fzf_pid" 2>/dev/null || true
    rm -rf "$state_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 130' INT
printf 'manage\n' >"$state_dir/mode"; printf '%s\n' "$create_scope" >"$state_dir/scope"
printf 'false\n' >"$state_dir/search"; printf 'true\n' >"$state_dir/preview"; printf '0\n' >"$state_dir/generation"

manager_script_q=$(printf '%q' "$plugin_root/manager.sh")
preview_script_q=$(printf '%q' "$plugin_root/preview.sh")
manager_q="$bash_q $manager_script_q"
state_q=$(printf '%q' "$state_dir")
rows_cmd="$manager_q __rows $state_q"
header_cmd="$manager_q __header $state_q"
footer_cmd="$manager_q __footer $state_q"
preview_cmd="$bash_q $preview_script_q {1}"
normal_label=esc; [[ $key_normal == esc ]] || normal_label+="/$key_normal"
back_label="$key_back/$normal_label"
select_label=enter; [[ $key_open == enter ]] || select_label="$key_open/enter"
manage_footer="$key_down/$key_up move · $select_label open · $key_create create · $key_remove/$key_force_remove delete/force · $key_preview preview · $key_search search · $key_refresh refresh · $key_quit quit · $back_label close"
repository_footer="$key_down/$key_up move · $select_label choose · $key_search search · $back_label back · $key_refresh refresh · $key_quit quit"
source_footer="$select_label use · $key_new new · $key_local/$key_remote/$key_both local/remote/both · $key_search search · $back_label back · $key_quit quit"
[[ $backend_create_clobber != true ]] || source_footer+=" · $key_force_create clobber-new"
new_footer="enter create · $normal_label back · ctrl-u clear · all characters are text"
printf '%s\n' "$manage_footer" >"$state_dir/manage.footer"
printf '%s\n' "$repository_footer" >"$state_dir/repository.footer"
printf '%s\n' "$source_footer" >"$state_dir/source.footer"
printf '%s\n' "$new_footer" >"$state_dir/new.footer"
printf '%s\n' "enter open · $normal_label clear search" >"$state_dir/manage.search.footer"
printf '%s\n' "enter choose · $normal_label clear search" >"$state_dir/repository.search.footer"
printf '%s\n' "enter use · $normal_label clear search" >"$state_dir/source.search.footer"

# Keys are mode-gated by transforms. Direct branch input additionally unbinds
# every configured printable action key so all branch-name characters reach
# fzf's query buffer unchanged; Enter and Esc remain dedicated controls.
bindable_keys="$key_down,$key_up,$key_first,$key_last,$key_search,$key_create,$key_new,$key_back,$key_force_create,$key_remove,$key_force_remove,$key_local,$key_remote,$key_both,$key_preview,$key_refresh,$key_quit"
[[ $key_open == enter ]] || bindable_keys+=",$key_open"
# Esc and its configurable equivalent remain dedicated controls. The h/l
# aliases are modal, so search and exact branch input explicitly unbind them.
direct_input_keys=$bindable_keys
join_key_actions() {
    local action=$1 csv=$2 key joined=""
    local -a keys
    IFS=, read -r -a keys <<<"$csv"
    for key in "${keys[@]}"; do joined+="${joined:++}$action($key)"; done
    printf '%s\n' "$joined"
}
modal_unbind_actions=$(join_key_actions unbind "$direct_input_keys")
modal_rebind_actions=$(join_key_actions rebind "$bindable_keys")
status_action="transform-footer($footer_cmd)"
chrome_actions="transform-header($header_cmd)+$status_action"
reload_actions="$chrome_actions+reload($rows_cmd)"
preview_restore_action="transform($manager_q __preview-restore $state_q)"
list_normal_actions="clear-query+disable-search+hide-input+rebind(change)+$modal_rebind_actions"
new_input_actions="hide-preview+show-input+clear-query+disable-search+change-prompt(branch name  )+change-ghost()+unbind(change)+$modal_unbind_actions+$reload_actions"
source_normal_actions="hide-preview+$list_normal_actions+change-prompt()+change-ghost()+$reload_actions"
repository_normal_actions="hide-preview+$list_normal_actions+change-prompt()+change-ghost()+$reload_actions"
manage_normal_actions="$preview_restore_action+$list_normal_actions+change-prompt()+change-ghost()+$reload_actions"

# One Enter binding serves all four screens. Failures update the fixed status
# area without rebuilding candidates; success aborts fzf so the common Herdr
# lifecycle owns focus/open behavior.
accept_transform="transform:mode=\$(cat $state_q/mode); case \$mode in manage) if $manager_q __open $state_q {1}; then echo abort; else echo '$status_action'; fi ;; repository) if $manager_q __select-repository $state_q {1}; then echo '$source_normal_actions'; else echo '$status_action'; fi ;; source) kind=\$($manager_q __kind {1} 2>/dev/null || true); if [[ \$kind = new ]]; then if $manager_q __new-mode $state_q false; then echo '$new_input_actions'; else echo '$status_action'; fi; elif $manager_q __open $state_q {1}; then echo abort; else echo '$status_action'; fi ;; new) if $manager_q __create $state_q {q}; then echo abort; else echo '$status_action'; fi ;; esac"
remove_transform="transform:if [[ \$(cat $state_q/mode) != manage ]]; then exit; fi; status=0; $manager_q __remove $state_q {1} false || status=\$?; if [[ \$status = 10 ]]; then echo abort; elif [[ \$status = 0 ]]; then echo 'exclude+$status_action'; else echo '$status_action'; fi"
force_remove_transform="transform:if [[ \$(cat $state_q/mode) != manage ]]; then exit; fi; status=0; $manager_q __remove $state_q {1} true || status=\$?; if [[ \$status = 10 ]]; then echo abort; elif [[ \$status = 0 ]]; then echo 'exclude+$status_action'; else echo '$status_action'; fi"
create_transition="transform:if [[ \$(cat $state_q/mode) = manage ]]; then $manager_q __enter-repository $state_q {1}; echo '$repository_normal_actions'; fi"
new_transition="transform:if [[ \$(cat $state_q/mode) = source ]] && $manager_q __new-mode $state_q false; then echo '$new_input_actions'; fi"
force_transition="transform:if [[ \$(cat $state_q/mode) = source ]]; then if $manager_q __new-mode $state_q true; then echo '$new_input_actions'; else echo '$status_action'; fi; fi"
search_transition="transform:mode=\$(cat $state_q/mode); case \$mode in manage) $manager_q __search-mode $state_q true; echo 'show-input+clear-query+enable-search+change-prompt(/ )+change-ghost(search worktrees)+unbind(change)+$modal_unbind_actions+$chrome_actions' ;; repository) $manager_q __search-mode $state_q true; echo 'show-input+clear-query+enable-search+change-prompt(/ )+change-ghost(search repositories)+unbind(change)+$modal_unbind_actions+$chrome_actions' ;; source) $manager_q __search-mode $state_q true; echo 'show-input+clear-query+enable-search+change-prompt(/ )+change-ghost(search branches)+unbind(change)+$modal_unbind_actions+$chrome_actions' ;; esac"
scope_local="transform:if [[ \$(cat $state_q/mode) = source ]]; then $manager_q __scope $state_q local; echo 'hide-input+change-prompt()+change-ghost()+$reload_actions'; fi"
scope_remote="transform:if [[ \$(cat $state_q/mode) = source ]]; then $manager_q __scope $state_q remote; echo 'hide-input+change-prompt()+change-ghost()+$reload_actions'; fi"
scope_both="transform:if [[ \$(cat $state_q/mode) = source ]]; then $manager_q __scope $state_q both; echo 'hide-input+change-prompt()+change-ghost()+$reload_actions'; fi"
refresh_transition="transform:mode=\$(cat $state_q/mode); case \$mode in manage|repository|source) $manager_q __refresh $state_q; echo '$reload_actions' ;; esac"
preview_toggle="transform:$manager_q __preview-toggle $state_q"
quit_transform="transform:[[ \$(cat $state_q/mode) = new ]] || echo abort"
esc_transform="transform:mode=\$(cat $state_q/mode); search=\$(cat $state_q/search 2>/dev/null || printf false); if [[ \$mode = new ]]; then $manager_q __source-mode $state_q; echo '$source_normal_actions'; elif [[ \$search = true ]]; then $manager_q __search-mode $state_q false; case \$mode in manage) echo '$manage_normal_actions' ;; repository) echo '$repository_normal_actions' ;; source) echo '$source_normal_actions' ;; esac; elif [[ \$mode = source ]]; then $manager_q __repository-mode $state_q; echo '$repository_normal_actions'; elif [[ \$mode = repository ]]; then $manager_q __manage-mode $state_q; echo '$manage_normal_actions'; else echo abort; fi"
normal_bind_args=(--bind="esc:$esc_transform" --bind="$key_back:$esc_transform")
if [[ $key_normal != esc ]]; then normal_bind_args+=(--bind="$key_normal:$esc_transform"); fi
open_bind_args=(--bind="enter:$accept_transform")
if [[ $key_open != enter ]]; then open_bind_args+=(--bind="$key_open:$accept_transform"); fi

start_refresh "$state_dir"
initial_snapshot="$state_dir/snapshot.$(current_generation "$state_dir")"

set +e
env -u FZF_API_KEY "$fzf_bin" \
    --disabled --with-shell="$bash_q -c" --delimiter=$'\t' --with-nth=3.. \
    --track --id-nth=2 --listen-unsafe="$state_dir/fzf.sock" \
    --preview="$preview_cmd" --preview-window='right,46%,border-left,nowrap,noinfo,~2,<65(down,40%,border-top)' \
    --header-lines=1 --reverse --info=inline-right --border=none --input-border=bottom --footer-border=none \
    --color='16,fg:-1,bg:-1,gutter:-1,input-bg:-1,list-bg:-1,header-bg:-1,footer-bg:-1,bg+:5,fg+:0:bold,hl:magenta,hl+:0:bold,pointer:-1,prompt:magenta,query:magenta,ghost:bright-black:dim,input-border:bright-black,header:bright-black,footer:bright-black,info:bright-black,disabled:bright-black,spinner:magenta' \
    --no-separator --no-scrollbar --highlight-line --pointer= \
    --prompt= --ghost= --header= --footer='loading…' \
    "${open_bind_args[@]}" \
    --bind="$key_create:$create_transition" --bind="$key_new:$new_transition" \
    --bind="$key_force_create:$force_transition" \
    --bind="$key_remove:$remove_transform" --bind="$key_force_remove:$force_remove_transform" \
    --bind="$key_local:$scope_local" --bind="$key_remote:$scope_remote" --bind="$key_both:$scope_both" \
    --bind="$key_preview:$preview_toggle" --bind="$key_refresh:$refresh_transition" --bind="$key_quit:$quit_transform" \
    --bind="$key_down:down" --bind="$key_up:up" --bind="$key_first:first" --bind="$key_last:last" \
    --bind="$key_search:$search_transition" --bind="load:transform-header($header_cmd)+transform-footer($footer_cmd)" \
    --bind="start:hide-input" --bind="change:clear-query" "${normal_bind_args[@]}" \
    <"$initial_snapshot" &
fzf_pid=$!
wait "$fzf_pid"
status=$?
fzf_pid=
set -e
stop_producer "$state_dir"
if [[ $status -gt 1 && $status -ne 130 ]]; then
    printf '\033[31mForestr exited because fzf failed with status %s.\033[0m' "$status" >&2
    pause_after_error
    exit "$status"
fi
exit 0
