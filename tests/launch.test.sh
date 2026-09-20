#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 ))
printf '%s\n' "$FORESTR_BASH_BIN" "$1"
EOF

FORESTR_BASH_BIN="$BASH" sh "$repo_root/src/launch.sh" "$tmp/target.sh" launched >"$tmp/output"
[[ $(sed -n '1p' "$tmp/output") == "$BASH" ]]
[[ $(sed -n '2p' "$tmp/output") == launched ]]

env -u FORESTR_BASH_BIN -u BASH_BIN sh "$repo_root/src/launch.sh" "$tmp/target.sh" discovered >"$tmp/discovered"
[[ -x $(sed -n '1p' "$tmp/discovered") ]]
[[ $(sed -n '2p' "$tmp/discovered") == discovered ]]

if FORESTR_BASH_BIN="$tmp/missing" sh "$repo_root/src/launch.sh" "$tmp/target.sh" launched \
    >"$tmp/invalid-output" 2>"$tmp/invalid-error"; then
    printf 'invalid Bash override was accepted\n' >&2
    exit 1
fi
grep -Fq 'Bash override must be an executable Bash 4 or newer' "$tmp/invalid-error"

printf 'launcher tests passed\n'
