#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
    printf 'Forestr launcher requires a script path.\n' >&2
    exit 2
fi

script=$1
shift

is_supported_bash() {
    [ -x "$1" ] && [ "$("$1" -c \
        '(( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) )) && printf supported' \
        2>/dev/null || true)" = supported ]
}

# Honor an explicit interpreter strictly. Without an override, prefer Bash from
# PATH so an installed newer version is used, with system/Homebrew fallbacks.
override=${FORESTR_BASH_BIN:-${BASH_BIN:-}}
if [ -n "$override" ]; then
    if is_supported_bash "$override"; then
        FORESTR_BASH_BIN=$override
        export FORESTR_BASH_BIN
        exec "$override" "$script" "$@"
    fi
    printf 'Forestr Bash override must be an executable Bash 3.2 or newer: %s\n' "$override" >&2
    exit 127
fi

path_bash=$(command -v bash 2>/dev/null || true)
for candidate in \
    "$path_bash" \
    /bin/bash \
    /usr/bin/bash \
    /opt/homebrew/bin/bash \
    /usr/local/bin/bash; do
    [ -n "$candidate" ] || continue
    if is_supported_bash "$candidate"; then
        FORESTR_BASH_BIN=$candidate
        export FORESTR_BASH_BIN
        exec "$candidate" "$script" "$@"
    fi
done

printf '%s\n' 'Forestr requires Bash 3.2 or newer.' >&2
exit 127
