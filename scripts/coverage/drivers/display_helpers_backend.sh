#!/usr/bin/env bash
# Display kcov backend helpers (sourced by display_helpers.sh).

_setup_display_backend_tree() {
    local tmp="$1" mock="$2" sock="$3"
    mkdir -p "$mock" "$tmp/sys/backlight/asus_screenpad" "$tmp/notif/$(id -u)" \
        "$tmp/bus/$(id -u)" "$tmp/run/user/$(id -u)"
    _driver_bind_required "$tmp/bus/$(id -u)/bus" display_helpers
    printf '#!/bin/sh\nexit 0\n' > "$mock/ydotool"
    printf '#!/bin/sh\nexit 0\n' > "$mock/xdotool"
    printf '#!/bin/sh\nexit 0\n' > "$mock/gnome-control-center"
    printf '#!/bin/sh\nexit 0\n' > "$mock/systemsettings"
    printf '#!/bin/sh\nexit 0\n' > "$mock/systemsettings5"
    printf '#!/bin/sh\nexit 0\n' > "$mock/xfce4-display-settings"
    printf '#!/bin/sh\nexit 0\n' > "$mock/lxqt-config-monitor"
    printf '#!/bin/sh\nexit 0\n' > "$mock/systemctl"
    # Fail-fast D-Bus stub: a listening-but-dead AF_UNIX bus hangs real gdbus/Mutter.
    printf '#!/bin/sh\necho "gdbus: stub fail" >&2\nexit 1\n' > "$mock/gdbus"
    # Mutter helpers require timeout on PATH (fail closed when absent).
    printf '#!/bin/sh\nshift; exec "$@"\n' > "$mock/timeout"
    chmod +x "$mock"/*
    _driver_bind_required "$sock" display_helpers
}

_export_display_backend_env() {
    local tmp="$1" mock="$2" sock="$3" saved_path="$4"
    export ASUS_DISPLAY_MODE_PYTHON_TIMEOUT_SECS=1
    export ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/state"
    export ASUS_DISPLAY_MODE_IDLE_SECS=1
    export SYS_CLASS_ROOT="$tmp/sys"
    export BIN_ROOT="$REPO_ROOT/bin"
    export NOTIF_ID_ROOT="$tmp/notif"
    export DBUS_BUS_ROOT="$tmp/bus"
    export RUN_USER_ROOT="$tmp/run/user"
    export PATH="$mock:$saved_path"
    # Prefer per-user socket under RUN_USER_ROOT / DBUS_BUS_ROOT.
    if [ -S "$sock" ]; then
        ln -sf "$sock" "$RUN_USER_ROOT/$(id -u)/.ydotool_socket"
    fi
    printf '255\n' > "$tmp/sys/backlight/asus_screenpad/brightness"
    # Driver runs as file owner; 644 is sufficient (no privilege drop).
    chmod 644 "$tmp/sys/backlight/asus_screenpad/brightness"
}

_run_display_backend_ydotool_paths() {
    local sock="$1" _yd_u _yd_t
    _soft _ydotool_key "" "$sock" 125:1
    _soft _ydotool_key "$(id -un)" "" 125:1
    _soft _ydotool_key "" "" 125:1
    _soft _xdotool_cmd "$(id -un)" ":0" key p
    _soft asus_session_type "$(id -un)" >/dev/null
    _soft _resolve_x11_display "$(id -un)" >/dev/null
    _yd_u=""; _yd_t=""
    ASUS_DISPLAY_MODE_FORCE_LOCAL=0 _soft _resolve_ydotool_target _yd_u _yd_t
    _soft _start_ydotool_user_unit "$(id -un)" "$(id -u)"
    _soft _find_ydotool_socket "$(id -un)" "$(id -u)" _yd_u _yd_t
    ASUS_DISPLAY_MODE_FORCE_LOCAL=1 _soft _resolve_ydotool_target _yd_u _yd_t
    _soft _trigger_ydotool_display_switch
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        DISPLAY=:0 _soft _trigger_xdotool_display_switch
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_FORCE_LOCAL=0 \
        ASUS_DISPLAY_MODE_FORCE_XDOTOOL=1 DISPLAY=:0 XDG_SESSION_TYPE=x11 \
        _soft _trigger_xdotool_display_switch
}

_run_display_backend_settings_paths() {
    ASUS_DISPLAY_MODE_DISABLE_SETTINGS=0 ASUS_DESKTOP_FAMILY=gnome \
        _soft _open_display_settings
    ASUS_DESKTOP_FAMILY=kde _soft _open_display_settings
    ASUS_DESKTOP_FAMILY=xfce _soft _open_display_settings
    ASUS_DESKTOP_FAMILY=lxqt _soft _open_display_settings
    ASUS_DESKTOP_FAMILY=cinnamon _soft _open_display_settings
    ASUS_DESKTOP_FAMILY=mate _soft _open_display_settings
    ASUS_DESKTOP_FAMILY=other _soft _open_display_settings
}

_run_display_backend_screenpad_paths() {
    local tmp="$1"
    _soft _set_screenpad_backlight 255
    _soft _set_screenpad_backlight 0
    # Mutter clamp / missing-timeout / on-level helpers.
    printf '10\n' > "$tmp/sys/backlight/asus_screenpad/max_brightness"
    _soft _clamp_mutter_screenpad_value 99 \
        "$tmp/sys/backlight/asus_screenpad/max_brightness" >/dev/null
    _soft _clamp_mutter_screenpad_value 5 \
        "$tmp/sys/backlight/asus_screenpad/max_brightness" >/dev/null
    _soft _clamp_mutter_screenpad_value 999 \
        "$tmp/sys/backlight/asus_screenpad/max_brightness" >/dev/null
    _soft _mutter_screenpad_on_level >/dev/null
    mkdir -p "$tmp/state/$(id -u)"
    echo 77 > "$tmp/state/$(id -u)/screenpad_brightness"
    STATE_DIR="$tmp/state" _soft _mutter_screenpad_on_level >/dev/null
}

_run_display_backend_mutter_paths() {
    local tmp="$1"
    ASUS_DISPLAY_MODE_PYTHON_TIMEOUT_SECS=bad \
        _soft _run_display_mode_python "$(id -un)" \
        "unix:path=$tmp/bus/$(id -u)/bus" --help >/dev/null
    PATH="/nonexistent" _soft _run_display_mode_python "$(id -un)" \
        "unix:path=$tmp/bus/$(id -u)/bus" --help >/dev/null
    _soft _set_screenpad_backlight 999
    _soft _send_user_notification "t" "m" "video-display" "display" "display" "video-display"
    _soft _apply_mutter_layout "$(id -un)" "$tmp/bus/$(id -u)/bus" all
    _soft _apply_mutter_layout "$(id -un)" "$tmp/bus/$(id -u)/bus" main_only
    _soft _detect_current_mutter_state "$(id -un)" "$tmp/bus/$(id -u)/bus" >/dev/null
    _soft _get_next_profile_info "$(id -un)" "$tmp/bus/$(id -u)/bus" all >/dev/null
}

_run_display_backend_fallback_paths() {
    ASUS_DISPLAY_MODE_FORCE_LOCAL=1 _soft _try_osd_backends
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        _soft _try_fallback_backends
    # Locked: LXQt/KDE/XFCE skip Mutter ApplyMonitorsConfig (settings only).
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DESKTOP_FAMILY=lxqt _soft _try_fallback_backends
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DESKTOP_FAMILY=cinnamon _soft _try_fallback_backends
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DESKTOP_FAMILY=mate _soft _try_fallback_backends
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DESKTOP_FAMILY=kde _soft _try_fallback_backends
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DESKTOP_FAMILY=xfce _soft _try_fallback_backends
    _soft _is_duplicate_invoke
    _soft _is_duplicate_invoke
}

_run_display_backend_open_fail_paths() {
    local mock="$1" tmp="$2"
    # Force open-osd failure branches.
    printf '#!/bin/sh\nexit 1\n' > "$mock/ydotool"
    ASUS_DISPLAY_MODE_FORCE_LOCAL=1 _soft _open_osd_session_ydotool "$tmp/state-fail" "" ""
    printf '#!/bin/sh\nexit 1\n' > "$mock/xdotool"
    ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        _soft _open_osd_session_xdotool "$tmp/state-fail2" "" ":0"
}

_run_display_backend_helpers() {
    local tmp mock sock saved_path
    saved_path="$PATH"
    tmp=$(mktemp -d)
    trap 'PATH="'"$saved_path"'"; rm -rf "'"$tmp"'"; unset ASUS_DISPLAY_MODE_STATE_PREFIX SYS_CLASS_ROOT BIN_ROOT NOTIF_ID_ROOT DBUS_BUS_ROOT RUN_USER_ROOT' RETURN
    mock="$tmp/bin"
    sock="$tmp/ydotool.sock"
    _setup_display_backend_tree "$tmp" "$mock" "$sock"
    _export_display_backend_env "$tmp" "$mock" "$sock" "$saved_path"
    _run_display_backend_ydotool_paths "$sock"
    _run_display_backend_settings_paths
    _run_display_backend_screenpad_paths "$tmp"
    _run_display_backend_mutter_paths "$tmp"
    _run_display_backend_fallback_paths
    _run_display_backend_open_fail_paths "$mock" "$tmp"
    _run_display_backend_cancel_exercises "$ASUS_DISPLAY_MODE_STATE_PREFIX" "$sock" "$tmp"
}

_run_display_backend_cancel_mark_paths() {
    local prefix="$1"
    _soft _mark_osd_cancel_in_progress "$prefix"
    _soft _clear_osd_cancel_flag "$prefix"
    _soft _cancel_osd_session "$prefix"
}

_run_display_backend_cancel_open_paths() {
    local prefix="$1" sock="$2" tmp="$3" mock="$3/bin"
    # Working ydotool + missing watchdog entry → finalize dismiss path.
    printf '#!/bin/sh\nexit 0\n' > "$mock/ydotool"
    chmod +x "$mock/ydotool"
    _soft rm -f "${prefix}.session" "${prefix}.ctx" "${prefix}.cancel"
    _ASUS_DISPLAY_MODE_ENTRY="" BIN_ROOT="$tmp/missing-bin" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        _soft _open_osd_session_ydotool "$prefix" "$(id -un)" "$sock"
    # Cycle path with ensure_watchdog failure.
    _soft _write_ctx "$prefix" "$(id -un)" "$sock" "ydotool"
    _soft _bump_session_expiry "$prefix"
    _ASUS_DISPLAY_MODE_ENTRY="" BIN_ROOT="$tmp/missing-bin" \
        _soft _cycle_osd_session "$prefix"
    # xdotool: keydown ok, key p fails → Super-up cleanup branch.
    printf '#!/bin/sh\ncase " $* " in *" key p "*) exit 1 ;; *) exit 0 ;; esac\n' \
        > "$mock/xdotool"
    chmod +x "$mock/xdotool"
    ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        _soft _open_osd_session_xdotool "$prefix" "$(id -un)" ":0"
}

_run_display_backend_cancel_busy_paths() {
    local prefix="$1" sock="$2" tmp="$3" biglog
    # Cancel while flock is held → busy path.
    _hold_display_mode_flock_briefly "$prefix" 0.25
    sleep 0.05
    _soft_expect 0 _cancel_osd_session "$prefix"
    _soft wait
    biglog="$tmp/display-mode-big.log"
    printf '%4096s\n' "kcov-display-mode-log-padding" | tr ' ' 'x' >"$biglog"
    _soft _append_bounded_display_mode_log "$biglog" "overflow-line" 1024
    _soft _rewrite_display_mode_log_tail "$biglog" 512
    _soft_expect 0 _rewrite_display_mode_log_tail "$tmp" 512
    _soft _write_ctx "$prefix" "$(id -un)" "$sock" "ydotool"
    _soft _mark_osd_cancel_in_progress "$prefix"
    _soft _release_osd_modifiers "$prefix"
}

_run_display_backend_cancel_exercises() {
    local prefix="$1" sock="$2" tmp="$3"
    _run_display_backend_cancel_mark_paths "$prefix"
    _run_display_backend_cancel_open_paths "$prefix" "$sock" "$tmp"
    _run_display_backend_cancel_busy_paths "$prefix" "$sock" "$tmp"
}
