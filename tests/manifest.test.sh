#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
tmp=$(mktemp -d /tmp/forestr-manifest.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
    /usr/bin/git -C "$repo" init -q

cat >"$tmp/fzf" <<'EOF'
#!/usr/bin/env bash
IFS= read -r row
cat >/dev/null
printf 'q\n%s\n' "$row"
EOF
cat >"$tmp/wt" <<'EOF'
#!/usr/bin/env bash
printf '{"items":[{"branch":"main","worktree":{"path":"%s","main":true},"display":{"statusline":"main"}}]}\n' "$TEST_REPO"
EOF
chmod +x "$tmp/fzf" "$tmp/wt"

# Exercise the manifest through Herdr's real loader in an isolated registry so
# schema or platform-field regressions cannot hide behind manual TOML checks.
schema_herdr=${HERDR_SCHEMA_BIN:-$(command -v herdr 2>/dev/null || true)}
[[ -n $schema_herdr && -x $schema_herdr ]] || {
    printf 'manifest test requires Herdr; set HERDR_SCHEMA_BIN to its executable.\n' >&2
    exit 1
}
schema_root="$tmp/herdr-schema"
mkdir -p "$schema_root"/{home,config,data,state,runtime}
chmod 700 "$schema_root/runtime"
schema_env=(
    HOME="$schema_root/home"
    XDG_CONFIG_HOME="$schema_root/config"
    XDG_DATA_HOME="$schema_root/data"
    XDG_STATE_HOME="$schema_root/state"
    XDG_RUNTIME_DIR="$schema_root/runtime"
)
env "${schema_env[@]}" "$schema_herdr" plugin link "$repo_root" --enabled >"$tmp/plugin-link.json"
/usr/bin/jq -e '
  .result.plugin
  | .plugin_id == "ludoroo.forestr"
    and .version == "0.1.0"
    and .platforms == ["linux"]
    and [.actions[].id] == ["open"]
    and [.actions[].contexts] == [["workspace"]]
    and [.panes[].id] == ["manager"]
    and [.panes[].placement] == ["popup"]
' "$tmp/plugin-link.json" >/dev/null
env "${schema_env[@]}" "$schema_herdr" plugin list --json --plugin ludoroo.forestr >"$tmp/plugin-list.json"
/usr/bin/jq -e '.result.plugins | length == 1 and .[0].plugin_id == "ludoroo.forestr"' \
    "$tmp/plugin-list.json" >/dev/null

export TEST_REPO="$repo"
export HERDR_PLUGIN_ROOT="$repo_root"
export HERDR_BIN_PATH=/bin/true
export WORKTRUNK_BIN="$tmp/wt"
export FZF_BIN="$tmp/fzf"
export GIT_BIN=/usr/bin/git
export JQ_BIN=/usr/bin/jq
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false

python3 - <<'PY'
import os
import subprocess
import tomllib

root = os.environ["HERDR_PLUGIN_ROOT"]
with open(f"{root}/herdr-plugin.toml", "rb") as file:
    manifest = tomllib.load(file)
assert manifest["id"] == "ludoroo.forestr"
assert manifest["name"] == "Forestr"
assert manifest["version"] == "0.1.0"
assert manifest["platforms"] == ["linux"]
assert [action["id"] for action in manifest["actions"]] == ["open"]
assert f'{manifest["id"]}.{manifest["actions"][0]["id"]}' == "ludoroo.forestr.open"
assert [pane["id"] for pane in manifest["panes"]] == ["manager"]
actions = {action["id"]: action["command"] for action in manifest["actions"]}
panes = {pane["id"]: pane["command"] for pane in manifest["panes"]}
assert "$HERDR_PLUGIN_ROOT/src/open.sh" in " ".join(actions["open"])
assert "$HERDR_PLUGIN_ROOT/src/manager.sh" in " ".join(panes["manager"])
assert "tab" not in " ".join(panes["manager"])
subprocess.run(panes["manager"], cwd=os.environ["TEST_REPO"], env=os.environ, check=True)
PY

printf 'manifest pane test passed\n'
