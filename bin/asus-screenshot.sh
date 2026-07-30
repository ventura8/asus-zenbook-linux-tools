#!/bin/bash
# Triggers an interactive region screenshot for the active session user.
# Order: preferred DE → GNOME Shell/keychord → KDE Spectacle → XFCE → portal.

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

get_dbus_bus_path() {
    local target_user="$1"
    local user_id bus_root bus_path
    user_id=$(id -u "$target_user" 2>/dev/null)
    [ -z "$user_id" ] && { echo "Error: Could not determine UID for user $target_user." >&2; return 1; }
    bus_root="${RUN_USER_ROOT:-/run/user}"
    bus_path="$bus_root/$user_id/bus"
    [ ! -S "$bus_path" ] && { echo "Error: D-Bus socket $bus_path does not exist." >&2; return 1; }
    echo "$bus_path"
}

_screenshot_user_env() {
    _asus_session_launch_env "$1" "$2" "$3" "${RUN_USER_ROOT:-/run/user}" "$4"
}

_screenshot_timeout_secs() {
    # Positive int for gdbus/portal (and related) timeouts; default 8.
    local raw="${1:-8}"
    [[ "$raw" =~ ^[1-9][0-9]*$ ]] || raw=8
    printf '%s\n' "$raw"
}

_gdbus_as_user() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    local gnome_timeout
    gnome_timeout=$(_screenshot_timeout_secs "${ASUS_GNOME_SCREENSHOT_TIMEOUT_SECS:-8}")
    shift 3
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _run_as_user "$target_user" env "${env_args[@]}" \
        timeout "$gnome_timeout" gdbus call --session "$@"
}

_trigger_gnome_dbus_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    # Older GNOME exposed ShowScreenshotUI on org.gnome.Shell.
    if _gdbus_as_user "$target_user" "$target_uid" "$bus_addr" \
        --dest org.gnome.Shell --object-path /org/gnome/Shell \
        --method org.gnome.Shell.ShowScreenshotUI >/dev/null 2>&1; then
        return 0
    fi
    # GNOME 46+ moved interactive capture here; may be AccessDenied for peers.
    # Keep stderr visible on failure so callers/tests can diagnose gdbus errors.
    _gdbus_as_user "$target_user" "$target_uid" "$bus_addr" \
        --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
        --method org.gnome.Shell.Screenshot.InteractiveScreenshot >/dev/null
}

_ydotool_key_as_user() {
    local target_user="$1" sock="$2"
    shift 2
    if [ -n "$sock" ]; then
        _run_as_user "$target_user" env YDOTOOL_SOCKET="$sock" ydotool key "$@" 2>/dev/null
        return $?
    fi
    _run_as_user "$target_user" ydotool key "$@" 2>/dev/null
}

_ydotool_socket_canonical() {
    local sock="$1" canonical
    if command -v realpath >/dev/null 2>&1; then
        canonical=$(realpath -m -- "$sock" 2>/dev/null) || canonical="$sock"
    else
        canonical=$(readlink -f -- "$sock" 2>/dev/null) || canonical="$sock"
    fi
    printf '%s\n' "$canonical"
}

