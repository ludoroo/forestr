#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'Forestr requires Bash 4 or newer (associative arrays are used).\n' >&2
    return 2 2>/dev/null || exit 2
fi

# Plugin configuration is immutable for one command invocation. Parse it once
# into data (never shell source/eval it), while preserving TOML's last-key-wins
# behavior used by the previous reader.
declare -gA FORESTR_CONFIG_VALUES=()
declare -g FORESTR_CONFIG_LOADED_PATH=

forestr_reset_config_cache() {
    FORESTR_CONFIG_VALUES=()
    FORESTR_CONFIG_LOADED_PATH=
}

forestr_load_config() {
    local config_file line key quoted bare
    config_file=${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml
    [[ $FORESTR_CONFIG_LOADED_PATH == "$config_file" ]] && return 0
    FORESTR_CONFIG_VALUES=()
    FORESTR_CONFIG_LOADED_PATH=$config_file
    [[ -f $config_file ]] || return 0
    while IFS=$'\t' read -r key quoted bare; do
        [[ -n $key ]] || continue
        FORESTR_CONFIG_VALUES["$key"]=${quoted:-$bare}
    done < <(sed -nE \
        's/^[[:space:]]*([[:alnum:]_]+)[[:space:]]*=[[:space:]]*("([^"]*)"|([^[:space:]#"]+))[[:space:]]*(#.*)?$/\1\t\3\t\4/p' \
        "$config_file")
}

forestr_config_value() {
    local key=$1
    forestr_load_config
    printf '%s\n' "${FORESTR_CONFIG_VALUES[$key]:-}"
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
