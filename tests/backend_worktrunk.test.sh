#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export JQ_BIN FORESTR_BACKEND=worktrunk
JQ_BIN=$(command -v jq)
# shellcheck source=../src/backend.sh
source "$plugin_root/backend.sh"
# shellcheck source=../src/backend_worktrunk.sh
source "$plugin_root/backend_worktrunk.sh"

cat >"$tmp/wt" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$TEST_ARGS"
case " $* " in
  *" list "*) printf '{"schema":2,"items":[{"branch":"topic","worktree":{"path":"/repo/.topic"},"head":{"short_sha":"abc123"},"display":{"symbols":"!↑"}}]}\n' ;;
  *" remove "*) printf '{}\n' ;;
  *) printf '{"path":"/repo/.topic","branch":"topic"}\n' ;;
esac
EOF
chmod +x "$tmp/wt"
export FORESTR_WORKTRUNK_BIN="$tmp/wt" TEST_ARGS="$tmp/args"
args() { tr '\0' '\n' <"$1"; }
request() { "$JQ_BIN" -cn --arg operation "$1" --arg mode "${2:-open}" --argjson force "${3:-false}" \
  '{version:1,operation:$operation,repo_root:"/repo",target:"topic",mode:$mode,force:$force}'; }

result=$(backend_dispatch "$(request open open)")
"$JQ_BIN" -e '.ok and .path == "/repo/.topic" and .branch == "topic"' <<<"$result" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo switch topic --no-cd --format=json' ]]

backend_dispatch "$(request open create)" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo switch --create topic --no-cd --format=json' ]]
backend_dispatch "$(request open force-create)" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo switch --create --clobber topic --no-cd --format=json' ]]
# No hook-disabling flag may be introduced.
! args "$tmp/args" | grep -Eq 'hook|verify'

backend_dispatch "$(request remove open false)" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo remove --foreground --format=json topic' ]]
backend_dispatch "$(request remove open true)" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo remove --foreground --format=json --force --force-delete topic' ]]

result=$(backend_dispatch "$($JQ_BIN -cn \
  '{version:1,operation:"enrich",repo_root:"/repo",collection_timeout_ms:5000}')")
"$JQ_BIN" -e '.ok and .items == [{path:"/repo/.topic",branch:"topic",head:"abc123",symbols:"!↑"}]' <<<"$result" >/dev/null
actual=$(args "$tmp/args" | paste -s -d ' ' -)
[[ $actual == '-C /repo list --format=json --config-set list.json-schema=2 --config-set list.full=false --config-set list.timeout-ms=5000' ]]

printf 'Worktrunk adapter tests passed\n'
