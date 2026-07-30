#!/bin/bash
# Display-mode helper library (sourced by bin/asus-display-mode.sh).

_resolve_user_id() {
    local user="$1"
    if echo "$user" | grep -Eq '^[0-9]+$'; then
        echo "$user"
        return 0
    fi
    id -u "$user" 2>/dev/null || true
}

_resolve_cycle_user() {
    local user
    user=$(find_active_session_user 2>/dev/null)
    user="${user:-${SUDO_USER:-}}"
    user="${user:-$(id -un 2>/dev/null)}"
    echo "${user:-${USER:-}}"
}

_ydotool_key() {
    local active_user="$1" sock="$2"
    shift 2
    if [ -n "$active_user" ] && [ -n "$sock" ]; then
        _run_as_user "$active_user" env YDOTOOL_SOCKET="$sock" ydotool key "$@" 2>/dev/null
        return $?
    fi
    if [ -n "$sock" ]; then
        YDOTOOL_SOCKET="$sock" ydotool key "$@" 2>/dev/null
        return $?
    fi
    if [ -n "$active_user" ]; then
        _run_as_user "$active_user" ydotool key "$@" 2>/dev/null
        return $?
    fi
    ydotool key "$@" 2>/dev/null
}

_xdotool_cmd() {
    local active_user="$1" display_val="$2"
    shift 2
    if [ -n "$active_user" ]; then
        _run_as_user "$active_user" env DISPLAY="$display_val" xdotool "$@" 2>/dev/null
        return $?
    fi
    env DISPLAY="$display_val" xdotool "$@" 2>/dev/null
}

_release_osd_modifiers() {
    local prefix="$1" active_user target backend
    if _osd_cancel_in_progress "$prefix"; then
        _osd_cleanup_marker_files "$prefix"
        return 0
    fi
    if ! _read_ctx "$prefix" active_user target backend; then
        _osd_cleanup_marker_files "$prefix"
        return 0
    fi
    if [ "$backend" = "xdotool" ]; then
        # Super up first so Mutter applies the OSD selection, then clear peers.
        _soft _xdotool_cmd "$active_user" "${target:-:0}" keyup Super_L Super_R
        _soft _xdotool_cmd "$active_user" "${target:-:0}" keyup \
            Shift_L Shift_R Control_L Control_R Alt_L Alt_R
    else
        _soft _ydotool_key "$active_user" "$target" 125:0 126:0
        _soft _ydotool_key "$active_user" "$target" 42:0 54:0 29:0 97:0 56:0 100:0
    fi
    _osd_cleanup_marker_files "$prefix"
}

_dismiss_osd_modifiers() {
    # Esc cancel: Esc tap then Super-up on the *same* injection backend that holds
    # Super. Cross-device Esc (AT proxy) + ydotool Super-up races and can apply.
    local prefix="$1" active_user target backend
    if ! _read_ctx "$prefix" active_user target backend; then
        _osd_cleanup_marker_files "$prefix"
        _clear_osd_cancel_flag "$prefix"
        return 0
    fi
    # Stop idle watchdog apply (Super-up without Esc) from racing this cancel path.
    _mark_osd_cancel_in_progress "$prefix"
    _soft rm -f "${prefix}.session"
    if [ "$backend" = "xdotool" ]; then
        _soft _xdotool_cmd "$active_user" "${target:-:0}" key --clearmodifiers Escape
        _osd_cancel_pause
        _soft _xdotool_cmd "$active_user" "${target:-:0}" keyup Super_L Super_R
        _soft _xdotool_cmd "$active_user" "${target:-:0}" keyup \
            Shift_L Shift_R Control_L Control_R Alt_L Alt_R
    else
        # KEY_ESC=1; Super L/R = 125/126 (same device stream as sticky Super-down).
        _soft _ydotool_key "$active_user" "$target" 1:1 1:0
        _osd_cancel_pause
        _soft _ydotool_key "$active_user" "$target" 125:0 126:0
        _soft _ydotool_key "$active_user" "$target" 42:0 54:0 29:0 97:0 56:0 100:0
        _osd_cancel_pause
        _soft _ydotool_key "$active_user" "$target" 42:0 54:0 29:0 97:0 56:0 100:0
    fi
    _osd_cleanup_marker_files "$prefix"
    _clear_osd_cancel_flag "$prefix"
}

