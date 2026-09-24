#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
export FORESTR_REMOVAL_STATE_DIR="$tmp/removal-state"
producer_pids_for_test() {
    local pid state args
    while read -r pid state args; do
        [[ $state == *Z* ]] && continue
        [[ $args == *'manager.sh __produce '*"$tmp"* ]] || continue
        printf '%s\n' "$pid"
    done < <(ps -ww -axo pid=,state=,command=)
}
signal_test_producer() {
    local signal=$1 pid=$2 pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null || true)
    pgid=${pgid//[[:space:]]/}
    if [[ -n $pgid && $pgid == "$pid" ]]; then
        kill "-$signal" -- "-$pid" 2>/dev/null || kill "-$signal" "$pid" 2>/dev/null || true
    else
        kill "-$signal" "$pid" 2>/dev/null || true
    fi
}
cleanup_test() {
    local pid found empty_samples=0
    set +e
    for _ in {1..100}; do
        found=false
        while IFS= read -r pid; do
            [[ -n $pid ]] || continue
            found=true
            signal_test_producer TERM "$pid"
        done < <(producer_pids_for_test)
        if $found; then
            empty_samples=0
        else
            empty_samples=$((empty_samples + 1))
            (( empty_samples < 5 )) || break
        fi
        sleep 0.01
    done
    while IFS= read -r pid; do
        [[ -z $pid ]] || signal_test_producer KILL "$pid"
    done < <(producer_pids_for_test)
    rm -rf "$tmp"
}
trap cleanup_test EXIT
export JQ_BIN FORESTR_GIT_BIN=/usr/bin/git
JQ_BIN=$(command -v jq)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
# shellcheck source=../src/backend.sh
source "$plugin_root/backend.sh"
# shellcheck source=../src/backend_git.sh
source "$plugin_root/backend_git.sh"
backend_git_resolve

fail() { printf 'backend_git.test.sh: %s\n' "$*" >&2; exit 1; }
wait_for_manager_refresh() {
    local state_dir=$1 generation
    generation=$(cat "$state_dir/generation")
    for _ in {1..500}; do
        if [[ -e $state_dir/completed.$generation && ! -e $state_dir/producer.pid ]]; then
            return 0
        fi
        sleep 0.02
    done
    fail "manager refresh generation $generation did not finish"
}
new_repo() {
    local repo=$1
    mkdir -p "$repo"
    "$FORESTR_GIT_BIN" -C "$repo" init -q -b main
    "$FORESTR_GIT_BIN" -C "$repo" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m initial
}
open_request() {
    local repo=$1 target=$2 mode=$3 intent=$4 path=${5:-} full_ref=${6:-} remote=${7:-} create_base=${8:-}
    "$JQ_BIN" -cn --arg repo "$repo" --arg target "$target" --arg mode "$mode" --arg intent "$intent" \
        --arg path "$path" --arg full_ref "$full_ref" --arg remote "$remote" --arg create_base "$create_base" \
        '{version:1,operation:"open",repo_root:$repo,target:$target,mode:$mode,intent:$intent,
          path:$path,full_ref:$full_ref,remote:$remote,create_base:$create_base}'
}
remove_request() {
    "$JQ_BIN" -cn --arg repo "$1" --arg target "$2" --arg path "$3" --argjson force "$4" \
        '{version:1,operation:"remove",repo_root:$repo,target:$target,path:$path,force:$force}'
}
dispatch() { backend_dispatch "$1"; }
assert_ok() { "$JQ_BIN" -e '.ok == true' >/dev/null <<<"$1" || fail "expected success: $1"; }
assert_fail() { "$JQ_BIN" -e '.ok == false and (.message|length>0)' >/dev/null <<<"$1" || fail "expected failure: $1"; }

# Capability contract is complete and requires no optional backend executable.
"$JQ_BIN" -e '.backend == "git" and .operations.open and .operations.create and .operations.remove
  and (.operations.enrich|not) and (.features.create_clobber|not) and .features.remove_stale
  and (.features.relocate|not) and .dependencies == {wt:false}' \
  <<<"$(backend_capabilities)" >/dev/null

