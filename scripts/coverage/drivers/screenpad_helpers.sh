#!/usr/bin/env bash
# kcov driver: exercise ScreenPad shared + brightness helper branches.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_setup_screenpad_kcov_tree() {
    local tmp="$1"
    mkdir -p "$tmp/sys/backlight/asus_screenpad" "$tmp/state/$(id -u)" "$tmp/notif/$(id -u)" \
        "$tmp/bus/$(id -u)" "$tmp/icons" "$tmp/prefix/usr/local/share/icons/hicolor/scalable/apps"
    printf '128\n' > "$tmp/sys/backlight/asus_screenpad/brightness"
    printf '255\n' > "$tmp/sys/backlight/asus_screenpad/max_brightness"
    chmod 666 "$tmp/sys/backlight/asus_screenpad/brightness"
    printf '<svg><path stroke="#000"/></svg>\n' > "$tmp/icons/asus-screenpad-on-symbolic.svg"
    printf '<svg><path stroke="#000"/></svg>\n' > "$tmp/icons/asus-screenpad-off-symbolic.svg"
}

_export_screenpad_kcov_env() {
    local tmp="$1"
    export SYS_CLASS_ROOT="$tmp/sys"
    export ASUS_SCREENPAD_NODE="$tmp/sys/backlight/asus_screenpad/brightness"
    export STATE_DIR="$tmp/state"
    export NOTIF_ID_ROOT="$tmp/notif"
    export ASUS_SCREENPAD_ICON_DIR="$tmp/icons"
    export PREFIX="$tmp/prefix"
    export RUN_USER_ROOT="$tmp/bus"
    # Skip host gnome-shell.css scans (huge; hangs under kcov).
    export ASUS_NOTIF_APP_NAME_COLOR='#abc'
    export ASUS_SCREENPAD_APP_NAME_COLOR='#abc'
}

_install_screenpad_kcov_stubs() {
    local tmp="$1"
    _make_fake_loginctl_current_user "$tmp"
    _make_fake_sudo_script "$tmp"
    _driver_bind_required "$tmp/bus/$(id -u)/bus" screenpad_helpers
    PATH="$tmp:$PATH"
    export PATH
    # Fail-fast stubs before any OSD/notify: real gdbus+timeout against a bound but
    # non-D-Bus AF_UNIX socket hangs for ASUS_SCREENPAD_OSD_TIMEOUT_SECS each call.
    _kcov_make_stub "$tmp/gdbus" 'echo "(uint32 7,)"; exit 0'
    _kcov_make_stub "$tmp/timeout" 'shift; exec "$@"'
    _kcov_make_stub "$tmp/gsettings" 'exit 0'
    _kcov_make_stub "$tmp/gnome-extensions" 'exit 0'
    export ASUS_SCREENPAD_OSD_TIMEOUT_SECS=1
}

_run_screenpad_read_clamp_paths() {
    local tmp="$1"
    _soft_expect 0 find_screenpad_node >/dev/null
    # max_brightness non-numeric → default 255 (same-shell for kcov).
    printf 'abc\n' > "$tmp/sys/backlight/asus_screenpad/max_brightness"
    _soft _read_screenpad_max_value "$ASUS_SCREENPAD_NODE" >/dev/null
    printf '255\n' > "$tmp/sys/backlight/asus_screenpad/max_brightness"
    _soft_expect 0 _read_screenpad_value "$ASUS_SCREENPAD_NODE" >/dev/null
    _soft_expect 0 _read_screenpad_max_value "$ASUS_SCREENPAD_NODE" >/dev/null
    _soft_expect 0 _clamp_screenpad_brightness 50 255 >/dev/null
    _soft_expect 0 _clamp_screenpad_brightness abc 255 >/dev/null
    _soft_expect 0 _clamp_screenpad_brightness 50 abc >/dev/null
    _soft_expect 0 _clamp_screenpad_brightness 999 10 >/dev/null
}

