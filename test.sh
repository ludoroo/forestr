#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_root"

printf '%s\n' '==> Bash syntax'
while IFS= read -r script; do
    bash -n "$script"
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
    bash "$test_file"
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
