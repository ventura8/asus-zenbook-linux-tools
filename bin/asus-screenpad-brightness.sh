#!/bin/bash
# ASUS ZenBook ScreenPad brightness helper (up/down/set/get).

_source_bootstrap_helper() {
    local script_dir installed_lib
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ "${ASUS_FORCE_INSTALLED_LIB:-0}" != "1" ] \
        && [ -f "$script_dir/../lib/asus-bootstrap.sh" ]; then
        . "$script_dir/../lib/asus-bootstrap.sh"
        return 0
    fi
    installed_lib="${ASUS_INSTALLED_LIB_DIR:-/usr/local/lib/asus-zenbook-linux-tools}"
    if [ -f "$installed_lib/asus-bootstrap.sh" ]; then
        . "$installed_lib/asus-bootstrap.sh"
        return 0
    fi
    echo "Error: Missing lib/asus-bootstrap.sh" >&2
    return 1
}

_source_screenpad_helper() {
    if [ -f "${_ASUS_LIB_DIR}/asus-screenpad.sh" ]; then
        # shellcheck source=lib/asus-screenpad.sh
        . "${_ASUS_LIB_DIR}/asus-screenpad.sh"
        return 0
    fi
    echo "Error: Missing lib/asus-screenpad.sh" >&2
    return 1
}

_source_bootstrap_helper || exit 1
_source_common_helper || exit 1
_source_screenpad_helper || exit 1

_usage_screenpad_brightness() {
    echo "Usage: asus-screenpad-brightness.sh up|down|get|set <percent|raw>" >&2
}

_require_screenpad_node() {
    local node
    node=$(find_screenpad_node || true)
    if [ -z "$node" ]; then
        echo "Error: No ScreenPad control node found." >&2
        return 1
    fi
    printf '%s\n' "$node"
}

_require_writable_screenpad_node() {
    local node
    node=$(_require_screenpad_node) || return 1
    if [ ! -w "$node" ]; then
        echo "Error: ScreenPad control node is not writable: $node" >&2
        return 1
    fi
    printf '%s\n' "$node"
}

_brightness_after_delta() {
    local node="$1" delta="$2" max_val="$3"
    local curr next
    curr=$(_read_screenpad_value "$node")
    if [ "$curr" -le 0 ]; then
        curr=1
    fi
    next=$((curr + delta))
    next=$(_clamp_screenpad_brightness "$next" "$max_val")
    _write_screenpad_brightness "$node" "$next" || return 1
    _notify_screenpad_brightness "$next" "$max_val"
}

_screenpad_brightness_up() {
    local node="$1" max_val step
    max_val=$(_read_screenpad_max_value "$node")
    step=$(_screenpad_step_size "$max_val")
    _brightness_after_delta "$node" "$step" "$max_val"
}

_screenpad_brightness_down() {
    local node="$1" max_val step
    max_val=$(_read_screenpad_max_value "$node")
    step=$(_screenpad_step_size "$max_val")
    _brightness_after_delta "$node" "$((-step))" "$max_val"
}

_parse_screenpad_set_value() {
    local raw="$1" max_val="$2"
    local value pct
    max_val=$((10#$max_val))
    if [[ "$raw" =~ ^([0-9]+)%$ ]]; then
        pct=$((10#${BASH_REMATCH[1]}))
        value=$(( (pct * max_val + 50) / 100 ))
        _clamp_screenpad_brightness "$value" "$max_val"
        return 0
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        _clamp_screenpad_brightness "$((10#$raw))" "$max_val"
        return 0
    fi
    return 1
}

_screenpad_brightness_set() {
    local node="$1" raw="$2"
    local max_val value
    max_val=$(_read_screenpad_max_value "$node")
    value=$(_parse_screenpad_set_value "$raw" "$max_val") || {
        echo "Error: Invalid brightness value: $raw" >&2
        return 1
    }
    _write_screenpad_brightness "$node" "$value" || return 1
    _notify_screenpad_brightness "$value" "$max_val"
}

_screenpad_brightness_get() {
    local node="$1"
    local curr max_val percent
    curr=$(_read_screenpad_value "$node")
    max_val=$(_read_screenpad_max_value "$node")
    percent=$(_screenpad_percent "$curr" "$max_val")
    printf 'brightness=%s max=%s percent=%s\n' "$curr" "$max_val" "$percent"
}

_dispatch_screenpad_brightness_cmd() {
    local cmd="$1" node="$2" arg="$3"
    # Caller (main) validates cmd; helpers assume a known token.
    case "$cmd" in
        up) _screenpad_brightness_up "$node" ;;
        down) _screenpad_brightness_down "$node" ;;
        get) _screenpad_brightness_get "$node" ;;
        set) _dispatch_screenpad_set "$node" "$arg" ;;
    esac
}

_dispatch_screenpad_set() {
    local node="$1" arg="$2"
    [ -n "$arg" ] || { _usage_screenpad_brightness; return 1; }
    _screenpad_brightness_set "$node" "$arg"
}

_require_node_for_brightness_cmd() {
    local cmd="$1"
    # Caller (main) validates cmd; helpers assume a known token.
    case "$cmd" in
        set|up|down) _require_writable_screenpad_node ;;
        get) _require_screenpad_node ;;
    esac
}

main() {
    local node cmd="${1:-}"
    case "$cmd" in
        set|up|down|get) ;;
        *)
            _usage_screenpad_brightness
            return 1
            ;;
    esac
    node=$(_require_node_for_brightness_cmd "$cmd") || return 1
    _dispatch_screenpad_brightness_cmd "$cmd" "$node" "${2:-}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
