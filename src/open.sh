#!/usr/bin/env bash

set -euo pipefail

plugin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./lib.sh
source "$plugin_root/lib.sh"
forestr_load_config

entrypoint=${1:-manager}
create_scope=$(forestr_create_scope "${2:-config}")
case $entrypoint in
    manager) ;;
    *) printf 'Unsupported Forestr pane: %s\n' "$entrypoint" >&2; exit 2 ;;
esac

herdr=${HERDR_BIN_PATH:-$(forestr_find_executable herdr "${HERDR_BIN:-}")}
jq_bin=$(forestr_find_executable jq "${JQ_BIN:-}") || {
    printf 'Could not find the jq executable.\n' >&2
    exit 1
}
export JQ_BIN="$jq_bin"
git_bin=$(forestr_find_executable git "${GIT_BIN:-}") || {
    printf 'Could not find the git executable.\n' >&2
    exit 1
}
workspace_id=$(forestr_context_value workspace_id)
pane_id=$(forestr_context_value focused_pane_id)
cwd=$(forestr_foreground_cwd "$herdr" "$pane_id" "$workspace_id")
git_root=
if [[ -n $cwd ]]; then
    git_root=$("$git_bin" -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
fi
if [[ -n $cwd && -d $cwd ]]; then
    popup_cwd=$cwd
else
    popup_cwd=${HOME:-/}
fi

fzf_bin=$(forestr_find_executable fzf "${FZF_BIN:-}") || {
    printf 'Could not find the fzf executable.\n' >&2
    exit 1
}

width=$(forestr_popup_dimension popup_width '90%')
height=$(forestr_popup_dimension popup_height '85%')
configured_backend=$(forestr_config_value backend)
configured_backend=${configured_backend:-auto}
backend_env=()
[[ $configured_backend == git ]] || backend_env=(--env "WORKTRUNK_BIN=${WORKTRUNK_BIN:-}")

exec "$herdr" plugin pane open \
    --plugin "${HERDR_PLUGIN_ID:-ludoroo.forestr}" \
    --entrypoint "$entrypoint" \
    --cwd "$popup_cwd" \
    --focus \
    --placement popup \
    --width "$width" \
    --height "$height" \
    ${backend_env[@]+"${backend_env[@]}"} \
    --env "FORESTR_BASH_BIN=${FORESTR_BASH_BIN:-${BASH:-bash}}" \
    --env "FZF_BIN=$fzf_bin" \
    --env "GIT_BIN=$git_bin" \
    --env "JQ_BIN=$jq_bin" \
    --env "CREATE_SCOPE=$create_scope" \
    --env "ACTIVE_REPO_ROOT=$git_root" \
    --env "MANAGER_SOURCE_WORKSPACE_ID=$workspace_id" \
    --env "MANAGER_SOURCE_CHECKOUT_PATH=$git_root"
