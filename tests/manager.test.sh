#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_root="$repo_root/src"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
producer_pids_for_test() {
    local pid args
    while read -r pid args; do
        [[ $args == *'manager.sh __produce '*"$tmp"* ]] || continue
        printf '%s\n' "$pid"
    done < <(ps -ww -axo pid=,command=)
}
cleanup_test() {
    local pid
    set +e
    while IFS= read -r pid; do [[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null; done < <(producer_pids_for_test)
    for _ in {1..100}; do
        [[ -z $(producer_pids_for_test) ]] && break
        sleep 0.01
    done
    while IFS= read -r pid; do [[ -z $pid ]] || kill -KILL "$pid" 2>/dev/null; done < <(producer_pids_for_test)
    rm -rf "$tmp"
}
trap cleanup_test EXIT

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
git_bin=/usr/bin/git
[[ -x $git_bin ]] || git_bin=$(command -v git)
jq_bin=$(command -v jq)
repo_a="$tmp/repo a"
repo_b="$tmp/repo-b"
feature_a="$tmp/repo a.feature one"
feature_b="$tmp/repo-b.feature-b"
detached_a="$tmp/repo a.detached"
mkdir -p "$repo_a" "$repo_b"
for repo in "$repo_a" "$repo_b"; do
    "$git_bin" -C "$repo" init -q -b main
    "$git_bin" -C "$repo" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m initial
done
"$git_bin" -C "$repo_a" branch local-free
"$git_bin" -C "$repo_a" branch 'topic/slash.ok'
"$git_bin" -C "$repo_a" worktree add -q -b feature-a "$feature_a"
"$git_bin" -C "$repo_a" worktree add -q --detach "$detached_a" HEAD
"$git_bin" -C "$repo_a" worktree lock --reason 'test lock' "$feature_a"
"$git_bin" -C "$repo_b" worktree add -q -b feature-b "$feature_b"
head_a=$("$git_bin" -C "$repo_a" rev-parse HEAD)
"$git_bin" -C "$repo_a" update-ref refs/remotes/origin/main "$head_a"
"$git_bin" -C "$repo_a" update-ref refs/remotes/origin/remote-only "$head_a"
"$git_bin" -C "$repo_a" update-ref refs/remotes/upstream/remote-only "$head_a"
"$git_bin" -C "$repo_a" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'herdr' >>"$TEST_CAPTURE"; printf ' <%s>' "$@" >>"$TEST_CAPTURE"; printf '\n' >>"$TEST_CAPTURE"
if [[ ${1:-} == workspace && ${2:-} == list ]]; then
    [[ ${TEST_HERDR_LIST_FAIL:-false} != true ]] || exit 1
    if [[ ${TEST_HERDR_WAIT_FOR_FIRST_ROW:-false} == true ]]; then
        for _ in $(seq 1 100); do [[ -e $TEST_FIRST_ROW ]] && break; sleep 0.02; done
        [[ -e $TEST_FIRST_ROW ]] || { printf 'first row was blocked by Herdr discovery\n' >&2; exit 1; }
    fi
    cat <<JSON
{"result":{"workspaces":[
 {"workspace_id":"w1","worktree":{"checkout_path":"$TEST_REPO_A","repo_key":"$TEST_REPO_A/.git","repo_name":"repo a","repo_root":"$TEST_REPO_A"}},
 {"workspace_id":"w2","worktree":{"checkout_path":"$TEST_FEATURE_A","repo_key":"$TEST_REPO_A/.git","repo_name":"repo a","repo_root":"$TEST_REPO_A"}},
 {"workspace_id":"w3","worktree":{"checkout_path":"$TEST_REPO_B","repo_key":"$TEST_REPO_B/.git","repo_name":"repo-b","repo_root":"$TEST_REPO_B"}},
 {"workspace_id":"w4","worktree":{"checkout_path":"$TEST_FEATURE_B","repo_key":"$TEST_REPO_B/.git","repo_name":"repo-b","repo_root":"$TEST_REPO_B"}}
]}}
JSON
elif [[ ${1:-} == worktree && ${2:-} == list ]]; then
    repo=
    for ((i=1; i<=$#; i++)); do
        [[ ${!i} != --cwd ]] || { j=$((i+1)); repo=${!j}; }
    done
    if [[ $repo == "$TEST_REPO_A" ]]; then id=w1; name='repo a'; else id=w3; name=repo-b; fi
    printf '{"result":{"source":{"repo_root":"%s","repo_name":"%s","source_workspace_id":"%s"}}}\n' "$repo" "$name" "$id"
elif [[ ${1:-} == workspace && ${2:-} == create ]]; then
    printf '{"result":{"workspace":{"workspace_id":"new-root"}}}\n'
fi
EOF

cat >"$tmp/wt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'wt' >>"$TEST_CAPTURE"; printf ' <%s>' "$@" >>"$TEST_CAPTURE"; printf '\n' >>"$TEST_CAPTURE"
for arg in "$@"; do
    [[ $arg != --branches && $arg != --remotes ]] || { printf 'forbidden enrichment scope\n' >&2; exit 97; }
done
repo=
for ((i=1; i<=$#; i++)); do
    [[ ${!i} != -C ]] || { j=$((i+1)); repo=${!j}; }
done
if [[ " $* " == *' list '* ]]; then
    [[ ${TEST_WT_LIST_FAIL:-false} != true ]] || exit 1
    if [[ -n ${TEST_WT_LIST_DELAY:-} ]]; then
        [[ -z ${TEST_WT_PID_FILE:-} ]] || printf '%s\n' "$$" >"$TEST_WT_PID_FILE"
        sleep "$TEST_WT_LIST_DELAY"
    fi
    if [[ $repo == "$TEST_REPO_A" ]]; then
        cat <<JSON
{"schema":2,"items":[
 {"branch":"main","head":{"short_sha":"enriched1"},"worktree":{"path":"$TEST_REPO_A"},"display":{"state":"is_main","symbols":"^"}},
 {"branch":"feature-a","head":{"short_sha":"enriched2"},"worktree":{"path":"$TEST_FEATURE_A","changes":{"modified":true}},"display":{"state":"ahead","symbols":"!↑"}}
]}
JSON
    else
        printf '{"schema":2,"items":[{"branch":"feature-b","head":{"short_sha":"enriched3"},"worktree":{"path":"%s"},"display":{"symbols":"?"}}]}\n' "$TEST_FEATURE_B"
    fi
    exit
fi
if [[ " $* " == *' remove '* ]]; then
    [[ ${TEST_WT_REMOVE_FAIL:-false} != true ]]
    exit
fi
if [[ " $* " == *' switch '* ]]; then
    [[ ${TEST_WT_SWITCH_FAIL:-false} != true ]] || exit 1
    create=false; target=
    for arg in "$@"; do
        [[ $arg != --create ]] || create=true
        case $arg in
            -C|switch|--create|--clobber|--no-cd|--format=json) ;;
            "$repo") ;;
            *) target=$arg ;;
        esac
    done
    case $target in
        feature-a) path=$TEST_FEATURE_A ;;
        feature-b|local-free) path=$TEST_FEATURE_B ;;
        origin/remote-only|upstream/remote-only) path=$TEST_REMOTE_PATH ;;
        *) path=$TEST_NEW_PATH ;;
    esac
    mkdir -p "$path"
    printf '{"path":"%s","branch":"%s"}\n' "$path" "$target"
fi
EOF