_run_screenpad_write_notify_paths() {
    _soft_expect 0 _save_screenpad_brightness 100
    _soft_expect 0 _load_screenpad_brightness >/dev/null
    _soft_expect 0 _screenpad_write_verified "$ASUS_SCREENPAD_NODE" 64
    _soft_expect 0 _write_screenpad_brightness "$ASUS_SCREENPAD_NODE" 80
    _soft_expect 0 _screenpad_level_fraction 0 0 >/dev/null
    _soft_expect 0 _screenpad_level_fraction 80 255 >/dev/null
    _soft_expect 0 _screenpad_percent 80 0 >/dev/null
    _soft_expect 0 _resolve_screenpad_notification_icon on >/dev/null
    _soft_expect 0 _resolve_screenpad_notification_icon off >/dev/null
}

_run_screenpad_icon_miss_paths() {
    local tmp="$1" _icon_name
    # Theme glyph path (same-shell) before icon-dir miss exercises.
    mkdir -p "$tmp/theme/Adwaita/symbolic/status"
    _icon_name=$(_screenpad_symbolic_icon_name on)
    printf '<svg/>\n' > "$tmp/theme/Adwaita/symbolic/status/${_icon_name}.svg"
    # Force tint fallback to theme name: color ok but dest parent not creatable.
    : > "$tmp/blocked-notif-root"
    ASUS_ICON_THEME_ROOT="$tmp/theme" ASUS_NOTIF_APP_NAME_COLOR='#abc' \
        NOTIF_ID_ROOT="$tmp/blocked-notif-root" \
        _soft _resolve_screenpad_notification_icon on >/dev/null
    # No template → video-joined-displays.
    ASUS_SCREENPAD_ICON_DIR="$tmp/empty-icons" ASUS_ICON_THEME_ROOT="$tmp/empty-theme" \
        _soft _resolve_screenpad_notification_icon on >/dev/null
    ASUS_SCREENPAD_ICON_DIR=/missing _soft _resolve_screenpad_notification_icon on >/dev/null
}

_run_screenpad_write_timeout_paths() {
    local tmp="$1"
    mkdir -p "$tmp/sys/backlight/dirnode"
    _soft_expect 1 _screenpad_write_verified "$tmp/sys/backlight/dirnode" 1
    ASUS_SCREENPAD_OSD_TIMEOUT_SECS=bad _soft _screenpad_osd_timeout_secs >/dev/null
    ASUS_SCREENPAD_OSD_TIMEOUT_SECS=0 _soft _screenpad_osd_timeout_secs >/dev/null
    _soft_expect 0 _parse_screenpad_set_value 40 255 >/dev/null
    _soft_expect 0 _parse_screenpad_set_value 40% 255 >/dev/null
    _soft_expect 1 _parse_screenpad_set_value bogus 255 >/dev/null
    _soft_expect 0 _require_writable_screenpad_node >/dev/null
    _soft_expect 0 _brightness_after_delta "$ASUS_SCREENPAD_NODE" 10 255 >/dev/null
    _soft_expect 0 _brightness_after_delta "$ASUS_SCREENPAD_NODE" -200 255 >/dev/null
    chmod a-w "$ASUS_SCREENPAD_NODE"
    _soft_expect 1 _require_writable_screenpad_node >/dev/null
    chmod u+w "$ASUS_SCREENPAD_NODE"
}

