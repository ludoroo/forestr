#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf 'Forestr requires Bash 3.2 or newer.\n' >&2
    return 2 2>/dev/null || exit 2
fi

# Plugin configuration is immutable for one command invocation. Parse it once
# into parallel indexed arrays (supported by Bash 3.2), without sourcing/eval,
# while preserving TOML's last-key-wins behavior.
FORESTR_CONFIG_KEYS=()
FORESTR_CONFIG_VALUES=()
FORESTR_CONFIG_LOADED_PATH=
FORESTR_CONFIG_VALUE=

forestr_reset_config_cache() {
    FORESTR_CONFIG_KEYS=()
    FORESTR_CONFIG_VALUES=()
    FORESTR_CONFIG_LOADED_PATH=
    FORESTR_CONFIG_VALUE=
}

forestr_load_config() {
    local config_file line key quoted bare value index found
    config_file=${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml
    [[ $FORESTR_CONFIG_LOADED_PATH == "$config_file" ]] && return 0
    FORESTR_CONFIG_KEYS=()
    FORESTR_CONFIG_VALUES=()
    FORESTR_CONFIG_LOADED_PATH=$config_file
    [[ -f $config_file ]] || return 0
    while IFS=$'\t' read -r key quoted bare; do
        [[ -n $key ]] || continue
        value=${quoted:-$bare}
        found=false
        for ((index=0; index<${#FORESTR_CONFIG_KEYS[@]}; index++)); do
            if [[ ${FORESTR_CONFIG_KEYS[$index]} == "$key" ]]; then
                FORESTR_CONFIG_VALUES[$index]=$value
                found=true
                break
            fi
        done
        if ! $found; then
            index=${#FORESTR_CONFIG_KEYS[@]}
            FORESTR_CONFIG_KEYS[$index]=$key
            FORESTR_CONFIG_VALUES[$index]=$value
        fi
    done < <(sed -nE \
        's/^[[:space:]]*([[:alnum:]_]+)[[:space:]]*=[[:space:]]*("([^"]*)"|([^[:space:]#"]+))[[:space:]]*(#.*)?$/\1\t\3\t\4/p' \
        "$config_file")
}

forestr_find_config_value() {
    local key=$1 index
    forestr_load_config
    FORESTR_CONFIG_VALUE=
    for ((index=0; index<${#FORESTR_CONFIG_KEYS[@]}; index++)); do
        if [[ ${FORESTR_CONFIG_KEYS[$index]} == "$key" ]]; then
            FORESTR_CONFIG_VALUE=${FORESTR_CONFIG_VALUES[$index]}
            return 0
        fi
    done
}

forestr_config_value() {
    forestr_find_config_value "$1"
    printf '%s\n' "$FORESTR_CONFIG_VALUE"
}

forestr_config_assign() {
    local destination=$1 key=$2 default=$3
    forestr_find_config_value "$key"
    printf -v "$destination" '%s' "${FORESTR_CONFIG_VALUE:-$default}"
}

forestr_find_executable() {
    local name=$1 override=${2:-} candidate

    if [[ -n $override && -x $override ]]; then
        printf '%s\n' "$override"
        return 0
    fi
    if candidate=$(command -v "$name" 2>/dev/null) && [[ -x $candidate ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in \
        "$HOME/.local/bin/$name" \
        "/home/linuxbrew/.linuxbrew/bin/$name" \
        "/opt/homebrew/bin/$name" \
        "/usr/local/bin/$name" \
        "/usr/bin/$name"; do
        if [[ -x $candidate ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

forestr_context_value() {
    local key=$1 context=${HERDR_PLUGIN_CONTEXT_JSON:-}
    [[ -n $context ]] || context='{}'
    "${JQ_BIN:-jq}" -r --arg key "$key" '.[$key] // empty' <<<"$context"
}

forestr_foreground_cwd() {
    local herdr=$1 pane_id=$2 workspace_id=$3 panes cwd

    if [[ -n $pane_id ]]; then
        panes=$("$herdr" pane list --workspace "$workspace_id" 2>/dev/null || true)
        cwd=$("${JQ_BIN:-jq}" -r --arg pane "$pane_id" '
            .result.panes[]?
            | select(.pane_id == $pane)
            | .foreground_cwd // .cwd // empty
        ' <<<"$panes" | head -n 1)
        if [[ -n $cwd ]]; then
            printf '%s\n' "$cwd"
            return 0
        fi
    fi

    forestr_context_value focused_pane_cwd
}

forestr_popup_dimension() {
    local key=$1 default=$2 value
    value=$(forestr_config_value "$key")
    case $value in
        "") printf '%s\n' "$default" ;;
        *[!0-9%]*|*%?*|%*) printf '%s\n' "$default" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

forestr_create_scope() {
    local requested=${1:-config} configured
    if [[ $requested == config ]]; then
        configured=$(forestr_config_value create_scope)
        requested=${configured:-local}
    fi
    case $requested in
        local|remote|both) printf '%s\n' "$requested" ;;
        *) printf '%s\n' local ;;
    esac
}

forestr_config_bool() {
    local key=$1 default=$2 value
    value=$(forestr_config_value "$key")
    case $value in
        true|false) printf '%s\n' "$value" ;;
        *) printf '%s\n' "$default" ;;
    esac
}

forestr_config_positive_integer() {
    local key=$1 default=$2 value
    value=$(forestr_config_value "$key")
    case $value in
        ""|0|0[0-9]*|*[!0-9]*) printf '%s\n' "$default" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

forestr_config_concurrency() {
    local key=$1 default=$2 value
    value=$(forestr_config_value "$key")
    case $value in
        1|2) printf '%s\n' "$value" ;;
        *) printf '%s\n' "$default" ;;
    esac
}

forestr_key() {
    local name=$1 default=$2 value
    value=$(forestr_config_value "$name")
    value=${value:-$default}
    case $value in
        [[:alnum:]]|[/?.]|enter|esc|home|end|ctrl-[a-z]|alt-[a-z])
            printf '%s\n' "$value"
            ;;
        *)
            printf '\033[31mInvalid %s key: %s.\033[0m\n' "$name" "$value" >&2
            return 1
            ;;
    esac
}
