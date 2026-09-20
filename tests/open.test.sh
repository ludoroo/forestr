#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
non_repo="$tmp/non-repo"
git_bin=/usr/bin/git
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
mkdir -p "$repo" "$non_repo"
"$git_bin" -C "$repo" init -q

cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == pane && ${2:-} == list ]]; then
    printf '{"result":{"panes":[{"pane_id":"w1:p1","cwd":"/home/coder","foreground_cwd":"%s"}]}}\n' "$TEST_FOREGROUND_CWD"
    exit 0
fi
printf '%s\n' "$@" >"$TEST_CAPTURE"
EOF
chmod +x "$tmp/herdr"

export TEST_FOREGROUND_CWD="$repo"
export TEST_CAPTURE="$tmp/args"
export HERDR_PLUGIN_ROOT="$repo_root"
export HERDR_PLUGIN_ID='ludoroo.forestr'
export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","focused_pane_id":"w1:p1"}'
export HERDR_BIN_PATH="$tmp/herdr"
export WORKTRUNK_BIN=/bin/true
export FZF_BIN=/bin/true
export GIT_BIN="$git_bin"
export JQ_BIN=/usr/bin/jq

bash "$plugin_root/open.sh"

joined=$(cat "$TEST_CAPTURE")
grep -Fxq -- 'ludoroo.forestr' <<<"$joined"
grep -Fxq -- '--cwd' <<<"$joined"
grep -Fxq -- "$repo" <<<"$joined"
grep -Fxq -- '--placement' <<<"$joined"
grep -Fxq -- 'popup' <<<"$joined"
grep -Fxq -- 'WORKTRUNK_BIN=/bin/true' <<<"$joined"
grep -Fxq -- 'JQ_BIN=/usr/bin/jq' <<<"$joined"
grep -Fxq -- 'CREATE_SCOPE=local' <<<"$joined"
grep -Fxq -- "ACTIVE_REPO_ROOT=$repo" <<<"$joined"
grep -Fxq -- 'MANAGER_SOURCE_WORKSPACE_ID=w1' <<<"$joined"
grep -Fxq -- "MANAGER_SOURCE_CHECKOUT_PATH=$repo" <<<"$joined"

# The global manager can also open from a Herdr workspace whose active pane is
# not a Git checkout; represented repositories are discovered inside manager.
export TEST_FOREGROUND_CWD="$non_repo"
bash "$plugin_root/open.sh"
joined=$(cat "$TEST_CAPTURE")
grep -Fxq -- "$non_repo" <<<"$joined"
grep -Fxq -- 'ACTIVE_REPO_ROOT=' <<<"$joined"
grep -Fxq -- 'MANAGER_SOURCE_CHECKOUT_PATH=' <<<"$joined"

# Explicit Git mode does not propagate a Worktrunk executable into the popup.
mkdir -p "$tmp/config"
printf 'backend = "git"\n' >"$tmp/config/config.toml"
export HERDR_PLUGIN_CONFIG_DIR="$tmp/config" TEST_FOREGROUND_CWD="$repo"
bash "$plugin_root/open.sh"
joined=$(cat "$TEST_CAPTURE")
! grep -Fq -- 'WORKTRUNK_BIN=' <<<"$joined"
grep -Fxq -- "GIT_BIN=$git_bin" <<<"$joined"

printf 'open tests passed\n'
