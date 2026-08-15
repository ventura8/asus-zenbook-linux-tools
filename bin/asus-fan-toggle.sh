#!/bin/bash
# ASUS ZenBook Fan Profile Toggle Helper

SYS_PLATFORM_ROOT="${SYS_PLATFORM_ROOT:-/sys/devices/platform}"

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

_source_bootstrap_helper || exit 1
_source_common_helper || exit 1


_get_fan_icon() {
    local profile_value="$1"
    case "$profile_value" in
        1) echo "power-profile-performance" ;;
        2) echo "power-profile-power-saver" ;;
        *) echo "power-profile-balanced" ;;
    esac
}

_send_notification() {
    local title="$1" msg="$2" profile_value="$3"
    local icon

    icon=$(_get_fan_icon "$profile_value")
    _send_user_notification "$title" "$msg" "$icon" "fan" "fan" "$icon"
}

_fan_sysfs_path_allowed() {
    # Print canonical path on success so callers use the resolved node.
    local node="$1" canonical platform_root
    [ -n "$node" ] || return 1
    if command -v realpath >/dev/null 2>&1; then
        canonical=$(realpath -m -- "$node" 2>/dev/null) || canonical="$node"
    else
        canonical=$(readlink -f -- "$node" 2>/dev/null) || canonical="$node"
    fi
    platform_root="${SYS_PLATFORM_ROOT:-/sys/devices/platform}"
    case "$canonical" in
        "$platform_root"/*)
            printf '%s\n' "$canonical"
            return 0
            ;;
    esac
    return 1
}

find_fan_node() {
    local allowed
    if [ -n "${ASUS_FAN_NODE:-}" ]; then
        if allowed=$(_fan_sysfs_path_allowed "$ASUS_FAN_NODE"); then
            printf '%s\n' "$allowed"
            return 0
        fi
        echo "Warning: ASUS_FAN_NODE='$ASUS_FAN_NODE' is outside" \
            "SYS_PLATFORM_ROOT; ignoring override" >&2
    fi
    _check_node "$SYS_PLATFORM_ROOT/asus-nb-wmi/throttle_thermal_policy" || \
    _check_node "$SYS_PLATFORM_ROOT/asus-wmi/throttle_thermal_policy"
}

_normalize_fan_value() {
    local value
    value="$(printf '%s' "$1" | tr -d '[:space:]')"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        if [ "$value" -gt 2 ]; then
            value=2
        fi
        printf '%s' "$value"
        return 0
    fi
    printf '0'
}

_get_next_fan_profile_name() {
    local next="$1"
    case "$next" in
        0) _asus_gettext "Balanced" ;;
        1) _asus_gettext "Performance (Boost)" ;;
        2) _asus_gettext "Quiet (Silent)" ;;
        *) _asus_gettext "Balanced" ;;
    esac
}

_ppd_name_from_value() {
    case "$1" in
        1) printf 'performance' ;;
        2) printf 'power-saver' ;;
        *) printf 'balanced' ;;
    esac
}

_value_from_ppd_name() {
    case "$1" in
        performance) printf '1' ;;
        power-saver|powersave) printf '2' ;;
        balanced) printf '0' ;;
        *)
            echo "unrecognized powerprofilesctl profile name: $1" >&2
            printf '0' ;;
    esac
}

_ASUS_FAN_USE_PPD_MODE=""
_ASUS_FAN_PPD_VALIDATED=0

_validate_asus_fan_use_ppd() {
    # Validate once at startup; store 0 / 1 / empty (auto) for later helpers.
    case "${ASUS_FAN_USE_PPD:-}" in
        "")
            _ASUS_FAN_USE_PPD_MODE=""
            ;;
        0)
            _ASUS_FAN_USE_PPD_MODE=0
            ;;
        1)
            _ASUS_FAN_USE_PPD_MODE=1
            ;;
        *)
            echo "Invalid ASUS_FAN_USE_PPD: ${ASUS_FAN_USE_PPD} (use 0 or 1)" >&2
            return 1
            ;;
    esac
    _ASUS_FAN_PPD_VALIDATED=1
    return 0
}

_ppd_enabled() {
    command -v powerprofilesctl >/dev/null 2>&1 || return 1
    if [ "$_ASUS_FAN_PPD_VALIDATED" != "1" ]; then
        _validate_asus_fan_use_ppd || return 1
    fi
    _ppd_mode_enabled
}

_ppd_mode_enabled() {
    case "${_ASUS_FAN_USE_PPD_MODE}" in
        0)
            return 1
            ;;
        1) ;;
        "")
            # Sysfs-only when ASUS_FAN_NODE is set, unless coverage forces PPD.
            if [ -n "${ASUS_FAN_NODE:-}" ]; then
                return 1
            fi
            ;;
    esac
    return 0
}

_read_ppd_profile() {
    local name
    _ppd_enabled || return 1
    name=$(powerprofilesctl get 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$name" ] || return 1
    printf '%s\n' "$name"
}

_read_current_fan_value() {
    local node="$1"
    local ppd_name raw
    ppd_name=$(_read_ppd_profile) || {
        if [ -z "$node" ]; then
            echo "Warning: No fan sysfs node; assuming Normal (0)" >&2
            printf '0'
            return 0
        fi
        raw=$(cat "$node" 2>/dev/null) || {
            echo "Warning: Failed to read fan profile from $node; assuming Normal (0)" >&2
            raw=0
        }
        _normalize_fan_value "$raw"
        return 0
    }
    _value_from_ppd_name "$ppd_name"
}

_apply_fan_profile() {
    local next="$1" node="$2"
    local ppd_name
    if _ppd_enabled; then
        ppd_name=$(_ppd_name_from_value "$next")
        if powerprofilesctl set "$ppd_name" >/dev/null 2>&1; then
            return 0
        fi
    fi
    _apply_fan_profile_sysfs "$next" "$node"
}

_apply_fan_profile_sysfs() {
    local next="$1" node="$2"
    if [ -z "$node" ]; then
        echo "Error: Failed to apply fan profile (no writable sysfs node)." >&2
        return 1
    fi
    if [ ! -w "$node" ]; then
        echo "Error: Failed to apply fan profile (no writable sysfs node)." >&2
        return 1
    fi
    if ! echo "$next" > "$node"; then
        echo "Error: Failed to write fan profile $next to $node" >&2
        return 1
    fi
}

_toggle_fan_val() {
    local node="$1"
    local curr next profile_name title msg
    curr=$(_read_current_fan_value "$node")
    next=$(( (curr + 1) % 3 ))
    _apply_fan_profile "$next" "$node" || return 1
    profile_name=$(_get_next_fan_profile_name "$next")
    title=$(_asus_gettext "Fan profile")
    msg=$(_asus_gettextf "Mode: %s" "$profile_name")
    _send_notification "$title" "$msg" "$next"
}

_prepare_ppd_fan_node() {
    local node="$1"
    if [ -n "$node" ]; then
        if [ ! -w "$node" ]; then
            node=""
        fi
    fi
    printf '%s\n' "$node"
}

_require_sysfs_fan_node() {
    local node="$1"
    if [ -z "$node" ]; then
        echo "Error: No fan control node found." >&2
        return 1
    fi
    if [ ! -w "$node" ]; then
        echo "Error: Fan control node is not writable: $node" >&2
        return 1
    fi
}

main() {
    local node=""
    _validate_asus_fan_use_ppd || return 1
    node=$(find_fan_node) || node=""
    if _ppd_enabled; then
        node=$(_prepare_ppd_fan_node "$node")
        _toggle_fan_val "$node"
        return $?
    fi
    _require_sysfs_fan_node "$node" || return 1
    _toggle_fan_val "$node"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
