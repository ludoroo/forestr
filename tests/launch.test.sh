#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
(( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) ))
printf '%s\n' "$FORESTR_BASH_BIN" "$1"
EOF

# Explicit overrides accept Bash 3.2, propagate their exact path, and keep
# FORESTR_BASH_BIN precedence over BASH_BIN.
FORESTR_BASH_BIN="$BASH" sh "$repo_root/src/launch.sh" "$tmp/target.sh" launched >"$tmp/output"
[[ $(sed -n '1p' "$tmp/output") == "$BASH" ]]
[[ $(sed -n '2p' "$tmp/output") == launched ]]
ln -s "$BASH" "$tmp/alternate-bash"
BASH_BIN="$tmp/alternate-bash" sh "$repo_root/src/launch.sh" "$tmp/target.sh" bash-bin >"$tmp/bash-bin"
[[ $(sed -n '1p' "$tmp/bash-bin") == "$tmp/alternate-bash" ]]
FORESTR_BASH_BIN="$BASH" BASH_BIN="$tmp/missing" \
    sh "$repo_root/src/launch.sh" "$tmp/target.sh" precedence >"$tmp/precedence"
[[ $(sed -n '1p' "$tmp/precedence") == "$BASH" ]]

# Automatic discovery prefers a supported Bash already available on PATH.
expected_discovered_bash=$(command -v bash)
env -u FORESTR_BASH_BIN -u BASH_BIN sh "$repo_root/src/launch.sh" \
    "$tmp/target.sh" discovered >"$tmp/discovered"
[[ $(sed -n '1p' "$tmp/discovered") == "$expected_discovered_bash" ]]
[[ $(sed -n '2p' "$tmp/discovered") == discovered ]]

cat >"$tmp/not-bash" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/not-bash"
for invalid in "$tmp/missing" "$tmp/not-bash"; do
    if FORESTR_BASH_BIN="$invalid" BASH_BIN="$BASH" \
        sh "$repo_root/src/launch.sh" "$tmp/target.sh" launched \
        >"$tmp/invalid-output" 2>"$tmp/invalid-error"; then
        printf 'invalid Bash override was accepted: %s\n' "$invalid" >&2
        exit 1
    fi
    grep -Fq 'Bash override must be an executable Bash 3.2 or newer' "$tmp/invalid-error"
done
if env -u FORESTR_BASH_BIN BASH_BIN="$tmp/not-bash" \
    sh "$repo_root/src/launch.sh" "$tmp/target.sh" launched \
    >"$tmp/invalid-output" 2>"$tmp/invalid-error"; then
    printf 'invalid BASH_BIN override was accepted\n' >&2
    exit 1
fi
grep -Fq 'Bash override must be an executable Bash 3.2 or newer' "$tmp/invalid-error"

printf 'launcher tests passed\n'