cat >"$tmp/fzf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>"$TEST_FZF_CALLS"
printf '%s\n' "$@" >"$TEST_FZF_ARGS"
printf '%s\n' "${FZF_API_KEY-unset}" >"$TEST_FZF_API_KEY"
: >"$TEST_CANDIDATES"
while IFS= read -r row; do
    printf '%s\n' "$row" >>"$TEST_CANDIDATES"
    [[ $row != *'@ repo a'* ]] || : >"$TEST_FIRST_ROW"
done
if [[ ${TEST_FZF_FAIL:-false} == true ]]; then exit 2; fi
if [[ ${TEST_FZF_BLOCK:-false} == true ]]; then
    : >"$TEST_FZF_READY"
    while true; do sleep 1; done
fi
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' worktree list '* ]]; then
    printf 'git-worktrees-start\n' >>"$TEST_CAPTURE"
    [[ -z ${TEST_GIT_LIST_MARKER:-} ]] || : >"$TEST_GIT_LIST_MARKER"
    [[ -z ${TEST_GIT_LIST_DELAY:-} ]] || sleep "$TEST_GIT_LIST_DELAY"
fi
exec "$TEST_REAL_GIT" "$@"
EOF
cat >"$tmp/timeout" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys

args = sys.argv[1:]
if args == ["--help"]:
    print("--signal --kill-after")
    raise SystemExit(0)
kill_after = 0.25
while args and args[0].startswith("--"):
    option = args.pop(0)
    if option.startswith("--kill-after="):
        kill_after = float(option.split("=", 1)[1].removesuffix("s"))
seconds = float(args.pop(0).removesuffix("s"))
process = subprocess.Popen(args, start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=kill_after)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
EOF
chmod +x "$tmp/herdr" "$tmp/wt" "$tmp/fzf" "$tmp/git" "$tmp/timeout"

export TEST_CAPTURE="$tmp/calls"
export TEST_FZF_CALLS="$tmp/fzf-calls"
export TEST_FZF_ARGS="$tmp/fzf-args"
export TEST_FZF_API_KEY="$tmp/fzf-api-key"
export TEST_CANDIDATES="$tmp/candidates"
export TEST_FZF_READY="$tmp/fzf-ready"
export TEST_FIRST_ROW="$tmp/first-row"
export TEST_REPO_A="$repo_a" TEST_REPO_B="$repo_b"
export TEST_FEATURE_A="$feature_a" TEST_FEATURE_B="$feature_b"
export TEST_REMOTE_PATH="$tmp/remote checkout" TEST_NEW_PATH="$tmp/new checkout"
export HERDR_PLUGIN_ROOT="$repo_root"
mkdir -p "$tmp/config"
printf 'backend = "worktrunk"\n' >"$tmp/config/config.toml"
export HERDR_PLUGIN_CONFIG_DIR="$tmp/config"
export HERDR_BIN_PATH="$tmp/herdr" WORKTRUNK_BIN="$tmp/wt" FZF_BIN="$tmp/fzf"
export GIT_BIN="$git_bin" JQ_BIN="$jq_bin"
export TEST_REAL_GIT="$git_bin" TIMEOUT_BIN="$tmp/timeout"
export FZF_API_KEY='must-not-reach-fzf'
export ACTIVE_REPO_ROOT="$repo_a"
export MANAGER_SOURCE_WORKSPACE_ID=w2
export MANAGER_SOURCE_CHECKOUT_PATH="$feature_a"
unset HERDR_PANE_ID

reset_capture() { : >"$TEST_CAPTURE"; : >"$TEST_FZF_CALLS"; rm -f "$TEST_FZF_READY" "$TEST_FIRST_ROW"; }
run_manager() { reset_capture; bash "$plugin_root/manager.sh" </dev/null; }
new_state() {
    local dir=$1 scope=${2:-local}
    mkdir -p "$dir"
    printf 'manage\n' >"$dir/mode"; printf '%s\n' "$scope" >"$dir/scope"; printf 'false\n' >"$dir/force"; : >"$dir/warnings"
}
payload_for() { grep -F "$1" "$2" | head -n 1 | cut -f1; }

# The one persistent popup starts from the source-checkout seed before either
# Herdr or repository-wide Git discovery has to finish.
export TEST_HERDR_WAIT_FOR_FIRST_ROW=true
run_manager
# The same behavior remains available through auto selection when wt exists.
printf 'backend = "auto"\n' >"$tmp/config/config.toml"
unset TEST_HERDR_WAIT_FOR_FIRST_ROW
[[ $(wc -l <"$TEST_FZF_CALLS") -eq 1 ]]
[[ $(wc -l <"$TEST_CANDIDATES") -eq 2 ]] # header + direct active seed
grep -Fq '@ repo a' "$TEST_CANDIDATES"
grep -Fq -- '--track' "$TEST_FZF_ARGS"
grep -Fq -- '--id-nth=2' "$TEST_FZF_ARGS"
grep -Fq -- '--with-nth=3..' "$TEST_FZF_ARGS"
! grep -Fxq -- '--nth=3..' "$TEST_FZF_ARGS"
grep -Fq -- '--listen-unsafe=' "$TEST_FZF_ARGS"
# Native-style chrome keeps input at the top, count on its right, and only a
# thin input/body divider. Selection is a full palette-backed row, not a glyph.
grep -Fxq -- '--info=inline-right' "$TEST_FZF_ARGS"
grep -Fxq -- '--input-border=bottom' "$TEST_FZF_ARGS"
grep -Fxq -- '--border=none' "$TEST_FZF_ARGS"
grep -Fxq -- '--pointer=' "$TEST_FZF_ARGS"
grep -Fxq -- '--footer-border=none' "$TEST_FZF_ARGS"
grep -Fq 'bg+:5' "$TEST_FZF_ARGS"
grep -Fq 'fg+:0:bold' "$TEST_FZF_ARGS"
grep -Fq 'hl+:0:bold' "$TEST_FZF_ARGS"
grep -Fq 'input-border:bright-black' "$TEST_FZF_ARGS"
grep -Fq 'input-bg:-1' "$TEST_FZF_ARGS"
grep -Fq 'list-bg:-1' "$TEST_FZF_ARGS"
grep -Fq 'header-bg:-1' "$TEST_FZF_ARGS"
grep -Fq 'footer-bg:-1' "$TEST_FZF_ARGS"
grep -Fq 'ghost:bright-black:dim' "$TEST_FZF_ARGS"
grep -Fq 'query:magenta' "$TEST_FZF_ARGS"
grep -Fxq -- '--prompt=' "$TEST_FZF_ARGS"
grep -Fxq -- '--ghost=' "$TEST_FZF_ARGS"
grep -Fxq -- '--footer=loading…' "$TEST_FZF_ARGS"
grep -Fq 'start:hide-input' "$TEST_FZF_ARGS"
grep -Fq 'show-input' "$TEST_FZF_ARGS"
grep -Fq 'hide-input' "$TEST_FZF_ARGS"
! grep -Fq -- '--no-input' "$TEST_FZF_ARGS"
[[ $(cat "$TEST_FZF_API_KEY") == unset ]]