# Worktrunk sanitize fixtures: Git-valid branch slashes become hyphens and all
# other valid bytes are retained. Collisions are intentionally not hashed.
[[ $(backend_sanitize_branch 'feature/oauth.v2') == 'feature-oauth.v2' ]]
[[ $(backend_sanitize_branch 'release_2026-09') == 'release_2026-09' ]]
[[ $(backend_sanitize_branch 'foo/bar/baz') == 'foo-bar-baz' ]]
[[ $(backend_sanitize_branch 'foo-bar') == 'foo-bar' ]]

repo="$tmp/project"
new_repo "$repo"
base=$("$FORESTR_GIT_BIN" -C "$repo" rev-parse HEAD)

# Existing worktrees are revalidated and reused without a second add. Both
# canonical manager rows and the early active/Herdr seed payload shape identify
# these rows by checkout path rather than by their eventual branch label.
existing="$tmp/existing checkout"
"$FORESTR_GIT_BIN" -C "$repo" worktree add -q -b existing "$existing"
result=$(dispatch "$(open_request "$repo" existing open existing_worktree "$existing")")
assert_ok "$result"
[[ $("$JQ_BIN" -r .path <<<"$result") == "$existing" ]]
result=$(dispatch "$(open_request "$repo" "$existing" open existing_worktree "$existing")")
assert_ok "$result" # active_seed_row payload shape
seeded="$tmp/herdr seeded checkout"
"$FORESTR_GIT_BIN" -C "$repo" worktree add -q -b seeded "$seeded"
result=$(dispatch "$(open_request "$repo" "$seeded" open existing_worktree "$seeded")")
assert_ok "$result" # herdr_seed_rows payload shape
[[ $("$JQ_BIN" -r .branch <<<"$result") == seeded ]]
result=$(dispatch "$(open_request "$repo" unrelated open existing_worktree "$seeded")")
assert_fail "$result"
[[ $("$FORESTR_GIT_BIN" -C "$repo" worktree list --porcelain | grep -c '^worktree ') -eq 3 ]]

# Exact local materialization uses one attached worktree-add command. A tag with
# the same short name cannot make Git detach or select any ref except the exact
# prevalidated refs/heads branch.
cat >"$tmp/git-record-add" <<'EOF_GIT_RECORD'
#!/usr/bin/env bash
if [[ " $* " == *' worktree add '* ]]; then printf '%s\0' "$@" >"$TEST_GIT_ADD_ARGS"; fi
exec /usr/bin/git "$@"
EOF_GIT_RECORD
chmod +x "$tmp/git-record-add"
"$FORESTR_GIT_BIN" -C "$repo" branch local/topic main
"$FORESTR_GIT_BIN" -C "$repo" tag local/topic main
local_path="$tmp/.project-local-topic"
export TEST_GIT_ADD_ARGS="$tmp/git-add-args"
FORESTR_GIT_BIN="$tmp/git-record-add"
result=$(dispatch "$(open_request "$repo" 'local/topic' open local_branch)")
FORESTR_GIT_BIN=/usr/bin/git
assert_ok "$result"
[[ $("$JQ_BIN" -r .path <<<"$result") == "$local_path" && -d $local_path ]]
[[ $("$FORESTR_GIT_BIN" -C "$local_path" symbolic-ref -q HEAD) == refs/heads/local/topic ]]
[[ $(tr '\0' '\n' <"$tmp/git-add-args" | paste -s -d ' ' -) == "-C $repo worktree add --no-guess-remote $local_path local/topic" ]]

# If another checkout wins after prevalidation, Git rejects the one add command;
# the winning checkout is retained and no detached manager checkout is created.
"$FORESTR_GIT_BIN" -C "$repo" branch race/winner main
cat >"$tmp/git-race" <<'EOF_GIT_RACE'
#!/usr/bin/env bash
if [[ " $* " == *' worktree add --no-guess-remote '* && ! -e $TEST_RACE_ONCE ]]; then
    : >"$TEST_RACE_ONCE"
    /usr/bin/git -C "$TEST_RACE_REPO" worktree add -q "$TEST_RACE_PATH" race/winner
