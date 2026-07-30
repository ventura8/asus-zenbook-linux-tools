#!/bin/bash
# ASUS ZenBook ScreenPad Backlight Toggle Helper

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

_apply_screenpad_off() {
    local node="$1" curr="$2"
    if ! _save_screenpad_brightness "$curr"; then
        echo "Warning: failed to save ScreenPad brightness before off ($curr)." >&2
    fi
    _screenpad_write_verified "$node" 0
}

_apply_screenpad_on() {
    local node="$1" max_val="$2" restore
    restore=$(_soft _load_screenpad_brightness)
    case "$restore" in
        ''|*[!0-9]*|0)
            restore="$max_val"
            ;;
    esac
    if [ "$restore" -gt "$max_val" ]; then
        restore="$max_val"
    fi
    _screenpad_write_verified "$node" "$restore"
}

_toggle_screenpad_val() {
    local node="$1"
    local curr status_text max_val icon state
    curr=$(_read_screenpad_value "$node")
    max_val=$(_read_screenpad_max_value "$node")
    if [ "$curr" -gt 0 ]; then
        _apply_screenpad_off "$node" "$curr" || return 1
        status_text=$(_asus_pgettext "ScreenPad backlight state" "Off")
        state="off"
    else
        _apply_screenpad_on "$node" "$max_val" || return 1
        status_text=$(_asus_pgettext "ScreenPad backlight state" "On")
        state="on"
    fi
    icon=$(_resolve_screenpad_notification_icon "$state")
    _send_user_notification "$(_asus_gettext "ScreenPad backlight")" "$status_text" \
        "$icon" "screenpad" "screenpad" "$icon"
}

main() {
    local node
    node=$(find_screenpad_node || true)
    if [ -z "$node" ]; then
        echo "Error: No ScreenPad control node found." >&2
        return 1
    fi

    if [ ! -w "$node" ]; then
        echo "Error: ScreenPad control node is not writable: $node" >&2
        return 1
    fi

    _toggle_screenpad_val "$node"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