# Search operates on the projected display field. Combining with-nth=3.. with
# nth=3.. applies the field projection twice and makes every non-empty query
# return zero matches.
if real_fzf=$(command -v fzf 2>/dev/null); then
    fuzzy_match=$(printf 'payload\tidentity\tprototype-ai-labelling\npayload2\tidentity2\tmaster\n' \
        | "$real_fzf" --delimiter=$'\t' --with-nth=3.. --filter=pail)
    grep -Fq $'payload\tidentity\tprototype-ai-labelling' <<<"$fuzzy_match"

    # Parse the manager's complete real argument/action set (except its live
    # socket) in filter mode, so malformed transform actions fail durably.
    real_args=()
    while IFS= read -r arg; do
        [[ $arg != --listen-unsafe=* ]] || continue
        real_args+=("$arg")
    done <"$TEST_FZF_ARGS"
    printf '\t\theader\npayload\tidentity\tvisible row\n' \
        | "$real_fzf" "${real_args[@]}" --filter=visible >/dev/null

    # Exercise the manager's exact fzf transform chains in one real PTY on
    # Linux. Darwin PTY redraw ordering is nondeterministic in headless CI; the
    # real fzf filter invocation above still parses every generated action.
    if [[ $(uname -s) != Darwin ]]; then
    pty_config="$tmp/pty-config"; mkdir "$pty_config"
    # ctrl-x is used as the configured Esc-equivalent because a raw ESC byte
    # is ambiguous in this headless PTY (there is no terminal key decoder).
    printf '%s\n' 'backend = "worktrunk"' 'enrich_backend = false' 'key_normal = "ctrl-x"' >"$pty_config/config.toml"
    : >"$TEST_CAPTURE"
    REAL_FZF="$real_fzf" PTY_CONFIG="$pty_config" PTY_TRANSCRIPT="$tmp/pty-transcript" \
        python3 - "$plugin_root/manager.sh" <<'PY'
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

manager = sys.argv[1]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 180, 0, 0))
os.set_blocking(master, False)
env = os.environ.copy()
env.update({"FZF_BIN": env["REAL_FZF"], "HERDR_PLUGIN_CONFIG_DIR": env["PTY_CONFIG"],
            "TERM": "xterm-256color", "MANAGER_BACKGROUND_NOTIFY": "false"})
def child_session():
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

proc = subprocess.Popen(["bash", manager], stdin=slave, stdout=slave, stderr=slave,
                        env=env, preexec_fn=child_session, close_fds=True)
os.close(slave)
output = bytearray()
fzf_pids = set()

def descendants(root):
    rows = []
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    parents = {root}
    found = set()
    changed = True
    while changed:
        changed = False
        for pid, ppid, command in rows:
            if pid not in found and ppid in parents:
                found.add(pid); parents.add(pid); changed = True
    return [(pid, command) for pid, _, command in rows if pid in found]

def sample_fzf():
    for pid, command in descendants(proc.pid):
        if os.path.basename(command.split()[0]) == "fzf":
            fzf_pids.add(pid)

def read_until(*needles, start=0, timeout=12):
    deadline = time.monotonic() + timeout
    encoded = [n.encode() if isinstance(n, str) else n for n in needles]
    while time.monotonic() < deadline:
        sample_fzf()
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except (BlockingIOError, OSError):
                pass
        current = bytes(output[start:])
        if all(n in current for n in encoded):
            return
        if proc.poll() is not None:
            raise AssertionError(f"manager exited {proc.returncode} before {encoded!r}")
    raise AssertionError(f"timed out waiting for {encoded!r}; tail={bytes(output[-4000:])!r}")

def settle(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], min(0.05, deadline - time.monotonic()))
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except (BlockingIOError, OSError):
                pass

try:
    mark = len(output)
    read_until("/ search worktrees", "\u2500\u2500\u2500\u2500", "j/k move \u00b7 enter open", "repo a")
    manage_screen = bytes(output[mark:])
    assert b"WORKTREES" not in manage_screen and b"backend:" not in manage_screen, manage_screen[-2000:]

    # Normal-list printable input is discarded while the real input stays
    # hidden; c proves no irrelevant query captured those bytes.
    os.write(master, b"zzzz-text")
    settle(0.3)
    mark = len(output); os.write(master, b"c")
    read_until("/ search repositories", "\u2500\u2500\u2500\u2500", "enter choose", "h/esc/ctrl-x back",
               os.environ["TEST_REPO_A"], os.environ["TEST_REPO_B"], start=mark)
    repository_screen = bytes(output[mark:])
    assert b"CREATE \xe2\x80\xba Choose repository" not in repository_screen, repository_screen[-2000:]
    assert b"backend:" not in repository_screen, repository_screen[-2000:]
    settle(0.6)
    # Enter is the sole select action.
    mark = len(output); os.write(master, b"\r")
    read_until("/ search branches", "\u2500\u2500\u2500\u2500", "enter use \u00b7 n new", "repo a \u00b7 local",
               "+ Create a new branch", start=mark)
    source_screen = bytes(output[mark:])
    assert b"Choose source" not in source_screen and b"backend:" not in source_screen, source_screen[-2000:]
    assert b"root:" not in source_screen, source_screen[-2000:]
    settle(0.6)
    # h navigates source -> repository in list-normal mode.
    mark = len(output); os.write(master, b"h")
    read_until("/ search repositories", "h/esc/ctrl-x back", start=mark)
    settle(0.8)
    mark = len(output); os.write(master, b"\r")
    read_until("/ search branches", "repo a \u00b7 local", "+ Create a new branch", start=mark)
    settle(0.8)

    # Lowercase l/r/b are source-only scope controls.
    mark = len(output); os.write(master, b"r")
    read_until("repo a \u00b7 remote", "/ search branches", start=mark)
    settle(0.6)
    mark = len(output); os.write(master, b"l")
    read_until("repo a \u00b7 local", start=mark)
    settle(0.8)

    mark = len(output); os.write(master, b"n")
    read_until("branch name", "enter create \u00b7 esc/ctrl-x back", "repo a \u00b7 base default", "Type a branch name", start=mark)
    new_screen = bytes(output[mark:])
    assert b"CREATE \xe2\x80\xba" not in new_screen and b"backend:" not in new_screen, new_screen[-2000:]
    assert b"root:" not in new_screen, new_screen[-2000:]
    branch = b"qjhklrbRGcdCR/pty.valid"
    mark = len(output); os.write(master, branch)
    read_until(branch, start=mark)
    assert proc.poll() is None, "h, l/r/b, R, q, or another former modal key closed direct input"
    mark = len(output); os.write(master, b"\x18")
    read_until("/ search branches", "\u2500\u2500\u2500\u2500", "repo a \u00b7 local", "+ Create a new branch", start=mark)

    # Slash reveals the real active input. h/l/r/b and former modal keys become
    # query text; back hides input and restores the fake bar on the same screen.
    modal_query = b"qjhklrbRGcdCR/"
    mark = len(output); os.write(master, b"/")
    read_until("search branches", "ctrl-x clear search", start=mark)
    mark = len(output); os.write(master, modal_query)
    read_until(modal_query, "0/", start=mark)
    assert proc.poll() is None, "modal keys were still active during search"
    mark = len(output); os.write(master, b"\x15local")
    read_until("local", "2/3", start=mark)
    mark = len(output); os.write(master, b"\x18")
    read_until("/ search branches", "\u2500\u2500\u2500\u2500", "enter use \u00b7 n new", start=mark)
    assert modal_query not in bytes(output[mark:]), "search query survived the back key"
    os.killpg(proc.pid, signal.SIGINT)
    proc.wait(timeout=8)
    assert proc.returncode == 130, proc.returncode
    assert len(fzf_pids) == 1, f"expected one persistent fzf PID, saw {fzf_pids}"
finally:
    try:
        open(os.environ["PTY_TRANSCRIPT"], "wb").write(output)
    except OSError:
        pass
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL); proc.wait()
    os.close(master)
PY
    ! grep -Eq 'wt .*<switch>|wt .*<--create>' "$TEST_CAPTURE"
    fi
fi