_ydotool_socket_allowed() {
    local sock="$1" target_uid="$2" runtime_root canonical
    [ -n "$sock" ] || return 1
    [ -S "$sock" ] || return 1
    [ "${ASUS_TEST_MODE:-0}" = "1" ] && [ "${ASUS_YDOTOOL_SOCKET_ALLOW:-0}" = "1" ] && return 0
    runtime_root="${RUN_USER_ROOT:-/run/user}/$target_uid"
    canonical=$(_ydotool_socket_canonical "$sock")
    case "$canonical" in
        "$runtime_root"/*) return 0 ;;
    esac
    return 1
}

_resolve_ydotool_sock() {
    local target_uid="$1" sock
    if [ -n "${YDOTOOL_SOCKET:-}" ] && _ydotool_socket_allowed "$YDOTOOL_SOCKET" "$target_uid"; then
        printf '%s' "$YDOTOOL_SOCKET"
        return 0
    fi
    for sock in \
        "${RUN_USER_ROOT:-/run/user}/$target_uid/.ydotool_socket" \
        /run/ydotoold/socket; do
        [ -S "$sock" ] && { printf '%s' "$sock"; return 0; }
    done
    return 1
}

_trigger_gnome_ydotool() {
    local target_user="$1" sock="$2"
    command -v ydotool >/dev/null 2>&1 || return 1
    # Do not call ShowScreenshotUI after a successful chord: that queues a second
    # selector, so Esc dismisses one and the next appears (touchpad Share path).
    # Legacy Share / Fn+F11 chord (install also binds this for GNOME).
    _ydotool_key_as_user "$target_user" "$sock" 125:1 42:1 31:1 31:0 42:0 125:0 && return 0
    # KEY_PRINT (210) — Print / show-screenshot-ui fallback on Ubuntu GNOME.
    _ydotool_key_as_user "$target_user" "$sock" 210:1 210:0 && return 0
    # KEY_SYSRQ (99) — SysRq screenshot chord when Print is unbound.
    _ydotool_key_as_user "$target_user" "$sock" 99:1 99:0
}

_merge_share_accelerators() {
    local current="$1"
    # Trim trailing whitespace so ${current%]} strips a trailing ']' reliably.
    current="${current%"${current##*[![:space:]]}"}"
    # Caller skips '' / '@as []'; keep '[]' for non-empty malformed recovery.
    case "$current" in
        '[]')
            printf "%s\n" "['<Super><Shift>s', '<Super><Shift>S']"
            ;;
        *)
            printf "%s, '<Super><Shift>s', '<Super><Shift>S']\n" "${current%]}"
            ;;
    esac
}

_backup_gnome_share_keybinding() {
    local target_uid="$1" current="$2" state_root backup_file
    state_root="${STATE_DIR:-/var/lib/asus-zenbook-linux-tools}"
    backup_file="${state_root}/${target_uid}/orig_show_screenshot_ui"
    [ -f "$backup_file" ] && return 0
    [ -n "$current" ] || return 0
    mkdir -p "${state_root}/${target_uid}" 2>/dev/null || return 1
    printf '%s\n' "$current" > "$backup_file" 2>/dev/null || return 1
}

_gnome_share_keybinding_needs_merge() {
    local current="$1"
    case "$current" in
        ''|'@as []') return 1 ;;
        *'<Super><Shift>s'*|*'<Super><Shift>S'*) return 1 ;;
    esac
    case "$current" in
        '['*|@as\ \[*) return 0 ;;
    esac
    return 1
}

_ensure_gnome_share_keybinding() {
    local target_user="$1" target_uid="$2" bus_addr="$3" current updated set_status
    local gnome_timeout
    gnome_timeout=$(_screenshot_timeout_secs "${ASUS_GNOME_SCREENSHOT_TIMEOUT_SECS:-8}")
    # Share/Fn+F11 historically emit Super+Shift+S; ensure GNOME accepts it even
    # when the DESKTOP component was not installed.
    current=$(_run_as_user "$target_user" env XDG_RUNTIME_DIR="${RUN_USER_ROOT:-/run/user}/$target_uid" \
        DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        timeout "$gnome_timeout" gsettings get org.gnome.shell.keybindings show-screenshot-ui \
        2>/dev/null) || current=""
    _gnome_share_keybinding_needs_merge "$current" || return 0
    _backup_gnome_share_keybinding "$target_uid" "$current" || return 1
    updated=$(_merge_share_accelerators "$current")
    set_status=0
    _run_as_user "$target_user" env XDG_RUNTIME_DIR="${RUN_USER_ROOT:-/run/user}/$target_uid" \
        DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        timeout "$gnome_timeout" gsettings set org.gnome.shell.keybindings show-screenshot-ui \
        "$updated" >/dev/null 2>&1 || set_status=$?
    return "$set_status"
}

_trigger_gnome_xdotool() {
    local target_user="$1" target_uid="$2" bus_addr="$3" display_val
    local -a env_args
    display_val=$(asus_session_env_value "DISPLAY" "$target_user")
    [ -n "$display_val" ] || display_val="${DISPLAY:-:0}"
    command -v xdotool >/dev/null 2>&1 || return 1
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _run_as_user "$target_user" env "${env_args[@]}" \
        DISPLAY="$display_val" xdotool key --clearmodifiers 'super+shift+s' >/dev/null 2>&1 && return 0
    _run_as_user "$target_user" env "${env_args[@]}" \
        DISPLAY="$display_val" xdotool key --clearmodifiers Print >/dev/null 2>&1
}

_trigger_gnome_keychord() {
    local target_user="$1" target_uid="$2" bus_addr="$3" sock
    local -a env_args
    if [ "${ASUS_SCREENSHOT_DISABLE_KEYCHORD:-0}" = "1" ]; then
        return 1
    fi
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _run_as_user "$target_user" env "${env_args[@]}" \
        systemctl --user start ydotool >/dev/null 2>&1 || true
    sock=$(_resolve_ydotool_sock "$target_uid" || true)
    _trigger_gnome_ydotool "$target_user" "$sock" && return 0
    _trigger_gnome_xdotool "$target_user" "$target_uid" "$bus_addr"
}

_trigger_gnome_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    _trigger_gnome_dbus_screenshot "$target_user" "$target_uid" "$bus_addr" && return 0
    # Keychord before portal: matches prior Share/Fn+F11 Super+Shift+S UX.
    _trigger_gnome_keychord "$target_user" "$target_uid" "$bus_addr"
}

_trigger_spectacle_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _launch_background_with_env "$target_user" "spectacle" \
        'command -v spectacle >/dev/null' \
        'exec spectacle --region --nonotify </dev/null >/dev/null 2>&1 & echo $!' \
        "${env_args[@]}"
}

_trigger_xfce_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _launch_background_with_env "$target_user" "xfce4-screenshooter" \
        'command -v xfce4-screenshooter >/dev/null' \
        'exec xfce4-screenshooter -r </dev/null >/dev/null 2>&1 & echo $!' \
        "${env_args[@]}"
}

_trigger_lxqt_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _launch_background_with_env "$target_user" "screengrab" \
        'command -v screengrab >/dev/null' \
        'exec screengrab -r </dev/null >/dev/null 2>&1 & echo $!' \
        "${env_args[@]}"
}

_trigger_cinnamon_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _launch_background_with_env "$target_user" "gnome-screenshot" \
        'command -v gnome-screenshot >/dev/null' \
        'exec gnome-screenshot --area </dev/null >/dev/null 2>&1 & echo $!' \
        "${env_args[@]}"
}

_trigger_mate_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _launch_background_with_env "$target_user" "mate-screenshot" \
        'command -v mate-screenshot >/dev/null' \
        'exec mate-screenshot --area </dev/null >/dev/null 2>&1 & echo $!' \
        "${env_args[@]}"
}

_trigger_portal_screenshot() {
    local target_user="$1" target_uid="$2" bus_addr="$3"
    local -a env_args
    local portal_timeout
    portal_timeout=$(_screenshot_timeout_secs "${ASUS_PORTAL_SCREENSHOT_TIMEOUT_SECS:-8}")
    _screenshot_user_env env_args "$target_user" "$target_uid" "$bus_addr"
    _run_as_user "$target_user" env "${env_args[@]}" timeout "$portal_timeout" gdbus call \
        --session \
        --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.Screenshot.Screenshot \
        "" "{'interactive': <true>}" >/dev/null 2>&1
}

declare -A _SCREENSHOT_FN_BY_FAMILY
_SCREENSHOT_FN_BY_FAMILY[gnome]=_trigger_gnome_screenshot
_SCREENSHOT_FN_BY_FAMILY[kde]=_trigger_spectacle_screenshot
_SCREENSHOT_FN_BY_FAMILY[xfce]=_trigger_xfce_screenshot
_SCREENSHOT_FN_BY_FAMILY[lxqt]=_trigger_lxqt_screenshot
_SCREENSHOT_FN_BY_FAMILY[cinnamon]=_trigger_cinnamon_screenshot
_SCREENSHOT_FN_BY_FAMILY[mate]=_trigger_mate_screenshot

_try_family_screenshot() {
    local family="$1" target_user="$2" target_uid="$3" bus_addr="$4" screenshot_fn
    screenshot_fn="${_SCREENSHOT_FN_BY_FAMILY[$family]-}"
    [ -n "$screenshot_fn" ] || return 1
    "$screenshot_fn" "$target_user" "$target_uid" "$bus_addr"
}

_try_fallback_screenshots() {
    local target_user="$1" target_uid="$2" bus_addr="$3" family="$4" other
    for other in gnome kde xfce lxqt cinnamon mate; do
        [ "$other" = "$family" ] && continue
        _try_family_screenshot "$other" "$target_user" "$target_uid" "$bus_addr" && return 0
    done
    _trigger_portal_screenshot "$target_user" "$target_uid" "$bus_addr"
}

trigger_screenshot_ui() {
    local target_user="$1" bus_path="$2"
    local bus_addr="unix:path=$bus_path" target_uid family
    target_uid=$(id -u "$target_user" 2>/dev/null) || return 1
    family=$(asus_desktop_family "$target_user")
    if [ "$family" = gnome ]; then
        _ensure_gnome_share_keybinding "$target_user" "$target_uid" "$bus_addr"
    fi
    if _try_family_screenshot "$family" "$target_user" "$target_uid" "$bus_addr"; then
        return 0
    fi
    _try_fallback_screenshots "$target_user" "$target_uid" "$bus_addr" "$family"
}

main() {
    local target_user bus_path
    target_user=$(find_active_session_user)
    [ -z "$target_user" ] && { echo "Error: No active graphical session found." >&2; return 1; }
    bus_path=$(get_dbus_bus_path "$target_user") || return $?
    trigger_screenshot_ui "$target_user" "$bus_path"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
