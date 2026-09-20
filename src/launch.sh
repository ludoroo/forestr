#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    printf 'Forestr launcher requires a script path.\n' >&2
    exit 2
fi

script=$1
shift

# macOS ships Bash 3.2. Honor an explicit interpreter strictly, then try the
# standard Homebrew locations before falling back to PATH/system Bash.
override=${FORESTR_BASH_BIN:-${BASH_BIN:-}}
if [ -n "$override" ]; then
    if [ -x "$override" ] && "$override" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
        FORESTR_BASH_BIN=$override
        export FORESTR_BASH_BIN
        exec "$override" "$script" "$@"
    fi
    printf 'Forestr Bash override must be an executable Bash 4 or newer: %s\n' "$override" >&2
    exit 127
fi

path_bash=$(command -v bash 2>/dev/null || true)
for candidate in \
    /opt/homebrew/bin/bash \
    /usr/local/bin/bash \
    "$path_bash" \
    /bin/bash \
    /usr/bin/bash; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    if "$candidate" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
        FORESTR_BASH_BIN=$candidate
        export FORESTR_BASH_BIN
        exec "$candidate" "$script" "$@"
    fi
done

printf '%s\n' 'Forestr requires Bash 4 or newer. On macOS, install it with: brew install bash' >&2
exit 127
