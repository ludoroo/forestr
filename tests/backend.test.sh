#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export JQ_BIN
JQ_BIN=$(command -v jq)
# shellcheck source=../src/lib.sh
source "$plugin_root/lib.sh"
# shellcheck source=../src/backend.sh
source "$plugin_root/backend.sh"

mkdir -p "$tmp/config" "$tmp/bin"
export HERDR_PLUGIN_CONFIG_DIR="$tmp/config"
write_config() { printf 'backend = "%s"\n' "$1" >"$tmp/config/config.toml"; forestr_reset_config_cache; }

# All documented values parse, while unknown values fail at the config seam.
for value in auto worktrunk git; do
    write_config "$value"
    [[ $(backend_configured_name) == "$value" ]]
done
write_config invalid
if backend_configured_name >"$tmp/out" 2>"$tmp/error"; then
    printf 'invalid backend was accepted\n' >&2; exit 1
fi
grep -Fq 'Invalid backend: invalid' "$tmp/error"

# Auto prefers Worktrunk when it is available.
cat >"$tmp/bin/wt" <<'EOF_WT'
#!/usr/bin/env bash
exit 0
EOF_WT
chmod +x "$tmp/bin/wt"
write_config auto
backend_resolve "$tmp/bin/wt"
[[ $FORESTR_BACKEND == worktrunk ]]
"$JQ_BIN" -e '.version == 1 and .backend == "worktrunk"
  and .operations.open and .operations.create and .operations.remove and .operations.enrich
  and .dependencies == {wt:true}' <<<"$(backend_capabilities)" >/dev/null

write_config worktrunk
if backend_resolve "$tmp/missing-wt" >"$tmp/out" 2>"$tmp/error"; then
    printf 'explicit Worktrunk resolved without wt\n' >&2; exit 1
fi
grep -Fq 'backend "worktrunk" requires wt' "$tmp/error"

write_config auto
find_executable_definition=$(declare -f forestr_find_executable)
forestr_find_executable() { return 1; }
backend_resolve
[[ $FORESTR_BACKEND == git && -z $FORESTR_WORKTRUNK_BIN ]]
"$JQ_BIN" -e '.backend == "git" and .operations.open and (.operations.enrich|not)
  and .dependencies == {wt:false}' <<<"$(backend_capabilities)" >/dev/null
eval "$find_executable_definition"

# Explicit Git does not even ask executable resolution for wt.
write_config git
forestr_find_executable() { printf 'unexpected executable lookup: %s\n' "$1" >&2; return 99; }
backend_resolve "$tmp/missing-wt"
[[ $FORESTR_BACKEND == git && -z $FORESTR_WORKTRUNK_BIN ]]
eval "$find_executable_definition"

# Results crossing the adapter boundary are schema checked.
FORESTR_BACKEND=malformed
backend_adapter_dispatch() { printf '{"version":1,"ok":true,"operation":"open"}\n'; }
request='{"version":1,"operation":"open","repo_root":"/repo","target":"main","mode":"open"}'
if backend_dispatch "$request" >"$tmp/out" 2>"$tmp/error"; then
    printf 'malformed adapter result was accepted\n' >&2; exit 1
fi
grep -Fq 'invalid open result' "$tmp/error"

printf 'backend contract tests passed\n'