# The public current-mode row seam performs Git skeleton discovery without
# branch/history/status expansion; this includes worktrees not open in Herdr.
state="$tmp/state"
new_state "$state"
bash "$plugin_root/manager.sh" __rows "$state" >"$TEST_CANDIDATES"
[[ $(wc -l <"$TEST_CANDIDATES") -eq 6 ]] # header + 3 repo-a + 2 repo-b
cp "$TEST_CANDIDATES" "$tmp/skeleton-candidates"
! grep -Fq 'local-free' "$TEST_CANDIDATES"
! grep -Fq 'remote-only' "$TEST_CANDIDATES"
grep -Fq '@ repo a' "$TEST_CANDIDATES"
grep -Fq '^ repo a' "$TEST_CANDIDATES"
grep -Fq '+ repo-b' "$TEST_CANDIDATES"
grep -Fq '(detached HEAD)' "$TEST_CANDIDATES"
grep -Fq 'locked' "$TEST_CANDIDATES"
grep -Fq "$feature_a" "$TEST_CANDIDATES"
# Source marker uses canonical checkout identity, not Git's invocation cwd.
! grep -Fq $'\t@ repo-b' "$TEST_CANDIDATES"
# Full unusual paths survive in the hidden payload.
feature_payload=$(payload_for ' feature-a ' "$TEST_CANDIDATES")
[[ $("$jq_bin" -Rnr --arg p "$feature_payload" '$p|@base64d|fromjson|.path') == "$feature_a" ]]
# Terminal-inherited styling and display-width table behavior remain configured.
grep -Fq -- '--color=16,fg:-1,bg:-1,gutter:-1' "$TEST_FZF_ARGS"
grep -Fq -- '--with-shell=' "$TEST_FZF_ARGS"
grep -Fq -- 'bash -c' "$TEST_FZF_ARGS"
grep -Fq -- '--header-lines=1' "$TEST_FZF_ARGS"

