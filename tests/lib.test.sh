#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
# shellcheck source=../src/lib.sh
source "$plugin_root/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"result":{"panes":[{"pane_id":"w5:p1","cwd":"/home/coder","foreground_cwd":"/home/coder/repo"}]}}
JSON
EOF
chmod +x "$tmp/herdr"

actual=$(forestr_foreground_cwd "$tmp/herdr" 'w5:p1' 'w5')
[[ $actual == /home/coder/repo ]] || {
    printf 'expected foreground cwd, got %s\n' "$actual" >&2
    exit 1
}

mkdir -p "$tmp/config"
cat >"$tmp/config/config.toml" <<'EOF'
popup_width = "72%"
popup_height = 24
EOF
HERDR_PLUGIN_CONFIG_DIR="$tmp/config"
[[ $(forestr_popup_dimension popup_width '90%') == '72%' ]]
[[ $(forestr_popup_dimension popup_height '85%') == '24' ]]
[[ $(forestr_create_scope local) == local ]]
[[ $(forestr_create_scope both) == both ]]
# Create candidates default to local when unset or unsupported.
[[ $(forestr_create_scope config) == local ]]
[[ $(forestr_create_scope unsupported) == local ]]
printf 'create_scope = "remote"\n' >>"$tmp/config/config.toml"
forestr_reset_config_cache
[[ $(forestr_create_scope config) == remote ]]

# Enrichment controls are bounded and reject malformed values.
[[ $(forestr_config_bool enrich_backend true) == true ]]
[[ $(forestr_config_positive_integer worktrunk_enrichment_timeout_ms 10000) == 10000 ]]
[[ $(forestr_config_positive_integer worktrunk_enrichment_collection_timeout_ms 5000) == 5000 ]]
[[ $(forestr_config_concurrency worktrunk_enrichment_concurrency 2) == 2 ]]
printf '%s\n' 'enrich_backend = false' 'worktrunk_enrichment_timeout_ms = 900' \
    'worktrunk_enrichment_collection_timeout_ms = 400' 'worktrunk_enrichment_concurrency = 1' >>"$tmp/config/config.toml"
forestr_reset_config_cache
[[ $(forestr_config_bool enrich_backend true) == false ]]
[[ $(forestr_config_positive_integer worktrunk_enrichment_timeout_ms 10000) == 900 ]]
[[ $(forestr_config_positive_integer worktrunk_enrichment_collection_timeout_ms 5000) == 400 ]]
[[ $(forestr_config_concurrency worktrunk_enrichment_concurrency 2) == 1 ]]
printf '%s\n' 'worktrunk_enrichment_timeout_ms = 0' 'worktrunk_enrichment_collection_timeout_ms = nope' \
    'worktrunk_enrichment_concurrency = 9' >>"$tmp/config/config.toml"
forestr_reset_config_cache
[[ $(forestr_config_positive_integer worktrunk_enrichment_timeout_ms 10000) == 10000 ]]
[[ $(forestr_config_positive_integer worktrunk_enrichment_collection_timeout_ms 5000) == 5000 ]]
[[ $(forestr_config_concurrency worktrunk_enrichment_concurrency 2) == 2 ]]

# A manager-style parent preload makes all subsequent config access inherit the
# same safely parsed map instead of spawning sed once per key.
cat >"$tmp/sed" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >>"$TEST_SED_CALLS"
exec /usr/bin/sed "$@"
EOF
chmod +x "$tmp/sed"
export TEST_SED_CALLS="$tmp/sed-calls"
old_path=$PATH; PATH="$tmp:$PATH"
forestr_reset_config_cache
forestr_load_config
forestr_config_bool enrich_backend true >/dev/null
forestr_config_positive_integer worktrunk_enrichment_timeout_ms 10000 >/dev/null
forestr_key key_down j >/dev/null
[[ $(wc -l <"$TEST_SED_CALLS") -eq 1 ]]
PATH=$old_path

[[ $(forestr_key key_down j) == j ]]
# Wizard navigation has backend-neutral configurable defaults.
[[ $(forestr_key key_new n) == n ]]
[[ $(forestr_key key_back h) == h ]]
[[ $(forestr_key key_local l) == l ]]
[[ $(forestr_key key_remote r) == r ]]
[[ $(forestr_key key_both b) == b ]]
# Uppercase single characters are valid fzf keys for scopes and force actions.
[[ $(forestr_key key_force_create C) == C ]]
[[ $(forestr_key key_force_remove D) == D ]]
printf 'key_down = "ctrl-@"\n' >>"$tmp/config/config.toml"
forestr_reset_config_cache
if forestr_key key_down j >/dev/null 2>&1; then
    printf 'invalid fzf key was accepted\n' >&2
    exit 1
fi

cat >"$tmp/tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/tool"
[[ $(forestr_find_executable tool "$tmp/tool") == "$tmp/tool" ]]

printf 'lib tests passed\n'