fi
exec /usr/bin/git "$@"
EOF_GIT_RACE
chmod +x "$tmp/git-race"
race_winner="$tmp/race-winner"
export TEST_RACE_ONCE="$tmp/race-once" TEST_RACE_REPO="$repo" TEST_RACE_PATH="$race_winner"
FORESTR_GIT_BIN="$tmp/git-race"
result=$(dispatch "$(open_request "$repo" race/winner open local_branch)")
FORESTR_GIT_BIN=/usr/bin/git
assert_fail "$result"
[[ $("$FORESTR_GIT_BIN" -C "$race_winner" symbolic-ref -q HEAD) == refs/heads/race/winner ]]
[[ ! -e $tmp/.project-race-winner ]]

# An unexpected post-add identity change is reported without destructive
# rollback: files and hooks may already have run, so the checkout is retained.
"$FORESTR_GIT_BIN" -C "$repo" branch verify/retained main
cat >"$tmp/git-post-verify" <<'EOF_GIT_VERIFY'
#!/usr/bin/env bash
/usr/bin/git "$@"
status=$?
if [[ $status -eq 0 && " $* " == *' worktree add --no-guess-remote '* ]]; then
    path=${@: -2:1}
    /usr/bin/git -C "$path" symbolic-ref HEAD refs/heads/main
fi
exit "$status"
EOF_GIT_VERIFY
chmod +x "$tmp/git-post-verify"
FORESTR_GIT_BIN="$tmp/git-post-verify"
result=$(dispatch "$(open_request "$repo" verify/retained open local_branch)")
FORESTR_GIT_BIN=/usr/bin/git
assert_fail "$result"
verify_path="$tmp/.project-verify-retained"
[[ -d $verify_path ]]
grep -Fq 'checkout retained for inspection' <<<"$("$JQ_BIN" -r .message <<<"$result")"
"$FORESTR_GIT_BIN" -C "$repo" worktree remove --force "$verify_path"

# Typed branches use an explicit base when configured and otherwise detect the
# symbolic origin HEAD. Git creation is deliberately --no-track.
"$FORESTR_GIT_BIN" -C "$repo" branch explicit-base main
result=$(dispatch "$(open_request "$repo" typed/explicit create create_branch '' '' '' refs/heads/explicit-base)")
assert_ok "$result"
explicit_path=$("$JQ_BIN" -r .path <<<"$result")
[[ $("$FORESTR_GIT_BIN" -C "$explicit_path" rev-parse HEAD) == "$base" ]]
! "$FORESTR_GIT_BIN" -C "$explicit_path" rev-parse --verify '@{upstream}' >/dev/null 2>&1
"$FORESTR_GIT_BIN" -C "$repo" update-ref refs/remotes/origin/default-base "$base"
"$FORESTR_GIT_BIN" -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/default-base
result=$(dispatch "$(open_request "$repo" typed/default create create_branch)")
assert_ok "$result"
default_path=$("$JQ_BIN" -r .path <<<"$result")
[[ $("$FORESTR_GIT_BIN" -C "$default_path" rev-parse HEAD) == "$base" ]]
! "$FORESTR_GIT_BIN" -C "$default_path" rev-parse --verify '@{upstream}' >/dev/null 2>&1

# Typed creation revalidates the exact registered branch after add and retains
# an unexpectedly changed checkout for inspection rather than rolling it back.
cat >"$tmp/git-post-create-verify" <<'EOF_GIT_CREATE_VERIFY'
#!/usr/bin/env bash
/usr/bin/git "$@"
status=$?
if [[ $status -eq 0 && " $* " == *' worktree add --no-track -b '* ]]; then
    path=${@: -2:1}
    /usr/bin/git -C "$path" symbolic-ref HEAD refs/heads/main
fi
exit "$status"
EOF_GIT_CREATE_VERIFY
chmod +x "$tmp/git-post-create-verify"
FORESTR_GIT_BIN="$tmp/git-post-create-verify"
result=$(dispatch "$(open_request "$repo" verify/typed create create_branch)")
FORESTR_GIT_BIN=/usr/bin/git
assert_fail "$result"
typed_verify_path="$tmp/.project-verify-typed"
[[ -d $typed_verify_path ]]
grep -Fq 'checkout retained for inspection' <<<"$("$JQ_BIN" -r .message <<<"$result")"
"$FORESTR_GIT_BIN" -C "$repo" worktree remove --force "$typed_verify_path"
"$FORESTR_GIT_BIN" -C "$repo" branch -D verify/typed >/dev/null

