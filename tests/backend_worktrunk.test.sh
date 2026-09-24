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
  *" list "*)
    if [[ ${TEST_UNRESOLVED:-} == true ]]; then
      printf '{"schema":2,"items":[{"branch":"topic","worktree":{"path":"/repo/.topic","operation":null,"changes":null},"head":{"short_sha":"abc123"},"default_branch":{"ahead":null,"behind":null,"orphan":null,"integration":null,"merge_conflicts":null},"upstream":null,"marker":null,"display":{}}]}\n'
    elif [[ ${TEST_PRIORITY:-} == true ]]; then
      printf '{"schema":2,"items":[
        {"branch":"conflict","worktree":{"path":"/repo/.conflict","locked":{},"operation":"rebase","changes":{"conflicted":true}},"head":{},"display":{"state":"ahead"}},
        {"branch":"pending","worktree":{"path":"/repo/.pending","locked":{},"operation":null,"changes":{"conflicted":false}},"head":{},"display":{"state":"ahead"}},
        {"branch":"operation","worktree":{"path":"/repo/.operation","locked":{},"operation":"rebase","changes":{"conflicted":false}},"head":{},"display":{"state":"ahead"}},
        {"branch":"quiet","worktree":{"path":"/repo/.quiet","changes":{"conflicted":false}},"head":{},"default_branch":{"ahead":0,"behind":0,"orphan":false,"merge_conflicts":false},"display":{}},
        {"branch":"prunable","worktree":{"path":"/repo/.prunable","prunable":{"reason":"missing"},"operation":null,"changes":null},"head":{},"default_branch":{"ahead":null,"behind":null,"orphan":null,"integration":null,"merge_conflicts":null},"upstream":null,"marker":null,"display":{}}
      ]}\n'
    else
      printf '{"schema":2,"items":[{"branch":"topic","worktree":{"path":"/repo/.topic","branch_mismatch":true,"changes":{"staged":false,"modified":true,"untracked":true,"conflicted":false}},"head":{"short_sha":"abc123"},"display":{"state":"ahead","symbols":"!?⚑↑💬"},"upstream":{"ahead":2,"behind":0},"marker":"💬"}]}\n'
    fi
    ;;
  *" remove "*)
    [[ ${TEST_REMOVE_FAIL:-false} != true ]] || { printf 'safety check failed\n' >&2; exit 1; }
    if [[ ${TEST_REMOVE_INVALID:-false} == true ]]; then printf '{"accepted":true}\n'; exit; fi
    printf '[{"kind":"worktree","branch":"topic","path":"/repo/.topic","branch_outcome":"%s","branch_checked_out_at":null}]\n' "${TEST_REMOVE_OUTCOME:-deleted}"
    ;;
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

result=$(backend_dispatch "$(request remove open false)")
"$JQ_BIN" -e '.ok and .removed_worktree and .branch_outcome == "deleted" and .warning == ""' <<<"$result" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo remove --foreground --format=json topic' ]]
result=$(backend_dispatch "$(request remove open true)")
"$JQ_BIN" -e '.ok and .removed_worktree' <<<"$result" >/dev/null
[[ $(args "$tmp/args" | paste -s -d ' ' -) == '-C /repo remove --foreground --format=json --force --force-delete topic' ]]

export TEST_REMOVE_OUTCOME=retained_raced
result=$(backend_dispatch "$(request remove open false)")
"$JQ_BIN" -e '.ok and .branch_outcome == "retained_raced"
  and (.warning | contains("changed during removal"))' <<<"$result" >/dev/null
export TEST_REMOVE_OUTCOME=not_attempted
result=$(backend_dispatch "$(request remove open false)")
"$JQ_BIN" -e '.ok and .branch_outcome == "not_applicable"' <<<"$result" >/dev/null
unset TEST_REMOVE_OUTCOME

export TEST_REMOVE_OUTCOME=deferred
result=$(backend_dispatch "$(request remove open false)")
"$JQ_BIN" -e '.ok == false and (.message | contains("incomplete removal result"))' <<<"$result" >/dev/null
unset TEST_REMOVE_OUTCOME
export TEST_REMOVE_INVALID=true
result=$(backend_dispatch "$(request remove open false)")
"$JQ_BIN" -e '.ok == false and (.message | contains("incomplete removal result"))' <<<"$result" >/dev/null
unset TEST_REMOVE_INVALID
export TEST_REMOVE_FAIL=true
result=$(backend_dispatch "$(request remove open false)" 2>"$tmp/remove-stderr")
"$JQ_BIN" -e '.ok == false and (.message | contains("did not remove"))' <<<"$result" >/dev/null
grep -Fq 'safety check failed' "$tmp/remove-stderr"
unset TEST_REMOVE_FAIL

result=$(backend_dispatch "$($JQ_BIN -cn \
  '{version:1,operation:"enrich",repo_root:"/repo",collection_timeout_ms:5000}')")
"$JQ_BIN" -e '.ok and .items == [{path:"/repo/.topic",branch:"topic",head:"abc123",symbols:"!?⚑↑💬",
  status:{staged:false,modified:true,untracked:true,worktree_state:"warning",branch_state:"ahead",
          remote_state:"ahead",marker:"💬"}}]' <<<"$result" >/dev/null
actual=$(args "$tmp/args" | paste -s -d ' ' -)
[[ $actual == '-C /repo list --format=json --config-set list.json-schema=2 --config-set list.full=false --config-set list.timeout-ms=5000' ]]

export TEST_UNRESOLVED=true
result=$(backend_dispatch "$($JQ_BIN -cn \
  '{version:1,operation:"enrich",repo_root:"/repo",collection_timeout_ms:5000}')")
unset TEST_UNRESOLVED
"$JQ_BIN" -e '.ok and .items[0].status == {
  staged:null,modified:null,untracked:null,worktree_state:"unresolved",branch_state:"unresolved",
  remote_state:"unresolved",marker:null}' <<<"$result" >/dev/null

export TEST_PRIORITY=true
result=$(backend_dispatch "$($JQ_BIN -cn \
  '{version:1,operation:"enrich",repo_root:"/repo",collection_timeout_ms:5000}')")
unset TEST_PRIORITY
"$JQ_BIN" -e '([.items[].status.worktree_state] == ["conflicted","unresolved","operation","","prunable"])
  and (.items[-2].status.branch_state == "")
  and (.items[-1].status == {staged:false,modified:false,untracked:false,worktree_state:"prunable",
      branch_state:"",remote_state:"",marker:""})
  and (all(.items[]; .status.remote_state == "" and .status.marker == ""))' \
  <<<"$result" >/dev/null

printf 'Worktrunk adapter tests passed\n'