_osd_cancel_pause() {
    sleep 0.05 2>/dev/null || sleep 1
}

_clear_stuck_non_super_modifiers() {
    # Stuck Shift/Ctrl/Alt makes Super+P look like Super+Shift+P (no OSD).
    local active_user="$1" target="$2" backend="$3"
    if [ "$backend" = "xdotool" ]; then
        _soft _xdotool_cmd "$active_user" "${target:-:0}" keyup \
            Shift_L Shift_R Control_L Control_R Alt_L Alt_R
        return 0
    fi
    _soft _ydotool_key "$active_user" "$target" 42:0 54:0 29:0 97:0 56:0 100:0
}

_start_ydotool_user_unit() {
    local active_user="$1" user_id="$2"
    [ -n "$user_id" ] && [ -n "$active_user" ] || return 0
    # Ubuntu/Debian ship user unit "ydotool" (ExecStart=ydotoold). Prefer enable
    # --now so a missing prior enable cannot leave Display Toggle on Mutter-only.
    _soft _run_as_user "$active_user" env \
        "XDG_RUNTIME_DIR=$DBUS_BUS_ROOT/$user_id" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=$DBUS_BUS_ROOT/$user_id/bus" \
        systemctl --user enable --now ydotool
}

_find_ydotool_socket() {
    # Locals must not reuse caller nameref names (_yd_user → active_user).
    local sock_user="$1" user_id="$2"
    local -n _yd_user="$3" _yd_target="$4"
    local sock
    for sock in "$DBUS_BUS_ROOT/$user_id/.ydotool_socket" \
        /run/ydotoold/socket; do
        [ -S "$sock" ] || continue
        _yd_user="$sock_user"
        _yd_target="$sock"
        return 0
    done
    return 1
}