# Remote identity stays exact when two configured remotes expose the same branch.
"$FORESTR_GIT_BIN" -C "$repo" config remote.origin.url "$tmp/origin.git"
"$FORESTR_GIT_BIN" -C "$repo" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
"$FORESTR_GIT_BIN" -C "$repo" config remote.upstream.url "$tmp/upstream.git"
"$FORESTR_GIT_BIN" -C "$repo" config --add remote.upstream.fetch '+refs/heads/*:refs/remotes/upstream/*'
"$FORESTR_GIT_BIN" -C "$repo" update-ref refs/remotes/origin/shared "$base"
"$FORESTR_GIT_BIN" -C "$repo" update-ref refs/remotes/upstream/shared "$base"
result=$(dispatch "$(open_request "$repo" upstream/shared open remote_branch '' refs/remotes/upstream/shared upstream)")
assert_ok "$result"
remote_path=$("$JQ_BIN" -r .path <<<"$result")
[[ $("$FORESTR_GIT_BIN" -C "$remote_path" rev-parse --symbolic-full-name '@{upstream}') == refs/remotes/upstream/shared ]]
result=$(dispatch "$(open_request "$repo" origin/HEAD open remote_branch '' refs/remotes/origin/HEAD origin)")
assert_fail "$result"

# Remote creation also revalidates the registered branch as well as its exact
# upstream after add, retaining an unexpectedly changed checkout for inspection.
"$FORESTR_GIT_BIN" -C "$repo" update-ref refs/remotes/upstream/verify/remote "$base"
cat >"$tmp/git-post-remote-verify" <<'EOF_GIT_REMOTE_VERIFY'
#!/usr/bin/env bash
/usr/bin/git "$@"
status=$?
if [[ $status -eq 0 && " $* " == *' worktree add --track -b '* ]]; then
    path=${@: -2:1}
    /usr/bin/git -C "$path" symbolic-ref HEAD refs/heads/main
fi
exit "$status"
EOF_GIT_REMOTE_VERIFY
chmod +x "$tmp/git-post-remote-verify"
FORESTR_GIT_BIN="$tmp/git-post-remote-verify"
result=$(dispatch "$(open_request "$repo" upstream/verify/remote open remote_branch '' refs/remotes/upstream/verify/remote upstream)")
FORESTR_GIT_BIN=/usr/bin/git
assert_fail "$result"
remote_verify_path="$tmp/.project-verify-remote"
[[ -d $remote_verify_path ]]
grep -Fq 'checkout retained for inspection' <<<"$("$JQ_BIN" -r .message <<<"$result")"
"$FORESTR_GIT_BIN" -C "$repo" worktree remove --force "$remote_verify_path"
"$FORESTR_GIT_BIN" -C "$repo" branch -D verify/remote >/dev/null

# Invalid/existing refs and force-create fail before any path mutation.
before=$("$FORESTR_GIT_BIN" -C "$repo" worktree list --porcelain | grep -c '^worktree ')
result=$(dispatch "$(open_request "$repo" 'bad..branch' create create_branch)"); assert_fail "$result"
result=$(dispatch "$(open_request "$repo" main create create_branch)"); assert_fail "$result"
result=$(dispatch "$(open_request "$repo" no/base create create_branch '' '' '' refs/heads/missing-base)"); assert_fail "$result"
[[ ! -e $tmp/.project-no-base ]] && ! "$FORESTR_GIT_BIN" -C "$repo" show-ref --verify --quiet refs/heads/no/base
result=$(dispatch "$(open_request "$repo" forced/new force-create create_branch)"); assert_fail "$result"
[[ $("$FORESTR_GIT_BIN" -C "$repo" worktree list --porcelain | grep -c '^worktree ') -eq $before ]]
[[ ! -e $tmp/.project-forced-new && ! -L $tmp/.project-forced-new ]]

