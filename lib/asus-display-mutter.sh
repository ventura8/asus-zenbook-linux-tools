#!/usr/bin/env bash
# Mutter D-Bus display profile helpers for bin/asus-display-mode.sh.
# Requires asus-common.sh (_soft, _soft_write_stdout, _run_as_user, notifications).
# Caller-provided from bin/asus-display-mode.sh: _resolve_cycle_user, _resolve_user_id.

_send_display_notification() {
    local title="$1" msg="$2"
    _send_user_notification "$title" "$msg" "video-display" "display" "display" "video-display"
}

_clamp_mutter_screenpad_value() {
    local val="$1" max_path="$2" max_val
    max_val=$(cat "$max_path" 2>/dev/null) || max_val=255
    if [[ "$max_val" =~ ^[1-9][0-9]*$ ]]; then
        if [ "$val" -gt "$max_val" ]; then
            val="$max_val"
        fi
    fi
    printf '%s\n' "$val"
}

_set_screenpad_backlight() {
    local val="$1" n max_path root="${SYS_CLASS_ROOT:-/sys/class}"
    [[ "$val" =~ ^[0-9]+$ ]] || return 1
    for n in "$root/backlight/asus_screenpad/brightness" \
        "$root/leds/asus::screenpad/brightness"; do
        [ -w "$n" ] || continue
        max_path="$(dirname "$n")/max_brightness"
        val=$(_clamp_mutter_screenpad_value "$val" "$max_path")
        echo "$val" > "$n" 2>/dev/null && return 0
    done
    return 1
}

_run_display_mode_python() {
    local user="$1" bus_addr="$2" bin_root="${BIN_ROOT:-/usr/local/bin}"
    local secs="${ASUS_DISPLAY_MODE_PYTHON_TIMEOUT_SECS:-5}"
    shift 2
    case "$secs" in
        ''|*[!0-9]*|0) secs=5 ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
        _run_as_user "$user" env DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
            timeout "$secs" python3 "$bin_root/asus_display_mode.py" "$@"
        return $?
    fi
    echo "Error: Missing required 'timeout' command for Mutter display-mode helpers." >&2
    return 1
}

_mutter_screenpad_on_level() {
    # Prefer last persisted ScreenPad brightness; fall back to max (255).
    local level=""
    if declare -F _load_screenpad_brightness >/dev/null 2>&1; then
        level=$(_load_screenpad_brightness 2>/dev/null || true)
    fi
    if [[ "$level" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$level"
        return 0
    fi
    printf '%s\n' "255"
}

_apply_mutter_layout() {
    local user="$1" bus_path="$2" profile_id="$3"
    local bus_addr="unix:path=$bus_path" level
    _run_display_mode_python "$user" "$bus_addr" --apply-profile "$profile_id" || return 1
    case "$profile_id" in
        all|screenpad_external|screenpad_only)
            level=$(_mutter_screenpad_on_level)
            _soft _set_screenpad_backlight "$level"
            ;;
        *) _soft _set_screenpad_backlight 0 ;;
    esac
    return 0
}

_get_fallback_next_profile_info() {
    local cur="$1"
    case "$cur" in
        all) printf 'main_only:%s\n' "$(_asus_gettext "Main display only")" ;;
        main_only) printf 'screenpad_only:%s\n' "$(_asus_gettext "ScreenPad only")" ;;
        *) printf 'all:%s\n' "$(_asus_gettext "All displays (Main + ScreenPad)")" ;;
    esac
}

_normalize_detected_profile() {
    local detected="$1"
    if echo "$detected" | grep -Eq \
        '^(all|main_external|screenpad_external|external_only|main_only|screenpad_only)$'; then
        echo "$detected"
        return 0
    fi
    case "$detected" in
        1) echo "all" ;;
        2) echo "main_only" ;;
        3) echo "screenpad_only" ;;
        *) echo "" ;;
    esac
}

_detect_current_mutter_state() {
    local user="$1" bus_path="$2" detected normalized
    detected=$(_run_display_mode_python "$user" "unix:path=$bus_path" --detect 2>/dev/null) \
        || detected=""
    detected=$(printf '%s\n' "${detected:-}" | head -n1)
    normalized=$(_normalize_detected_profile "${detected:-}")
    [ -n "$normalized" ] && { echo "$normalized"; return 0; }
    # Timeout/D-Bus failures fall through to the default profile (do not abort under set -e).
    echo "all"
}

_get_next_profile_info() {
    local user="$1" bus_path="$2" current_profile="$3" result matched
    result=$(_run_display_mode_python "$user" "unix:path=$bus_path" \
        --next "$current_profile" 2>/dev/null) || result=""
    matched=$(echo "${result:-}" | grep -E '^[a-z_]+:.+$' | head -n1)
    [ -n "$matched" ] && { echo "$matched"; return 0; }
    _get_fallback_next_profile_info "$current_profile"
}

_mutter_cycle_preflight() {
    local user="$1" user_id="$2" bus_path="$3"
    [ -n "$user" ] && [ -n "$user_id" ] && [ -S "$bus_path" ] || return 1
    _soft _ensure_notif_id_dir "$user_id"
}

_cycle_mutter_display_mode() {
    if [ "${ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE:-0}" = "1" ]; then
        return 1
    fi
    local user user_id bus_path state_file current_state info next_state status_text
    local bus_root
    bus_root="$(_resolve_session_bus_root)"
    user=$(_resolve_cycle_user)
    user_id=$(_resolve_user_id "$user")
    bus_path="$bus_root/$user_id/bus"
    _mutter_cycle_preflight "$user" "$user_id" "$bus_path" || return 1
    state_file="${NOTIF_ID_ROOT:-/run/asus-zenbook-notif}/$user_id/asus_disp_state"
    current_state=$(_detect_current_mutter_state "$user" "$bus_path")
    info=$(_get_next_profile_info "$user" "$bus_path" "$current_state")
    next_state=$(echo "$info" | cut -d: -f1)
    status_text=$(echo "$info" | cut -d: -f2-)
    _apply_mutter_layout "$user" "$bus_path" "$next_state" || return 1
    _soft_write_stdout "$state_file" echo "$next_state"
    _send_display_notification "$(_asus_gettext "Display mode")" "$status_text"
    return 0
}