# Layering is observable at the current-mode snapshot seam: all open Herdr
# checkouts arrive before delayed Git, Git adds the non-open detached worktree,
# then schema-2 Worktrunk facts replace the same canonical identities.
layer_state="$tmp/layer-state"; new_state "$layer_state"; printf '0\n' >"$layer_state/generation"
export GIT_BIN="$tmp/git" TEST_GIT_LIST_DELAY=1 TEST_WT_LIST_DELAY=1 MANAGER_BACKGROUND_NOTIFY=false
bash "$plugin_root/manager.sh" __refresh "$layer_state"
read -r layer_pid _ <"$layer_state/producer.pid"; layer_generation=$(cat "$layer_state/generation")
layer_pgid=$(ps -o pgid= -p "$layer_pid"); layer_pgid=${layer_pgid//[[:space:]]/}
[[ $layer_pgid == "$layer_pid" ]] # producer owns the group stopped on refresh/teardown
for _ in {1..100}; do
    grep -Fq "$feature_b" "$layer_state/snapshot.$layer_generation" 2>/dev/null && break
    sleep 0.02
done
grep -Fq "$feature_b" "$layer_state/snapshot.$layer_generation" # Herdr seed
! grep -Fq '(detached HEAD)' "$layer_state/snapshot.$layer_generation" # Git still delayed
for _ in {1..300}; do
    grep -Fq '(detached HEAD)' "$layer_state/snapshot.$layer_generation" 2>/dev/null && break
    sleep 0.02
done
layer_snapshot="$layer_state/snapshot.$layer_generation"
grep -Fq '(detached HEAD)' "$layer_snapshot" # Git skeleton precedes enrichment
! grep -Fq '!↑' "$layer_snapshot"             # delayed Worktrunk did not block it
for _ in {1..500}; do [[ -e $layer_state/completed.$layer_generation ]] && break; sleep 0.02; done
[[ -e $layer_state/completed.$layer_generation ]]
unset TEST_GIT_LIST_DELAY TEST_WT_LIST_DELAY
grep -Fq '!↑' "$layer_snapshot"              # advisory Worktrunk symbols
grep -Fq 'locked' "$layer_snapshot"           # Git topology remains
[[ $(grep -Fc "$feature_a" "$layer_snapshot") -eq 1 ]] # update, never duplicate
grep -Fq 'wt <-C>' "$TEST_CAPTURE"
grep -Fq '<--config-set> <list.json-schema=2>' "$TEST_CAPTURE"
grep -Fq '<--config-set> <list.full=false>' "$TEST_CAPTURE"
! grep -Eq 'wt .*<--branches>|wt .*<--remotes>' "$TEST_CAPTURE"
[[ ! -e $layer_state/producer.pid ]]
export GIT_BIN="$git_bin"

# A real external timeout surrounds Worktrunk's own collection budget. Failure
# leaves the already-published Git skeleton intact instead of blanking rows.
timeout_config="$tmp/timeout-config"; mkdir -p "$timeout_config"
cat >"$timeout_config/config.toml" <<'EOF'
enrich_backend = true
worktrunk_enrichment_timeout_ms = 100
worktrunk_enrichment_collection_timeout_ms = 50
worktrunk_enrichment_concurrency = 2
EOF
timeout_state="$tmp/timeout-state"; new_state "$timeout_state"; printf '0\n' >"$timeout_state/generation"
export HERDR_PLUGIN_CONFIG_DIR="$timeout_config" TEST_WT_LIST_DELAY=1
bash "$plugin_root/manager.sh" __refresh "$timeout_state"
timeout_generation=$(cat "$timeout_state/generation")
for _ in {1..500}; do [[ -e $timeout_state/completed.$timeout_generation ]] && break; sleep 0.02; done
[[ -e $timeout_state/completed.$timeout_generation ]]
timeout_snapshot="$timeout_state/snapshot.$timeout_generation"
grep -Fq '(detached HEAD)' "$timeout_snapshot"
! grep -Fq 'enriched2' "$timeout_snapshot"
[[ $(grep -Fc "$feature_a" "$timeout_snapshot") -eq 1 ]]
unset HERDR_PLUGIN_CONFIG_DIR TEST_WT_LIST_DELAY

# An impossible configured budget is called out and reset to safe defaults.
invalid_budget_config="$tmp/invalid-budget-config"; mkdir -p "$invalid_budget_config"
cat >"$invalid_budget_config/config.toml" <<'EOF'
enrich_backend = true
worktrunk_enrichment_timeout_ms = 100
worktrunk_enrichment_collection_timeout_ms = 500
worktrunk_enrichment_concurrency = 1
EOF
invalid_budget_state="$tmp/invalid-budget-state"; new_state "$invalid_budget_state"; printf '0\n' >"$invalid_budget_state/generation"
export HERDR_PLUGIN_CONFIG_DIR="$invalid_budget_config" MANAGER_BACKGROUND_NOTIFY=false
: >"$TEST_CAPTURE"
bash "$plugin_root/manager.sh" __refresh "$invalid_budget_state"
for _ in {1..500}; do [[ -e $invalid_budget_state/completed.1 ]] && break; sleep 0.02; done
grep -Fq 'must be >= worktrunk_enrichment_collection_timeout_ms' "$invalid_budget_state/warnings.1"
grep -Fq '<list.timeout-ms=5000>' "$TEST_CAPTURE"
unset HERDR_PLUGIN_CONFIG_DIR MANAGER_BACKGROUND_NOTIFY

# Refresh terminates the whole producer process group, including timeout and
# Worktrunk descendants, before starting the replacement generation.
descendant_state="$tmp/descendant-state"; new_state "$descendant_state"; printf '0\n' >"$descendant_state/generation"
export TEST_WT_LIST_DELAY=30 TEST_WT_PID_FILE="$tmp/wt-descendant-pid" MANAGER_BACKGROUND_NOTIFY=false
bash "$plugin_root/manager.sh" __refresh "$descendant_state"
for _ in {1..500}; do [[ -s $TEST_WT_PID_FILE ]] && break; sleep 0.02; done
[[ -s $TEST_WT_PID_FILE ]]; descendant_pid=$(cat "$TEST_WT_PID_FILE")
unset TEST_WT_LIST_DELAY TEST_WT_PID_FILE
bash "$plugin_root/manager.sh" __refresh "$descendant_state"
for _ in {1..200}; do ! kill -0 "$descendant_pid" 2>/dev/null && break; sleep 0.02; done
! kill -0 "$descendant_pid" 2>/dev/null
for _ in {1..500}; do [[ -e $descendant_state/completed.2 ]] && break; sleep 0.02; done
[[ -e $descendant_state/completed.2 ]]
unset MANAGER_BACKGROUND_NOTIFY

# Refresh increments the generation and terminates the previous producer group;
# stale generations can neither publish nor replace the current snapshot.
refresh_state="$tmp/refresh-state"; new_state "$refresh_state"; printf '0\n' >"$refresh_state/generation"
export GIT_BIN="$tmp/git" TEST_GIT_LIST_DELAY=5
bash "$plugin_root/manager.sh" __refresh "$refresh_state"
old_generation=$(cat "$refresh_state/generation")
for _ in {1..100}; do [[ -e $refresh_state/repositories.$old_generation ]] && break; sleep 0.02; done
bash "$plugin_root/manager.sh" __refresh "$refresh_state"
new_generation=$(cat "$refresh_state/generation")
[[ $new_generation -eq $((old_generation + 1)) ]]
bash "$plugin_root/manager.sh" __background-rows "$refresh_state" "$old_generation" >"$tmp/current-after-stale"
grep -Fq "$feature_a" "$tmp/current-after-stale"
for _ in {1..1000}; do [[ -e $refresh_state/completed.$new_generation ]] && break; sleep 0.02; done
[[ -e $refresh_state/completed.$new_generation ]]
[[ ! -e $refresh_state/completed.$old_generation ]]
unset TEST_GIT_LIST_DELAY MANAGER_BACKGROUND_NOTIFY
export GIT_BIN="$git_bin"

# A completed producer record is never signalled, even if its PID now belongs
# to an unrelated live process. Refresh replaces the stale record safely.
completed_guard_state="$tmp/completed-guard-state"; new_state "$completed_guard_state"; printf '7\n' >"$completed_guard_state/generation"
sleep 30 & innocent_pid=$!
innocent_token=$(LC_ALL=C ps -o lstart= -p "$innocent_pid")
innocent_token=${innocent_token//[[:space:]]/}
printf '%s 7 %s\n' "$innocent_pid" "$innocent_token" >"$completed_guard_state/producer.pid"
: >"$completed_guard_state/completed.7"
bash "$plugin_root/manager.sh" __refresh "$completed_guard_state"
kill -0 "$innocent_pid"
kill "$innocent_pid"; wait "$innocent_pid" 2>/dev/null || true
for _ in {1..1000}; do [[ -e $completed_guard_state/completed.8 ]] && break; sleep 0.02; done
[[ -e $completed_guard_state/completed.8 && ! -e $completed_guard_state/producer.pid ]]

# A matching start token is insufficient on platforms whose ps timestamps have
# one-second resolution: the command must also be this generation's producer.
identity_guard_state="$tmp/identity-guard-state"; new_state "$identity_guard_state"; printf '9\n' >"$identity_guard_state/generation"
sleep 30 & innocent_pid=$!
innocent_token=$(LC_ALL=C ps -o lstart= -p "$innocent_pid")
innocent_token=${innocent_token//[[:space:]]/}
printf '%s 9 %s\n' "$innocent_pid" "$innocent_token" >"$identity_guard_state/producer.pid"
bash "$plugin_root/manager.sh" __refresh "$identity_guard_state"
kill -0 "$innocent_pid"
kill "$innocent_pid"; wait "$innocent_pid" 2>/dev/null || true
for _ in {1..1000}; do [[ -e $identity_guard_state/completed.10 ]] && break; sleep 0.02; done
[[ -e $identity_guard_state/completed.10 && ! -e $identity_guard_state/producer.pid ]]

# Teardown can delete state just as a producer reaches complete_producer. A
# held lock makes that point deterministic: removing the directory must break
# lock acquisition promptly instead of leaving an orphan spinning under PID 1.
cat >"$tmp/herdr-empty" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == workspace && ${2:-} == list ]] && printf '{"result":{"workspaces":[]}}\n'
EOF
chmod +x "$tmp/herdr-empty"
deleted_state="$tmp/deleted-state"; new_state "$deleted_state"; printf '1\n' >"$deleted_state/generation"
mkdir "$deleted_state/producer.lock"
deleted_config="$tmp/deleted-config"; mkdir "$deleted_config"; printf 'backend = "git"\n' >"$deleted_config/config.toml"
HERDR_PLUGIN_CONFIG_DIR="$deleted_config" HERDR_BIN_PATH="$tmp/herdr-empty" ACTIVE_REPO_ROOT="" \
    MANAGER_SOURCE_CHECKOUT_PATH="" MANAGER_BACKGROUND_NOTIFY=false \
    bash "$plugin_root/manager.sh" __produce "$deleted_state" 1 \
    >"$tmp/deleted-producer.log" 2>&1 &
deleted_pid=$!
for _ in {1..100}; do
    [[ $(ps -o state= -p "$deleted_pid" 2>/dev/null) == *S* ]] && break
    sleep 0.01
done
rm -rf "$deleted_state"
for _ in {1..100}; do ! kill -0 "$deleted_pid" 2>/dev/null && break; sleep 0.01; done
! kill -0 "$deleted_pid" 2>/dev/null
wait "$deleted_pid" 2>/dev/null || true
[[ -z $(producer_pids_for_test) ]]

# Warning files are generation-scoped: repeated failures produce one warning
# in the current generation, never accumulated copies from prior refreshes.
warning_state="$tmp/warning-state"; new_state "$warning_state"; printf '0\n' >"$warning_state/generation"
export TEST_HERDR_LIST_FAIL=true MANAGER_BACKGROUND_NOTIFY=false
bash "$plugin_root/manager.sh" __refresh "$warning_state"
for _ in {1..500}; do [[ -e $warning_state/completed.1 ]] && break; sleep 0.02; done
bash "$plugin_root/manager.sh" __refresh "$warning_state"
for _ in {1..500}; do [[ -e $warning_state/completed.2 ]] && break; sleep 0.02; done
[[ $(grep -Fc 'Herdr could not list workspaces' "$warning_state/warnings.2") -eq 1 ]]
printf 'manage help must not be in the header\n' >"$warning_state/manage.help"
printf 'manage footer\n' >"$warning_state/manage.footer"
bash "$plugin_root/manager.sh" __header "$warning_state" >"$tmp/current-header"
[[ $(grep -Fc 'Herdr could not list workspaces' "$tmp/current-header") -eq 1 ]]
! grep -Fq 'WORKTREES' "$tmp/current-header"
! grep -Fq 'backend:' "$tmp/current-header"
! grep -Fq "$repo_a" "$tmp/current-header"
! grep -Fq 'manage help' "$tmp/current-header"
grep -Fq 'manage footer' <(bash "$plugin_root/manager.sh" __footer "$warning_state")
unset TEST_HERDR_LIST_FAIL MANAGER_BACKGROUND_NOTIFY

# Creation starts at an explicit repository chooser. The invoking/selected
# repository is only preferred: every deduplicated globally discovered repo is
# still selectable, including when Forestr was launched outside Git.
wizard_state="$tmp/wizard-state"; new_state "$wizard_state"
main_payload=$(payload_for '^ repo a' "$TEST_CANDIDATES")
bash "$plugin_root/manager.sh" __enter-repository "$wizard_state" "$main_payload"
[[ $(cat "$wizard_state/mode") == repository ]]
bash "$plugin_root/manager.sh" __rows "$wizard_state" >"$tmp/repositories"
[[ $(grep -Fc "$repo_a" "$tmp/repositories") -eq 1 ]]
[[ $(grep -Fc "$repo_b" "$tmp/repositories") -eq 1 ]]
grep -Fq "$repo_a" <(sed -n '2p' "$tmp/repositories") # preferred row is first/selected
grep -Fq $'\t› repo a' <(sed -n '2p' "$tmp/repositories")
bash "$plugin_root/manager.sh" __header "$wizard_state" >"$tmp/repository-header"
! grep -Fq 'CREATE ›' "$tmp/repository-header"
! grep -Fq 'Choose repository' "$tmp/repository-header"
! grep -Fq 'backend:' "$tmp/repository-header"
! grep -Fq "$repo_a" "$tmp/repository-header"
! grep -Fq "$repo_b" "$tmp/repository-header"
# Repository discovery warnings remain useful even though routine metadata is gone.
export TEST_HERDR_LIST_FAIL=true
bash "$plugin_root/manager.sh" __rows "$wizard_state" >/dev/null
unset TEST_HERDR_LIST_FAIL
bash "$plugin_root/manager.sh" __header "$wizard_state" >"$tmp/repository-warning-header"
grep -Fq 'Herdr could not list workspaces' "$tmp/repository-warning-header"
! grep -Fq 'Choose repository' "$tmp/repository-warning-header"
repo_b_payload=$(payload_for "$repo_b" "$tmp/repositories")
bash "$plugin_root/manager.sh" __select-repository "$wizard_state" "$repo_b_payload"
[[ $(cat "$wizard_state/mode") == source ]]
selected_repository=$("$jq_bin" -Rnr --arg p "$(cat "$wizard_state/repository")" '$p|@base64d|fromjson')
[[ $("$jq_bin" -r .repo_root <<<"$selected_repository") == "$repo_b" ]]

# Source choice and new-branch input are separate screens. The source inventory
# always starts with a synthetic New row, including an otherwise empty repo.
bash "$plugin_root/manager.sh" __rows "$wizard_state" >"$tmp/source-b"
new_payload=$(sed -n '2s/\t.*//p' "$tmp/source-b")
[[ $("$jq_bin" -Rnr --arg p "$new_payload" '$p|@base64d|fromjson|.kind') == new ]]
grep -Fq '+ Create a new branch…' "$tmp/source-b"
[[ $(wc -l <"$tmp/source-b") -eq 2 ]] # no unattached branches is still usable
bash "$plugin_root/manager.sh" __new-mode "$wizard_state" false
[[ $(cat "$wizard_state/mode") == new ]]
bash "$plugin_root/manager.sh" __rows "$wizard_state" >"$tmp/new-input"
[[ $(wc -l <"$tmp/new-input") -eq 2 ]]
grep -Fq 'Type a branch name' "$tmp/new-input"
bash "$plugin_root/manager.sh" __header "$wizard_state" >"$tmp/new-header"
grep -Fxq 'repo-b · base default' "$tmp/new-header"
! grep -Fq 'CREATE ›' "$tmp/new-header"
! grep -Fq 'New branch' "$tmp/new-header"
! grep -Fq 'backend:' "$tmp/new-header"
! grep -Fq "$repo_b" "$tmp/new-header"

# Source candidates are lazy and tied to the explicitly selected repository.
# The synthetic New row remains first; checked-out branches are excluded.
source_state="$tmp/source-state"; new_state "$source_state"
bash "$plugin_root/manager.sh" __enter-repository "$source_state" "$main_payload"
bash "$plugin_root/manager.sh" __rows "$source_state" >"$tmp/source-repositories"
repo_a_payload=$(payload_for "$repo_a" "$tmp/source-repositories")
bash "$plugin_root/manager.sh" __select-repository "$source_state" "$repo_a_payload"
bash "$plugin_root/manager.sh" __rows "$source_state" >"$tmp/source-local"
grep -Fq '+ Create a new branch…' "$tmp/source-local"
[[ $("$jq_bin" -Rnr --arg p "$(sed -n '2s/\t.*//p' "$tmp/source-local")" '$p|@base64d|fromjson|.kind') == new ]]
grep -Fq 'L local-free' "$tmp/source-local"
grep -Fq 'L topic/slash.ok' "$tmp/source-local"
! grep -Fq 'feature-a' "$tmp/source-local" # checked out elsewhere
! grep -Fq 'remote-only' "$tmp/source-local"
! grep -Fq 'wt ' "$TEST_CAPTURE"

# Local/remote/both scopes apply only to source rows. Remote rows retain an
# unambiguous remote/ref identity and symbolic remote HEAD is excluded.
bash "$plugin_root/manager.sh" __scope "$source_state" remote
bash "$plugin_root/manager.sh" __header "$source_state" >"$tmp/source-header"
grep -Fxq 'repo a · remote' "$tmp/source-header"
! grep -Fq 'CREATE ›' "$tmp/source-header"
! grep -Fq 'Choose source' "$tmp/source-header"
! grep -Fq 'backend:' "$tmp/source-header"
! grep -Fq 'root:' "$tmp/source-header"
! grep -Fq "$repo_a" "$tmp/source-header"
bash "$plugin_root/manager.sh" __rows "$source_state" >"$tmp/source-remote"
grep -Fq 'R origin/remote-only' "$tmp/source-remote"
grep -Fq 'R upstream/remote-only' "$tmp/source-remote"
! grep -Fq 'origin/HEAD' "$tmp/source-remote"
! grep -Fq 'local-free' "$tmp/source-remote"
bash "$plugin_root/manager.sh" __scope "$source_state" both
bash "$plugin_root/manager.sh" __rows "$source_state" >"$tmp/source-both"
grep -Fq 'L local-free' "$tmp/source-both"
grep -Fq 'R origin/remote-only' "$tmp/source-both"

# Repository lineage does not depend on the launch checkout. Reusing the exact
# selected record from a linked-worktree launch produces byte-identical rows.
linked_state="$tmp/linked-state"; new_state "$linked_state" both
cp "$source_state/repository" "$linked_state/repository"
printf 'source\n' >"$linked_state/mode"
ACTIVE_REPO_ROOT="$feature_a" MANAGER_SOURCE_CHECKOUT_PATH="$feature_a" \
    bash "$plugin_root/manager.sh" __rows "$linked_state" >"$tmp/source-from-linked"
cmp "$tmp/source-both" "$tmp/source-from-linked"

# Stale manage notifications render the current source/new screen instead of
# clobbering wizard state, scope, query semantics, or selected repository.
bash "$plugin_root/manager.sh" __background-rows "$source_state" 999 >"$tmp/background-during-source"
[[ $(cat "$source_state/mode") == source && $(cat "$source_state/scope") == both ]]
cmp "$tmp/source-both" "$tmp/background-during-source"
bash "$plugin_root/manager.sh" __new-mode "$source_state" false
bash "$plugin_root/manager.sh" __background-rows "$source_state" 999 >"$tmp/background-during-new"
[[ $(cat "$source_state/mode") == new ]]
grep -Fq 'Type a branch name' "$tmp/background-during-new"
bash "$plugin_root/manager.sh" __source-mode "$source_state"

# Existing local and fully qualified remote selections materialize through
# Worktrunk using the selected repository, then common Herdr focus/open logic.
: >"$TEST_CAPTURE"
local_payload=$(payload_for 'L local-free' "$tmp/source-both")
bash "$plugin_root/manager.sh" __open "$source_state" "$local_payload"
grep -Fq "wt <-C> <$repo_a> <switch> <local-free> <--no-cd> <--format=json>" "$TEST_CAPTURE"
grep -Fq 'herdr <workspace> <focus> <w4>' "$TEST_CAPTURE"
: >"$TEST_CAPTURE"
remote_payload=$(payload_for 'R origin/remote-only' "$tmp/source-both")
bash "$plugin_root/manager.sh" __open "$source_state" "$remote_payload"
grep -Fq "<switch> <origin/remote-only> <--no-cd>" "$TEST_CAPTURE"
grep -Fq "herdr <worktree> <open> <--cwd> <$repo_a> <--path> <$TEST_REMOTE_PATH>" "$TEST_CAPTURE"

# New-branch input is a distinct mode. Its query is submitted exactly, so all
# printable modal keys and slash remain valid branch-name bytes.
bash "$plugin_root/manager.sh" __new-mode "$source_state" false
: >"$TEST_CAPTURE"
exact_branch='qjhklGcdRbCR/n.valid'
bash "$plugin_root/manager.sh" __create "$source_state" "$exact_branch"
grep -Fq "<switch> <--create> <$exact_branch> <--no-cd>" "$TEST_CAPTURE"
! grep -Fq '<--clobber>' "$TEST_CAPTURE"

# Worktrunk exposes clobber input; Git rejects it on the source screen and
# leaves a clear error without changing modes.
bash "$plugin_root/manager.sh" __source-mode "$source_state"
bash "$plugin_root/manager.sh" __new-mode "$source_state" true
[[ $(cat "$source_state/mode") == new && $(cat "$source_state/force") == true ]]
bash "$plugin_root/manager.sh" __header "$source_state" >"$tmp/clobber-header"
grep -Fxq 'repo a · base default' "$tmp/clobber-header"
grep -Fq 'CLOBBER MODE' "$tmp/clobber-header"
: >"$TEST_CAPTURE"
bash "$plugin_root/manager.sh" __create "$source_state" 'feature/forced.name'
grep -Fq '<switch> <--create> <--clobber> <feature/forced.name> <--no-cd>' "$TEST_CAPTURE"
git_config="$tmp/git-config"; mkdir -p "$git_config"; printf 'backend = "git"\n' >"$git_config/config.toml"
printf 'source\n' >"$source_state/mode"
if HERDR_PLUGIN_CONFIG_DIR="$git_config" bash "$plugin_root/manager.sh" __new-mode "$source_state" true; then
    printf 'Git backend accepted clobber mode\n' >&2; exit 1
fi
[[ $(cat "$source_state/mode") == source ]]
grep -Fq 'not supported by the git backend' "$source_state/error"

# Backend errors stay on direct input with the typed screen available for retry.
bash "$plugin_root/manager.sh" __new-mode "$source_state" false
export TEST_WT_SWITCH_FAIL=true
if bash "$plugin_root/manager.sh" __create "$source_state" 'retry/me' </dev/null 2>"$tmp/create-error"; then
    printf 'expected Worktrunk create failure\n' >&2; exit 1
fi
unset TEST_WT_SWITCH_FAIL
[[ $(cat "$source_state/mode") == new ]]
grep -Fq 'Worktrunk could not open retry/me' "$source_state/error"
bash "$plugin_root/manager.sh" __header "$source_state" >"$tmp/retry-header"
grep -Fq 'Worktrunk could not open retry/me' "$tmp/retry-header"
grep -Fxq 'repo a · base default' "$tmp/retry-header"
! grep -Fq 'backend:' "$tmp/retry-header"
! grep -Fq "$repo_a" "$tmp/retry-header"

# fzf owns all modal transitions in one process. Search is list-only; direct
# input disables search and unbinds every printable action (including q and /).
grep -Fq -- '--bind=c:transform:' "$TEST_FZF_ARGS"
grep -Fq '__enter-repository' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=n:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=h:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=l:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=r:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=b:transform:' "$TEST_FZF_ARGS"
! grep -Fq -- '--bind=R:' "$TEST_FZF_ARGS"
grep -Fq 'clear-query+disable-search' "$TEST_FZF_ARGS"
grep -Fq 'enable-search' "$TEST_FZF_ARGS"
grep -Fq 'mode = new' "$TEST_FZF_ARGS"
grep -Fq 'change:clear-query' "$TEST_FZF_ARGS"
grep -Fq 'unbind(change)' "$TEST_FZF_ARGS"
grep -Fq 'rebind(change)' "$TEST_FZF_ARGS"
grep -Fq 'transform-footer(' "$TEST_FZF_ARGS"
grep -Fq 'show-input+clear-query+enable-search+change-prompt(/ )+change-ghost(search branches)' "$TEST_FZF_ARGS"
grep -Fq 'hide-input' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=esc:transform:' "$TEST_FZF_ARGS"
grep -Fq 'unbind(/)' "$TEST_FZF_ARGS"
grep -Fq 'unbind(q)' "$TEST_FZF_ARGS"
grep -Fq 'rebind(/)' "$TEST_FZF_ARGS"
grep -Fq 'unbind(h)' "$TEST_FZF_ARGS"
grep -Fq 'unbind(l)' "$TEST_FZF_ARGS"
! grep -Eq 'esc (repositories|sources|worktrees)' "$plugin_root/manager.sh"
! grep -Fq 'key_select' "$plugin_root/manager.sh"
! grep -Fq 'key_repository' "$plugin_root/manager.sh"
! grep -Fq 'create/force' "$TEST_FZF_ARGS"
! grep -Fq 'key_worktrees' "$plugin_root/manager.sh"

# Configured backend-neutral wizard keys participate in conflict validation and
# appear in the generated fzf actions alongside existing custom keys.
cat >"$tmp/config/config.toml" <<'EOF'
key_open = "o"
key_remove = "x"
key_force_remove = "X"
key_force_create = "N"
key_new = "m"
key_back = "u"
key_normal = "alt-n"
EOF
HERDR_PLUGIN_CONFIG_DIR="$tmp/config" run_manager
grep -Fq -- '--bind=enter:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=o:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=m:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=u:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=N:transform:' "$TEST_FZF_ARGS"
grep -Fq -- '--bind=alt-n:transform:' "$TEST_FZF_ARGS"
grep -Fq 'unbind(m)' "$TEST_FZF_ARGS"
grep -Fq 'unbind(u)' "$TEST_FZF_ARGS"
grep -Fq 'unbind(o)' "$TEST_FZF_ARGS"
! grep -Fq 'unbind(alt-n)' "$TEST_FZF_ARGS"
unset HERDR_PLUGIN_CONFIG_DIR

conflict_config="$tmp/conflict-config"; mkdir "$conflict_config"
printf '%s\n' 'key_back = "j"' >"$conflict_config/config.toml"
if HERDR_PLUGIN_CONFIG_DIR="$conflict_config" bash "$plugin_root/manager.sh" </dev/null 2>"$tmp/key-conflict"; then
    printf 'duplicate back/down keys were accepted\n' >&2; exit 1
fi
grep -Fq 'Duplicate keys: key_down and key_back both use j' "$tmp/key-conflict"

# Behavioral refresh: re-running the bound row producer observes a new worktree.
refresh_path="$tmp/repo a.refreshed"
"$git_bin" -C "$repo_a" worktree add -q -b refreshed "$refresh_path"
printf 'manage\n' >"$state/mode"
bash "$plugin_root/manager.sh" __rows "$state" >"$tmp/refreshed"
grep -Fq 'refreshed' "$tmp/refreshed"

# Removal remains Worktrunk-owned. Herdr closes only after successful removal;
# force uses the safe stale/prunable fallback flags.
: >"$TEST_CAPTURE"
b_payload=$(payload_for ' feature-b ' "$tmp/skeleton-candidates")
bash "$plugin_root/manager.sh" __remove "$state" "$b_payload" false
grep -Fq "wt <-C> <$repo_b> <remove> <--foreground> <--format=json> <feature-b>" "$TEST_CAPTURE"
grep -Fq 'herdr <workspace> <close> <w4>' "$TEST_CAPTURE"
! grep -Fq 'herdr <worktree> <remove>' "$TEST_CAPTURE"
stale_payload=$("$jq_bin" -cn --arg root "$repo_b" --arg path "$tmp/missing path" \
    '{kind:"worktree",target:"stale",path:$path,repo_root:$root,repo_name:"repo-b"}' | base64 | tr -d '\n')
: >"$TEST_CAPTURE"
bash "$plugin_root/manager.sh" __remove "$state" "$stale_payload" false
grep -Fq '<remove> <--foreground> <--format=json> <stale>' "$TEST_CAPTURE"
! grep -Fq '<--force>' "$TEST_CAPTURE"
: >"$TEST_CAPTURE"
bash "$plugin_root/manager.sh" __remove "$state" "$stale_payload" true
grep -Fq '<--force> <--force-delete> <stale>' "$TEST_CAPTURE"

# Deleting the manager's source resolves/focuses the root before closing the
# source workspace. The special status tells the popup to close.
: >"$TEST_CAPTURE"
set +e
bash "$plugin_root/manager.sh" __remove "$state" "$feature_payload" false
source_status=$?
set -e
[[ $source_status -eq 10 ]]
resolve_line=$(grep -nF "herdr <worktree> <list> <--cwd> <$repo_a>" "$TEST_CAPTURE" | cut -d: -f1)
remove_line=$(grep -nF "wt <-C> <$repo_a> <remove>" "$TEST_CAPTURE" | cut -d: -f1)
focus_line=$(grep -nF 'herdr <workspace> <focus> <w1>' "$TEST_CAPTURE" | cut -d: -f1)
close_line=$(grep -nF 'herdr <workspace> <close> <w2>' "$TEST_CAPTURE" | cut -d: -f1)
[[ $resolve_line -lt $remove_line && $remove_line -lt $focus_line && $focus_line -lt $close_line ]]

# Action failures are persisted at the public worker seam so fzf transforms,
# whose stderr/stdin are /dev/null, can render them in the popup header.
: >"$TEST_CAPTURE"
export TEST_WT_SWITCH_FAIL=true
if bash "$plugin_root/manager.sh" __open "$state" "$local_payload" '' </dev/null 2>"$tmp/open-error"; then
    printf 'expected Worktrunk open failure\n' >&2; exit 1
fi
unset TEST_WT_SWITCH_FAIL
grep -Fq 'Worktrunk could not open local-free' "$state/error"

# Worktrunk failure leaves Herdr untouched and propagates failure for fzf to
# retain/reload the current mode.
: >"$TEST_CAPTURE"
export TEST_WT_REMOVE_FAIL=true
if bash "$plugin_root/manager.sh" __remove "$state" "$b_payload" false </dev/null 2>"$tmp/remove-error"; then
    printf 'expected Worktrunk remove failure\n' >&2; exit 1
fi
unset TEST_WT_REMOVE_FAIL
grep -Fq 'Worktrunk did not remove feature-b' "$state/error"
printf 'current warning\n' >"$state/warnings.$(cat "$state/generation")"
printf 'manage help must stay out of header\n' >"$state/manage.help"
printf 'manage footer\n' >"$state/manage.footer"
bash "$plugin_root/manager.sh" __header "$state" >"$tmp/action-error-header"
grep -Fq 'Worktrunk did not remove feature-b' "$tmp/action-error-header"
grep -Fq 'current warning' "$tmp/action-error-header"
! grep -Fq 'manage help' "$tmp/action-error-header"
grep -Fq 'manage footer' <(bash "$plugin_root/manager.sh" __footer "$state")
! grep -Fq 'herdr <workspace> <close>' "$TEST_CAPTURE"

# Non-Git invocation still discovers repositories globally through Herdr.
export ACTIVE_REPO_ROOT="" MANAGER_SOURCE_CHECKOUT_PATH=""
non_git_state="$tmp/non-git-state"; new_state "$non_git_state"
bash "$plugin_root/manager.sh" __rows "$non_git_state" >"$TEST_CANDIDATES"
grep -Fq 'feature-a' "$TEST_CANDIDATES"
grep -Fq 'feature-b' "$TEST_CANDIDATES"
bash "$plugin_root/manager.sh" __enter-repository "$non_git_state" ''
bash "$plugin_root/manager.sh" __rows "$non_git_state" >"$tmp/non-git-repositories"
grep -Fq "$repo_a" "$tmp/non-git-repositories"
grep -Fq "$repo_b" "$tmp/non-git-repositories"
export ACTIVE_REPO_ROOT="$repo_a" MANAGER_SOURCE_CHECKOUT_PATH="$feature_a"

# Missing explicit dependency overrides fail with an actionable startup error.
if TIMEOUT_BIN="$tmp/not-executable" bash "$plugin_root/manager.sh" __rows "$state" 2>"$tmp/dependency-error"; then
    printf 'missing timeout override was accepted\n' >&2; exit 1
fi
grep -Fq 'timeout override is not executable' "$tmp/dependency-error"
no_enrich_config="$tmp/no-enrich-config"; mkdir -p "$no_enrich_config"
printf '%s\n' 'backend = "worktrunk"' 'enrich_backend = false' >"$no_enrich_config/config.toml"
HERDR_PLUGIN_CONFIG_DIR="$no_enrich_config" TIMEOUT_BIN="$tmp/not-executable" \
    bash "$plugin_root/manager.sh" __rows "$state" >/dev/null

# fzf failures are surfaced, and signals promptly cancel a producer that cannot
# finish naturally within the assertion window before removing its state dir.
export TEST_FZF_FAIL=true
if run_manager 2>"$tmp/fzf-error"; then printf 'fzf failure was hidden\n' >&2; exit 1; fi
unset TEST_FZF_FAIL
grep -Fq 'fzf failed with status 2' "$tmp/fzf-error"
mkdir -p "$tmp/signal-tmp"
export TEST_FZF_BLOCK=true TEST_GIT_LIST_DELAY=30 TEST_GIT_LIST_MARKER="$tmp/git-list-blocked"
TMPDIR="$tmp/signal-tmp" GIT_BIN="$tmp/git" bash "$plugin_root/manager.sh" </dev/null &
manager_pid=$!
for _ in {1..100}; do
    [[ -e $TEST_FZF_READY && -e $TEST_GIT_LIST_MARKER ]] && break
    sleep 0.05
done
[[ -e $TEST_FZF_READY && -e $TEST_GIT_LIST_MARKER ]]
[[ -n $(producer_pids_for_test) ]]
kill -TERM "$manager_pid"
set +e; wait "$manager_pid"; signal_status=$?; set -e
unset TEST_FZF_BLOCK TEST_GIT_LIST_DELAY TEST_GIT_LIST_MARKER
[[ $signal_status -eq 143 ]]
! compgen -G "$tmp/signal-tmp/forestr.*" >/dev/null
for _ in {1..100}; do [[ -z $(producer_pids_for_test) ]] && break; sleep 0.01; done
[[ -z $(producer_pids_for_test) ]]

printf 'manager tests passed\n'
