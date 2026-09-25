#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_root"

bash_bin=${FORESTR_TEST_BASH_BIN:-${BASH:-bash}}
bash_bin=$(command -v "$bash_bin" 2>/dev/null || true)
if [[ -z $bash_bin || ! -x $bash_bin ]] || [[ $("$bash_bin" -c \
    '(( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) )) && printf supported' \
    2>/dev/null || true) != supported ]]; then
    printf 'Tests require Bash 3.2 or newer (FORESTR_TEST_BASH_BIN=%s).\n' \
        "${FORESTR_TEST_BASH_BIN:-${BASH:-bash}}" >&2
    exit 2
fi
test_bin_dir=$(mktemp -d)
trap 'rm -rf "$test_bin_dir"' EXIT
ln -s "$bash_bin" "$test_bin_dir/bash"
PATH="$test_bin_dir:$PATH"
export PATH
printf '==> Bash runtime: %s (%s.%s)\n' "$bash_bin" \
    "$("$bash_bin" -c 'printf %s "${BASH_VERSINFO[0]}"')" \
    "$("$bash_bin" -c 'printf %s "${BASH_VERSINFO[1]}"')"

printf '%s\n' '==> Bash syntax'
while IFS= read -r script; do
    "$bash_bin" -n "$script"
done < <(find . src tests -maxdepth 1 -type f -name '*.sh' -print | sort)

printf '%s\n' '==> TOML parsing'
python3 - <<'PY'
from pathlib import Path
import tomllib

for path in sorted(Path('.').glob('*.toml')):
    with path.open('rb') as file:
        tomllib.load(file)
    print(f'parsed {path}')
PY

printf '%s\n' '==> Product identity'
stale_hyphen='ludo''-forestr'
stale_dot='ludo''\.forestr'
if grep -RInE "$stale_hyphen|$stale_dot" . --exclude-dir=.git; then
    printf '%s\n' 'stale copied-plugin identity found' >&2
    exit 1
fi

printf '%s\n' '==> Behavior tests'
while IFS= read -r test_file; do
    printf '%s\n' "--- $test_file"
    "$bash_bin" "$test_file"
done < <(find tests -maxdepth 1 -type f -name '*.test.sh' -print | sort)

printf '%s\n' '==> Git whitespace checks'
while IFS= read -r -d '' path; do
    status=0
    output=$(git diff --no-index --check -- /dev/null "$path" 2>&1) || status=$?
    if (( status > 1 )); then
        printf '%s\n' "$output" >&2
        exit 1
    fi
done < <(git ls-files --cached --others --exclude-standard -z)
git diff --check -- .
git diff --cached --check -- .

printf '%s\n' 'All checks passed'