# Sanitization collision and every filesystem entry kind are non-destructive.
"$FORESTR_GIT_BIN" -C "$repo" branch collision/path main
"$FORESTR_GIT_BIN" -C "$repo" branch collision-path main
result=$(dispatch "$(open_request "$repo" collision/path open local_branch)"); assert_ok "$result"
result=$(dispatch "$(open_request "$repo" collision-path open local_branch)"); assert_fail "$result"
grep -Fq 'collision' <<<"$("$JQ_BIN" -r .message <<<"$result")"
[[ $("$FORESTR_GIT_BIN" -C "$tmp/.project-collision-path" symbolic-ref --short HEAD) == collision/path ]]
long_branch=$(printf 'x%.0s' {1..250})
"$FORESTR_GIT_BIN" -C "$repo" branch "$long_branch" main
result=$(dispatch "$(open_request "$repo" "$long_branch" open local_branch)"); assert_fail "$result"
grep -Fq 'filesystem limit' <<<"$("$JQ_BIN" -r .message <<<"$result")"
for kind in file dir symlink broken; do
    branch="obstruction/$kind"
    path="$tmp/.project-obstruction-$kind"
    "$FORESTR_GIT_BIN" -C "$repo" branch "$branch" main
    case $kind in
        file) : >"$path" ;;
        dir) mkdir "$path" ;;
        symlink) ln -s "$repo" "$path" ;;
        broken) ln -s "$tmp/missing" "$path" ;;
    esac
    result=$(dispatch "$(open_request "$repo" "$branch" open local_branch)"); assert_fail "$result"
    [[ -e $path || -L $path ]] || fail "$kind obstruction was mutated"
done

# Separate repositories keep removal cases independent.
remove_repo="$tmp/removals"
new_repo "$remove_repo"
# Dirty safe removal is refused by Git.
dirty="$tmp/removals-dirty"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b dirty "$dirty"
printf dirty >"$dirty/untracked"
result=$(dispatch "$(remove_request "$remove_repo" dirty "$dirty" false)"); assert_fail "$result"
[[ -d $dirty ]] && "$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/dirty