_wait_ydotool_socket() {
    # After starting ydotoold, the socket can lag ~100-300ms; one immediate probe
    # made the first Display Toggle fall through without a sticky OSD.
    local sock_user="$1" user_id="$2"
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if _find_ydotool_socket "$sock_user" "$user_id" "$3" "$4"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

_resolve_ydotool_target() {
    local -n _yd_user="$1" _yd_target="$2"
    local sock_user user_id
    if ! command -v ydotool >/dev/null 2>&1; then
        return 1
    fi
    if [ "${ASUS_DISPLAY_MODE_FORCE_LOCAL:-0}" = "1" ]; then
        _yd_user=""
        _yd_target=""
        return 0
    fi
    sock_user=$(_resolve_cycle_user)
    user_id=$(_resolve_user_id "$sock_user")
    # Prefer an already-running socket; starting the user unit on every press
    # added ~0.5s and let rapid hotkeys overlap into racing Super holds.
    if _find_ydotool_socket "$sock_user" "$user_id" "$1" "$2"; then
        return 0
    fi
    _start_ydotool_user_unit "$sock_user" "$user_id"
    # Fail closed without a socket so we do not "succeed" with an empty TARGET
    # (first press looked like a no-op; second press found the socket).
    _wait_ydotool_socket "$sock_user" "$user_id" "$1" "$2"
}

_resolve_x11_display() {
    local user="$1" display_val
    display_val=$(asus_session_env_value "DISPLAY" "$user")
    [ -n "$display_val" ] || display_val="${DISPLAY:-:0}"
    echo "$display_val"
}

_clear_osd_session_marker() {
    local prefix="$1"
    rm -f "${prefix}.session" "${prefix}.ctx"
}

_finalize_osd_open_with_watchdog() {
    local prefix="$1"
    if _ensure_watchdog "$prefix"; then
        return 0
    fi
    _log_display_mode "Watchdog failed to start; releasing sticky OSD"
    _dismiss_osd_modifiers "$prefix"
    return 1
}

_open_osd_session_ydotool() {
    local prefix="$1" active_user="$2" sock="$3"
    # Mark sticky OSD before Super-down so Esc --cancel-osd works immediately
    # (daemon only cancels when .session/.ctx exists).
    _write_ctx "$prefix" "$active_user" "$sock" "ydotool"
    _bump_session_expiry "$prefix"
    # Single injection: clear stuck Shift/Ctrl/Alt, then Super-down + P tap.
    # Separate runuser round-trips raced with the next hotkey press.
    if ! _ydotool_key "$active_user" "$sock" \
        42:0 54:0 29:0 97:0 56:0 100:0 125:1 25:1 25:0; then
        _clear_osd_session_marker "$prefix"
        return 1
    fi
    _finalize_osd_open_with_watchdog "$prefix"
}

_open_osd_session_xdotool() {
    local prefix="$1" active_user="$2" display_val="$3"
    _clear_stuck_non_super_modifiers "$active_user" "$display_val" "xdotool"
    _write_ctx "$prefix" "$active_user" "$display_val" "xdotool"
    _bump_session_expiry "$prefix"
    if ! _xdotool_cmd "$active_user" "$display_val" keydown Super_L; then
        _clear_osd_session_marker "$prefix"
        return 1
    fi
    if ! _xdotool_cmd "$active_user" "$display_val" key p; then
        _xdotool_cmd "$active_user" "$display_val" keyup Super_L || true
        _clear_osd_session_marker "$prefix"
        return 1
    fi
    _finalize_osd_open_with_watchdog "$prefix"
}

_cycle_osd_backend() {
    local active_user="$1" target="$2" backend="$3"
    if [ "$backend" = "xdotool" ]; then
        _xdotool_cmd "$active_user" "${target:-:0}" key p
        return $?
    fi
    _ydotool_key "$active_user" "$target" 25:1 25:0
}

_cycle_osd_session() {
    local prefix="$1" active_user target backend
    _read_ctx "$prefix" active_user target backend || return 1
    _cycle_osd_backend "$active_user" "$target" "$backend" || return 1
    _bump_session_expiry "$prefix"
    if _ensure_watchdog "$prefix"; then
        return 0
    fi
    _log_display_mode "Watchdog failed to start during OSD cycle; releasing sticky OSD"
    _dismiss_osd_modifiers "$prefix"
    return 1
}

_trigger_ydotool_display_switch() {
    if [ "${ASUS_DISPLAY_MODE_DISABLE_YDOTOOL:-0}" = "1" ]; then
        return 1
    fi
    local prefix active_user target
    prefix="$(_display_state_prefix)"
    _resolve_ydotool_target active_user target || return 1
    _open_osd_session_ydotool "$prefix" "$active_user" "$target"
}

_xdotool_ready() {
    [ "${ASUS_DISPLAY_MODE_DISABLE_XDOTOOL:-0}" != "1" ] || return 1
    command -v xdotool >/dev/null 2>&1
}

_xdotool_allowed_for_session() {
    local stype="$1"
    [ "$stype" != "wayland" ] && return 0
    [ "${ASUS_DISPLAY_MODE_FORCE_XDOTOOL:-0}" = "1" ]
}

_trigger_xdotool_display_switch() {
    local prefix user stype display_val
    _xdotool_ready || return 1
    prefix="$(_display_state_prefix)"
    if [ "${ASUS_DISPLAY_MODE_FORCE_LOCAL:-0}" = "1" ]; then
        _open_osd_session_xdotool "$prefix" "" "${DISPLAY:-:0}"
        return $?
    fi
    user=$(_resolve_cycle_user)
    [ -n "$user" ] || return 1
    stype=$(asus_session_type "$user")
    _xdotool_allowed_for_session "$stype" || return 1
    display_val=$(_resolve_x11_display "$user")
    _open_osd_session_xdotool "$prefix" "$user" "$display_val"
}


_run_settings_cmd() {
    local user="$1" bus_addr="$2"
    shift 2
    _run_as_user "$user" env DBUS_SESSION_BUS_ADDRESS="$bus_addr" "$@" >/dev/null 2>&1
}

_open_gnome_display_settings() {
    _run_settings_cmd "$1" "$2" gnome-control-center display
}

_open_kde_display_settings() {
    _run_settings_cmd "$1" "$2" systemsettings kcm_kscreen \
        || _run_settings_cmd "$1" "$2" systemsettings5 kcm_kscreen
}

_open_xfce_display_settings() {
    _run_settings_cmd "$1" "$2" xfce4-display-settings
}

_open_lxqt_display_settings() {
    _run_settings_cmd "$1" "$2" lxqt-config-monitor
}

_open_cinnamon_display_settings() {
    _run_settings_cmd "$1" "$2" cinnamon-settings display
}

_open_mate_display_settings() {
    _run_settings_cmd "$1" "$2" mate-display-properties
}

_settings_fn_gnome_kde_xfce() {
    case "$1" in
        gnome) printf '%s\n' _open_gnome_display_settings ;;
        kde) printf '%s\n' _open_kde_display_settings ;;
        xfce) printf '%s\n' _open_xfce_display_settings ;;
        *) return 1 ;;
    esac
}