_run_screenpad_template_miss_paths() {
    local tmp="$1"
    # Icon/template miss → video-joined-displays fallback.
    ASUS_SCREENPAD_ICON_DIR=/missing PREFIX=/missing-prefix \
        _soft _resolve_screenpad_notification_icon on >/dev/null
    rm -f "$tmp/icons"/*
    ASUS_SCREENPAD_ICON_DIR="$tmp/icons" \
        _soft _resolve_screenpad_notification_icon on >/dev/null
    ASUS_SCREENPAD_ICON_DIR="/missing-icons-$$" \
        _soft _resolve_screenpad_notification_icon off >/dev/null
    # Max-brightness default when node lacks max file.
    rm -f "$tmp/sys/backlight/asus_screenpad/max_brightness"
    _soft_expect 0 _read_screenpad_max_value "$ASUS_SCREENPAD_NODE" >/dev/null
    printf '255\n' > "$tmp/sys/backlight/asus_screenpad/max_brightness"
}

_run_screenpad_bus_osd_paths() {
    local tmp="$1"
    # Bus address validation + OSD notify paths.
    _soft_expect 1 _screenpad_bus_addr_is_unix_path "unix:abstract=/tmp/x"
    _soft_expect 1 _screenpad_bus_addr_is_unix_path "unix:path=/tmp/x,guid=abc"
    _soft_expect 0 _screenpad_bus_addr_is_unix_path "unix:path=$tmp/bus/$(id -u)/bus"
    _soft _notify_screenpad_brightness 80 255 >/dev/null
    ASUS_DESKTOP_FAMILY=kde _soft _try_show_screenpad_plasma_osd 40 >/dev/null
    ASUS_DESKTOP_FAMILY=lxqt _soft _try_show_screenpad_lxqt_osd 40 >/dev/null
    ASUS_DESKTOP_FAMILY=mate _soft _try_show_screenpad_mate_osd 40 >/dev/null
    ASUS_DESKTOP_FAMILY=cinnamon _soft _try_show_screenpad_cinnamon_osd 40 >/dev/null
}

_run_screenpad_verify_context_paths() {
    # Read-back verify failure after making node unreadable.
    chmod a-r "$ASUS_SCREENPAD_NODE" 2>/dev/null
    _soft_expect 1 _screenpad_write_verified "$ASUS_SCREENPAD_NODE" 11
    chmod 666 "$ASUS_SCREENPAD_NODE"
    _soft_expect 0 _screenpad_read_notif_context >/dev/null
    _soft_expect 0 _screenpad_load_notif_fields >/dev/null
    _soft_expect 0 _screenpad_step_size 255 >/dev/null
    _soft_expect 0 _screenpad_symbolic_icon_name on >/dev/null
    _soft_expect 0 _screenpad_symbolic_svg_candidates on >/dev/null
    _soft_expect 0 _find_screenpad_template_svg on >/dev/null
    _soft_expect 0 _screenpad_brightness_state_file >/dev/null
}

_run_screenpad_osd_fallback_paths() {
    local tmp="$1"
    # Shell ShowOsd miss → prime → retry → percent OSD / notify fallback.
    _kcov_make_stub "$tmp/gdbus" 'exit 1'
    ASUS_DESKTOP_FAMILY=gnome _soft _try_show_screenpad_shell_osd 0.5 >/dev/null
    ASUS_DESKTOP_FAMILY=gnome _soft _notify_screenpad_brightness 80 255 >/dev/null
    ASUS_DESKTOP_FAMILY=kde _soft _try_show_screenpad_percent_osds 40 >/dev/null
    ASUS_DESKTOP_FAMILY=lxqt _soft _try_show_screenpad_percent_osds 40 >/dev/null
    ASUS_DESKTOP_FAMILY=mate _soft _try_show_screenpad_percent_osds 40 >/dev/null
    # Successful value-hint notify (LXQt/MATE path).
    _kcov_make_stub "$tmp/gdbus" 'echo "(uint32 9,)"; exit 0'
    ASUS_DESKTOP_FAMILY=lxqt _soft _try_show_screenpad_lxqt_osd 55 >/dev/null
    ASUS_DESKTOP_FAMILY=mate _soft _try_show_screenpad_mate_osd 55 >/dev/null
    # Family resolve without override uses session helper.
    unset ASUS_DESKTOP_FAMILY
    _soft_expect 0 _screenpad_resolve_family "$(id -un)" >/dev/null
    _soft_expect 1 _screenpad_resolve_family "" >/dev/null
}

_run_screenpad_kcov_main() {
    local tmp
    tmp=$(mktemp -d)
    # Expand path now: local tmp is gone when EXIT runs after this function returns.
    trap 'rm -rf "'"$tmp"'"' EXIT
    _setup_screenpad_kcov_tree "$tmp"
    _export_screenpad_kcov_env "$tmp"
    _install_screenpad_kcov_stubs "$tmp"

    # shellcheck source=bin/asus-screenpad-brightness.sh
    _driver_source_required "$REPO_ROOT/bin/asus-screenpad-brightness.sh" screenpad_helpers quiet

    _run_screenpad_read_clamp_paths "$tmp"
    _run_screenpad_write_notify_paths
    _run_screenpad_icon_miss_paths "$tmp"
    _run_screenpad_write_timeout_paths "$tmp"
    _run_screenpad_template_miss_paths "$tmp"
    _run_screenpad_bus_osd_paths "$tmp"
    _run_screenpad_verify_context_paths
    _run_screenpad_osd_fallback_paths "$tmp"
}

_run_screenpad_kcov_main