# A clean merged branch is removed with its worktree. Early active seed rows
# carry the selected checkout path as both target and path.
merged="$tmp/removals-merged"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b merged "$merged"
result=$(dispatch "$(remove_request "$remove_repo" "$merged" "$merged" false)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and .branch_outcome == "deleted" and .warning == ""' <<<"$result" >/dev/null
[[ ! -e $merged ]] && ! "$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/merged

# Herdr seed rows use the same path identity and still reject unrelated targets.
seed_remove="$tmp/removals-herdr-seed"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b seed-remove "$seed_remove"
result=$(dispatch "$(remove_request "$remove_repo" unrelated "$seed_remove" false)"); assert_fail "$result"
[[ -d $seed_remove ]]
result=$(dispatch "$(remove_request "$remove_repo" "$seed_remove" "$seed_remove" false)"); assert_ok "$result"
[[ ! -e $seed_remove ]] && ! "$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/seed-remove

# Removal remains functional when the selected linked checkout is also the
# repository path supplied by the manager (source-worktree lifecycle).
source_link="$tmp/removals-source"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b source-link "$source_link"
result=$(dispatch "$(remove_request "$source_link" source-link "$source_link" false)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and .branch_outcome == "deleted"' <<<"$result" >/dev/null
[[ ! -e $source_link ]]

# Successful worktree cleanup remains success when -d retains an unmerged branch.
unmerged="$tmp/removals-unmerged"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b unmerged "$unmerged"
"$FORESTR_GIT_BIN" -C "$unmerged" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m unmerged
result=$(dispatch "$(remove_request "$remove_repo" unmerged "$unmerged" false)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and .branch_outcome == "retained_unmerged" and (.warning|length>0)' <<<"$result" >/dev/null
[[ ! -e $unmerged ]] && "$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/unmerged

# Force removes dirty content and deletes an unmerged branch.
forced="$tmp/removals-forced"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b forced "$forced"
"$FORESTR_GIT_BIN" -C "$forced" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m forced
printf dirty >"$forced/untracked"
result=$(dispatch "$(remove_request "$remove_repo" forced "$forced" true)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and .branch_outcome == "deleted"' <<<"$result" >/dev/null
[[ ! -e $forced ]] && ! "$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/forced

# Detached removal skips branch deletion.
detached="$tmp/removals-detached"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q --detach "$detached" HEAD
result=$(dispatch "$(remove_request "$remove_repo" "$detached" "$detached" false)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and .branch_outcome == "not_applicable"' <<<"$result" >/dev/null

# Primary, unregistered, and wrong-repository selections are rejected.
result=$(dispatch "$(remove_request "$remove_repo" main "$remove_repo" true)"); assert_fail "$result"
result=$(dispatch "$(remove_request "$remove_repo" nowhere "$tmp/not-registered" true)"); assert_fail "$result"
other_repo="$tmp/other"; new_repo "$other_repo"
wrong="$tmp/other-linked"; "$FORESTR_GIT_BIN" -C "$other_repo" worktree add -q -b other "$wrong"
result=$(dispatch "$(open_request "$remove_repo" other open existing_worktree "$wrong")"); assert_fail "$result"
result=$(dispatch "$(remove_request "$remove_repo" other "$wrong" true)"); assert_fail "$result"
[[ -d $wrong ]]

# Installed Git supports precise path-specific cleanup for prunable metadata;
# no repository-wide prune is used. Safe removal prunes metadata but uses -d,
# retaining unmerged history; force alone upgrades branch deletion to -D.
stale_safe="$tmp/removals-stale-safe"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b stale-safe "$stale_safe"
"$FORESTR_GIT_BIN" -C "$stale_safe" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m stale-safe
stale_safe_commit=$("$FORESTR_GIT_BIN" -C "$stale_safe" rev-parse HEAD)
rm -rf "$stale_safe"
result=$(dispatch "$(remove_request "$remove_repo" "$stale_safe" "$stale_safe" false)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and (.branch_outcome == "retained_unmerged" or .branch_outcome == "retained_failed")' <<<"$result" >/dev/null
[[ $("$FORESTR_GIT_BIN" -C "$remove_repo" rev-parse refs/heads/stale-safe) == "$stale_safe_commit" ]]
! "$FORESTR_GIT_BIN" -C "$remove_repo" worktree list --porcelain | grep -Fq "$stale_safe"

stale="$tmp/removals-stale"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b stale "$stale"
"$FORESTR_GIT_BIN" -C "$stale" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m stale-force
rm -rf "$stale"
result=$(dispatch "$(remove_request "$remove_repo" "$stale" "$stale" true)"); assert_ok "$result"
"$JQ_BIN" -e '.removed_worktree and .branch_outcome == "deleted"' <<<"$result" >/dev/null
! "$FORESTR_GIT_BIN" -C "$remove_repo" worktree list --porcelain | grep -Fq "$stale"
! "$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/stale

# Manager capability behavior is backend-driven: explicit Git does not invoke
# wt, labels the popup, and keeps C as a source-only error action.
manager_bin="$tmp/manager-bin"; manager_config="$tmp/manager-config"
mkdir -p "$manager_bin" "$manager_config"
printf 'backend = "git"\n' >"$manager_config/config.toml"
cat >"$manager_bin/herdr" <<'EOF_HERDR'
#!/usr/bin/env bash
if [[ ${1:-} == workspace && ${2:-} == list ]]; then printf '{"result":{"workspaces":[]}}\n'; fi
EOF_HERDR
cat >"$manager_bin/fzf" <<'EOF_FZF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_MANAGER_ARGS"
cat >"$TEST_MANAGER_ROWS"
EOF_FZF
cat >"$manager_bin/wt" <<'EOF_WT'
#!/usr/bin/env bash
printf 'wt invoked\n' >>"$TEST_FORBIDDEN_PROCESSES"
exit 97
EOF_WT
chmod +x "$manager_bin"/*
: >"$tmp/forbidden-processes"

# The manager consults the adapter capability before forwarding any missing
# path. A backend that does not advertise precise stale removal fails clearly
# without invoking its remove operation or pruning registration metadata.
no_stale_plugin="$tmp/no-stale-plugin"; mkdir "$no_stale_plugin"
cp "$plugin_root"/{manager.sh,removal_jobs.sh,lib.sh,backend.sh,backend_git.sh} "$no_stale_plugin/"
sed 's/remove_stale:true/remove_stale:false/' "$no_stale_plugin/backend_git.sh" >"$no_stale_plugin/backend_git.sh.new"
mv "$no_stale_plugin/backend_git.sh.new" "$no_stale_plugin/backend_git.sh"
no_stale_path="$tmp/removals-no-stale-capability"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b no-stale-capability "$no_stale_path"
rm -rf "$no_stale_path"
no_stale_state="$tmp/no-stale-state"; mkdir "$no_stale_state"; printf 'manage\n' >"$no_stale_state/mode"
no_stale_payload=$("$JQ_BIN" -cn --arg root "$remove_repo" --arg path "$no_stale_path" \
    '{kind:"worktree",target:"no-stale-capability",path:$path,repo_root:$root,repo_name:"removals"}' | base64 | tr -d '\n')
if HERDR_PLUGIN_ROOT="$no_stale_plugin" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
    HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$FORESTR_GIT_BIN" JQ_BIN="$JQ_BIN" \
    WORKTRUNK_BIN="$manager_bin/wt" ACTIVE_REPO_ROOT="$remove_repo" \
    MANAGER_SOURCE_CHECKOUT_PATH="$remove_repo" TEST_FORBIDDEN_PROCESSES="$tmp/forbidden-processes" \
    bash "$no_stale_plugin/manager.sh" __remove "$no_stale_state" "$no_stale_payload" false; then
    fail 'backend without stale capability accepted a missing path'
fi
grep -Fq 'cannot safely remove a missing or prunable worktree path' "$no_stale_state/error"
"$FORESTR_GIT_BIN" -C "$remove_repo" show-ref --verify --quiet refs/heads/no-stale-capability
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree list --porcelain | grep -Fq "$no_stale_path"
wait_for_manager_refresh "$no_stale_state"

HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$FORESTR_GIT_BIN" JQ_BIN="$JQ_BIN" \
WORKTRUNK_BIN="$manager_bin/wt" ACTIVE_REPO_ROOT="$remove_repo" \
MANAGER_SOURCE_CHECKOUT_PATH="$remove_repo" TEST_MANAGER_ARGS="$tmp/manager-args" \
TEST_MANAGER_ROWS="$tmp/manager-rows" TEST_FORBIDDEN_PROCESSES="$tmp/forbidden-processes" \
bash "$plugin_root/manager.sh" </dev/null
[[ ! -s $tmp/forbidden-processes ]]
! grep -Fq 'backend: git' "$tmp/manager-args"
grep -Fq -- '--bind=C:transform:if ' "$tmp/manager-args"
! grep -Fq 'create/force' "$tmp/manager-args"
manager_state="$tmp/manager-state"; mkdir "$manager_state"; printf 'source\n' >"$manager_state/mode"
main_payload=$("$JQ_BIN" -cn --arg root "$remove_repo" \
    '{kind:"main",repo_root:$root,repo_key:$root,repo_name:"removals",target:"main",path:$root}' | base64 | tr -d '\n')
"$JQ_BIN" -Rnr --arg p "$main_payload" '$p|@base64d|fromjson|{repo_root,repo_key,repo_name}|tojson|@base64' \
    >"$manager_state/repository"
if HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
    HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$FORESTR_GIT_BIN" JQ_BIN="$JQ_BIN" \
    WORKTRUNK_BIN="$manager_bin/wt" \
    bash "$plugin_root/manager.sh" __new-mode "$manager_state" true; then
    fail 'Git clobber input transition succeeded'
fi
[[ $(cat "$manager_state/mode") == source ]]
grep -Fq 'not supported by the git backend' "$manager_state/error"

# A failed source open after Git created a checkout leaves the source screen and
# error intact. Lazy source rows immediately reflect the retained checkout.
"$FORESTR_GIT_BIN" -C "$remove_repo" branch manager-partial main
partial_path="$tmp/.removals-manager-partial"
partial_payload=$("$JQ_BIN" -cn --arg root "$remove_repo" \
    '{kind:"local",target:"manager-partial",path:"",repo_root:$root,repo_name:"removals"}' | base64 | tr -d '\n')
cat >"$tmp/git-manager-post-verify" <<'EOF_MANAGER_VERIFY'
#!/usr/bin/env bash
/usr/bin/git "$@"
status=$?
if [[ $status -eq 0 && " $* " == *' worktree add --no-guess-remote '* ]]; then
    path=${@: -2:1}
    /usr/bin/git -C "$path" symbolic-ref HEAD refs/heads/main
fi
exit "$status"
EOF_MANAGER_VERIFY
chmod +x "$tmp/git-manager-post-verify"
printf 'source\n' >"$manager_state/mode"; printf 'local\n' >"$manager_state/scope"
if HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
    HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$tmp/git-manager-post-verify" JQ_BIN="$JQ_BIN" \
    WORKTRUNK_BIN="$manager_bin/wt" ACTIVE_REPO_ROOT="$remove_repo" \
    MANAGER_SOURCE_CHECKOUT_PATH="$remove_repo" TEST_FORBIDDEN_PROCESSES="$tmp/forbidden-processes" \
    bash "$plugin_root/manager.sh" __open "$manager_state" "$partial_payload" ''; then
    fail 'post-verification open unexpectedly succeeded'
fi
[[ -d $partial_path ]]
grep -Fq 'checkout retained for inspection' "$manager_state/error"
[[ $(cat "$manager_state/mode") == source ]]
HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
    HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$FORESTR_GIT_BIN" JQ_BIN="$JQ_BIN" \
    WORKTRUNK_BIN="$manager_bin/wt" \
    bash "$plugin_root/manager.sh" __rows "$manager_state" >"$tmp/partial-source-rows"
! grep -Fq 'manager-partial' "$tmp/partial-source-rows"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree remove --force "$partial_path"
printf 'manage\n' >"$manager_state/mode"; printf '0\n' >"$manager_state/generation"

warning_path="$tmp/removals-manager-warning"
"$FORESTR_GIT_BIN" -C "$remove_repo" worktree add -q -b manager-warning "$warning_path"
"$FORESTR_GIT_BIN" -C "$warning_path" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m warning
warning_payload=$("$JQ_BIN" -cn --arg root "$remove_repo" --arg path "$warning_path" \
    '{kind:"worktree",target:"manager-warning",path:$path,repo_root:$root,repo_name:"removals"}' | base64 | tr -d '\n')
HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$FORESTR_GIT_BIN" JQ_BIN="$JQ_BIN" \
WORKTRUNK_BIN="$manager_bin/wt" ACTIVE_REPO_ROOT="$remove_repo" \
MANAGER_SOURCE_CHECKOUT_PATH="$remove_repo" TEST_FORBIDDEN_PROCESSES="$tmp/forbidden-processes" \
bash "$plugin_root/manager.sh" __remove "$manager_state" "$warning_payload" false
[[ ! -e $warning_path ]]
grep -Fq 'unmerged branch manager-warning was retained' "$manager_state/action-warning"

# Successful mutation starts a fresh topology generation before the worker
# returns, so reload cannot redisplay the removed row. Replaying its stale seed
# payload cannot recreate a ghost row from the retained branch.
removed_generation=$(cat "$manager_state/generation")
removed_snapshot="$manager_state/snapshot.$removed_generation"
! grep -Fq "$warning_path" "$removed_snapshot"
if HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$manager_config" \
    HERDR_BIN_PATH="$manager_bin/herdr" FZF_BIN="$manager_bin/fzf" GIT_BIN="$FORESTR_GIT_BIN" JQ_BIN="$JQ_BIN" \
    WORKTRUNK_BIN="$manager_bin/wt" ACTIVE_REPO_ROOT="$remove_repo" \
    MANAGER_SOURCE_CHECKOUT_PATH="$remove_repo" TEST_FORBIDDEN_PROCESSES="$tmp/forbidden-processes" \
    bash "$plugin_root/manager.sh" __open "$manager_state" "$warning_payload" ''; then
    fail 'stale removed row reopened its retained branch'
fi
refreshed_generation=$(cat "$manager_state/generation")
[[ $refreshed_generation -gt $removed_generation ]]
! grep -Fq "$warning_path" "$manager_state/snapshot.$refreshed_generation"
grep -Fq 'no longer a registered worktree' "$manager_state/error"
wait_for_manager_refresh "$manager_state"

printf 'Git adapter tests passed\n'
