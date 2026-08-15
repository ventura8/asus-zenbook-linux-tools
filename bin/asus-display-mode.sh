#!/bin/bash
# Display mode: ydotool/xdotool Super+P OSD, Mutter cycle, then DE settings.

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

_source_display_mutter_helper() {
    if [ ! -f "$_ASUS_LIB_DIR/asus-display-mutter.sh" ]; then
        echo "Error: Missing lib/asus-display-mutter.sh" >&2
        return 1
    fi
    # shellcheck source=lib/asus-display-mutter.sh
    . "$_ASUS_LIB_DIR/asus-display-mutter.sh"
}

_normalize_display_timing_env() {
    [[ "$_OSD_IDLE_SECS" =~ ^[0-9]+$ ]] || _OSD_IDLE_SECS=2
    [[ "$_DUP_WINDOW_MS" =~ ^[0-9]+$ ]] || _DUP_WINDOW_MS=50
    [[ "$_FLOCK_WAIT_SECS" =~ ^[0-9]+$ ]] || _FLOCK_WAIT_SECS=5
}

_source_initial_display_helpers() {
    _source_bootstrap_helper || return 1
    _source_common_helper || return 1
    _source_display_mutter_helper || return 1
}

_validate_display_mode_modules() {
    local display_lib
    for display_lib in asus-display-state.sh asus-display-watchdog.sh asus-display-osd.sh; do
        if [ ! -f "$_ASUS_LIB_DIR/$display_lib" ]; then
            echo "Error: Missing lib/$display_lib" >&2
            return 1
        fi
    done
}

_source_initial_display_helpers || exit 1
# Optional: persisted ScreenPad brightness for Mutter layout restore.
if [ -f "${_ASUS_LIB_DIR}/asus-screenpad.sh" ]; then
    # shellcheck source=lib/asus-screenpad.sh
    . "${_ASUS_LIB_DIR}/asus-screenpad.sh"
fi

DBUS_BUS_ROOT="$(_resolve_session_bus_root)"
export DBUS_BUS_ROOT
SYS_CLASS_ROOT="${SYS_CLASS_ROOT:-/sys/class}"
BIN_ROOT="${BIN_ROOT:-/usr/local/bin}"
_OSD_IDLE_SECS="${ASUS_DISPLAY_MODE_IDLE_SECS:-2}"
# Only suppress true double-dispatch (WMI+firmware); keep cycles near native Super+P.
_DUP_WINDOW_MS="${ASUS_DISPLAY_MODE_DUP_MS:-50}"
_FLOCK_WAIT_SECS="${ASUS_DISPLAY_MODE_FLOCK_WAIT_SECS:-5}"
_normalize_display_timing_env

_ASUS_DISPLAY_MODE_PREFIX_CACHE=""
_ASUS_DISPLAY_MODE_DIR_CACHE=""

_validate_display_mode_modules || exit 1
# shellcheck source=lib/asus-display-state.sh
. "$_ASUS_LIB_DIR/asus-display-state.sh"
# shellcheck source=lib/asus-display-watchdog.sh
. "$_ASUS_LIB_DIR/asus-display-watchdog.sh"
# shellcheck source=lib/asus-display-osd.sh
. "$_ASUS_LIB_DIR/asus-display-osd.sh"

# Watchdog setsid re-exec must target this entry script (not a sourced lib path).
_ASUS_DISPLAY_MODE_ENTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

_handle_internal_mode() {
    case "${1:-}" in
        --internal-watchdog)
            _run_internal_watchdog
            ;;
        --cancel-osd)
            # Esc path: drop synthetic Super (Mutter already saw / will see Esc).
            local cancel_status=0
            _cancel_osd_session "$(_display_state_prefix)" || cancel_status=$?
            return "$cancel_status"
            ;;
        *)
            return 1
            ;;
    esac
}

_open_display_mode_flock_fd() {
    local prefix="$1"
    _ensure_display_state_dir "$(dirname "$prefix")"
    if ! { exec 9>>"${prefix}.flock"; } 2>/dev/null; then
        echo "Error: Failed to open display mode lock file." >&2
        return 1
    fi
    return 0
}

_acquire_display_mode_lock() {
    local prefix="$1" wait_secs="${_FLOCK_WAIT_SECS:-5}"
    _open_display_mode_flock_fd "$prefix" || return 1
    if ! flock -w "$wait_secs" 9; then
        echo "Error: Timed out waiting for display mode lock." >&2
        exec 9>&- || true
        return 1
    fi
}

_release_display_mode_lock() {
    # Close only FD 9. Never attach `2>/dev/null` to this `exec` — that would
    # permanently redirect the shell's stderr and swallow the final Error line.
    flock -u 9 2>/dev/null || true
    exec 9>&- || true
}

main() {
    local prefix status
    case "${1:-}" in
        --internal-watchdog|--cancel-osd)
            _handle_internal_mode "$1"
            status=$?
            return "$status"
            ;;
    esac
    _display_state_prefix >/dev/null
    prefix="$_ASUS_DISPLAY_MODE_PREFIX_CACHE"
    _acquire_display_mode_lock "$prefix" || return 1
    # Sticky OSD cycles must not be delayed by duplicate suppression.
    if ! _session_is_active "$prefix" && _is_duplicate_invoke; then
        _log_display_mode "Duplicate suppress (user=$(whoami))"
        _release_display_mode_lock
        return 0
    fi
    _log_display_mode "Invoked by user=$(whoami) (UID=$UID)"
    if _trigger_display_mode; then
        _log_display_mode "Success"
        _release_display_mode_lock
        return 0
    fi
    _log_display_mode "Failed"
    _release_display_mode_lock
    echo "Error: could not open display OSD/settings (ydotool/xdotool/Mutter/DE)." >&2
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