_settings_fn_lxqt_cinnamon_mate() {
    case "$1" in
        lxqt) printf '%s\n' _open_lxqt_display_settings ;;
        cinnamon) printf '%s\n' _open_cinnamon_display_settings ;;
        mate) printf '%s\n' _open_mate_display_settings ;;
        *) return 1 ;;
    esac
}

_settings_fn_for_family() {
    case "$1" in
        gnome|kde|xfce) _settings_fn_gnome_kde_xfce "$1" ;;
        lxqt|cinnamon|mate) _settings_fn_lxqt_cinnamon_mate "$1" ;;
        *) return 1 ;;
    esac
}

_open_family_display_settings() {
    local user="$1" bus_addr="$2" family="$3" settings_fn
    settings_fn=$(_settings_fn_for_family "$family") || return 1
    "$settings_fn" "$user" "$bus_addr"
}

_open_any_display_settings() {
    local user="$1" bus_addr="$2" settings_fn
    for settings_fn in _open_gnome_display_settings _open_kde_display_settings \
        _open_xfce_display_settings _open_lxqt_display_settings \
        _open_cinnamon_display_settings _open_mate_display_settings; do
        if "$settings_fn" "$user" "$bus_addr"; then
            return 0
        fi
    done
    return 1
}

_open_display_settings() {
    if [ "${ASUS_DISPLAY_MODE_DISABLE_SETTINGS:-0}" = "1" ]; then
        return 1
    fi
    local user user_id bus_addr family
    user=$(_resolve_cycle_user)
    [ -n "$user" ] || return 1
    user_id=$(_resolve_user_id "$user")
    bus_addr="unix:path=$DBUS_BUS_ROOT/$user_id/bus"
    family=$(asus_desktop_family "$user")
    _open_family_display_settings "$user" "$bus_addr" "$family" \
        || _open_any_display_settings "$user" "$bus_addr"
}

_try_osd_backends() {
    _trigger_ydotool_display_switch || _trigger_xdotool_display_switch
}

_try_fallback_backends() {
    # Locked KDE/XFCE/LXQt/Cinnamon/MATE: sticky Super+P OSD first (above), then
    # DE settings — never Mutter ApplyMonitorsConfig on those families.
    local user family=""
    user=$(_resolve_cycle_user || true)
    if [ -n "$user" ]; then
        family=$(asus_desktop_family "$user" 2>/dev/null || true)
    fi
    case "$family" in
        kde|xfce|lxqt|cinnamon|mate)
            _open_display_settings
            return $?
            ;;
    esac
    _cycle_mutter_display_mode || _open_display_settings
}

_trigger_display_mode() {
    local prefix
    prefix="$(_display_state_prefix)"
    if _session_is_active "$prefix"; then
        # Orphan markers (session file without a live Super hold/watchdog): cycling
        # P alone does nothing. Clear and reopen sticky OSD instead.
        if ! _watchdog_pid_alive "${prefix}.wd.pid"; then
            _log_display_mode "Orphan OSD session (no watchdog); reopening"
            _clear_osd_session_marker "$prefix"
        else
            _cycle_osd_session "$prefix"
            return $?
        fi
    fi
    _try_osd_backends || _try_fallback_backends
}

_cancel_osd_session() {
    # Esc path must drop ydotool Super immediately. Never wait on the flock —
    # a multi-second wait left Super latched so Mutter re-opened the OSD.
    local prefix="$1"
    _ensure_display_state_dir "$(dirname "$prefix")"
    if ! _open_display_mode_flock_fd "$prefix"; then
        _log_display_mode "cancel-osd lock open failed; dismissing OSD without lock"
        _dismiss_osd_modifiers "$prefix"
        return 1
    fi
    if flock -n 9 2>/dev/null; then
        _dismiss_osd_modifiers "$prefix"
        _release_display_mode_lock
        return 0
    fi
    _log_display_mode "cancel-osd lock busy; dismissing OSD without lock"
    _dismiss_osd_modifiers "$prefix"
    exec 9>&- || true
    return 0
}

