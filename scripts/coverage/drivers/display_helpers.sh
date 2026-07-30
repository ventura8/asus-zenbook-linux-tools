#!/usr/bin/env bash
# kcov driver: exercise sourced helpers from bin/asus-display-mode.sh.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

export ASUS_DISPLAY_MODE_IDLE_SECS="${ASUS_DISPLAY_MODE_IDLE_SECS:-1}"

# shellcheck source=bin/asus-display-mode.sh
_driver_source_required "$REPO_ROOT/bin/asus-display-mode.sh" display_helpers quiet

# shellcheck source=scripts/coverage/drivers/display_helpers_watchdog.sh
source "$(dirname "${BASH_SOURCE[0]}")/display_helpers_watchdog.sh"
# shellcheck source=scripts/coverage/drivers/display_helpers_backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/display_helpers_backend.sh"

_run_display_session_state_paths() {
    local prefix="$1" fake_sock="$2" _ctx_u _ctx_t _ctx_b
    _soft _display_state_prefix >/dev/null
    _soft _log_display_mode "kcov"
    _soft _resolve_user_id "$(id -un)" >/dev/null
    _soft _resolve_user_id "$(id -u)" >/dev/null
    _soft _resolve_cycle_user >/dev/null
    _soft _write_ctx "$prefix" "user" "$fake_sock" "ydotool"
    _soft _read_ctx "$prefix" _ctx_u _ctx_t _ctx_b
    _soft _bump_session_expiry "$prefix"
    _soft _session_is_active "$prefix"
    _soft _release_osd_modifiers "$prefix"
    _soft _write_ctx "$prefix" "user" ":0" "xdotool"
    _soft _release_osd_modifiers "$prefix"
}

_run_display_session_profile_paths() {
    _soft _get_fallback_next_profile_info all >/dev/null
    _soft _get_fallback_next_profile_info main_only >/dev/null
    _soft _get_fallback_next_profile_info other >/dev/null
    _soft _normalize_detected_profile main_only >/dev/null
    _soft _normalize_detected_profile 1 >/dev/null
    _soft _normalize_detected_profile 2 >/dev/null
    _soft _normalize_detected_profile 3 >/dev/null
    _soft _normalize_detected_profile 9 >/dev/null
    _soft asus_desktop_family "$(id -un)" >/dev/null
    _soft _dup_window_hit "12345678901" "12345678900"
    _soft _dup_window_hit "10" "9"
    _soft _xdotool_allowed_for_session x11
    _soft _xdotool_allowed_for_session wayland
    ASUS_DISPLAY_MODE_FORCE_XDOTOOL=1 _soft _xdotool_allowed_for_session wayland
}

_run_display_session_trigger_paths() {
    local prefix="$1" saved_idle
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE=1 \
        ASUS_DISPLAY_MODE_DISABLE_SETTINGS=1 \
        _soft _trigger_display_mode
    _soft _write_ctx "$prefix" "$(id -un)" "" "ydotool"
    _soft _bump_session_expiry "$prefix"
    saved_idle="$ASUS_DISPLAY_MODE_IDLE_SECS"
    export ASUS_DISPLAY_MODE_IDLE_SECS=1
    PATH="/bin:/usr/bin" _soft _cycle_osd_session "$prefix"
    export ASUS_DISPLAY_MODE_IDLE_SECS="$saved_idle"
    _soft_session_trigger_if_active "$prefix"
}

_soft_session_trigger_if_active() {
    local prefix="$1"
    if _session_is_active "$prefix"; then
        _soft _trigger_display_mode
    fi
}

_run_display_session_helpers() {
    local tmp prefix fake_sock
    tmp=$(mktemp -d)
    trap 'rm -rf "'"$tmp"'"' RETURN
    prefix="$tmp/state"
    fake_sock="$tmp/fake.sock"
    export ASUS_DISPLAY_MODE_STATE_PREFIX="$prefix"
    _driver_bind_required "$fake_sock" display_helpers
    # Watchdog first (same-shell): later heavy work makes kcov drop parent hits.
    _run_display_watchdog_helper_exercises "$tmp" "$prefix" "$fake_sock"
    _run_display_session_state_paths "$prefix" "$fake_sock"
    _run_display_session_profile_paths
    _run_display_session_trigger_paths "$prefix"
}

_run_display_entry_bootstrap_paths() {
    local tmp="$1"
    _OSD_IDLE_SECS=bad
    _DUP_WINDOW_MS=bad
    _FLOCK_WAIT_SECS=bad
    _normalize_display_timing_env
    ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="$tmp/missing-lib" \
        _soft _source_bootstrap_helper >/dev/null 2>&1
    mkdir -p "$tmp/inst-lib"
    cp "$REPO_ROOT/lib/asus-bootstrap.sh" "$tmp/inst-lib/asus-bootstrap.sh"
    ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="$tmp/inst-lib" \
        _soft _source_bootstrap_helper >/dev/null 2>&1
    _ASUS_LIB_DIR="$tmp/missing-lib" _soft _source_display_mutter_helper >/dev/null 2>&1
    _ASUS_LIB_DIR="$tmp/missing-lib" _soft _validate_display_mode_modules >/dev/null 2>&1
}

_run_display_entry_lock_paths() {
    local prefix="$1"
    _soft _handle_internal_mode
    _soft _handle_internal_mode --cancel-osd
    _soft _open_display_mode_flock_fd "$prefix"
    _soft _release_display_mode_lock
    _soft _acquire_display_mode_lock "$prefix"
    _soft _release_display_mode_lock
    _hold_display_mode_flock_briefly "$prefix" 0.35
    sleep 0.05
    _FLOCK_WAIT_SECS=0
    _soft _acquire_display_mode_lock "$prefix"
    _soft wait
    _FLOCK_WAIT_SECS=5
}

_run_display_entry_main_paths() {
    # Failed path before any duplicate-window arming (main() last: later lines drop).
    export ASUS_DISPLAY_MODE_DUP_MS=0
    _DUP_WINDOW_MS=0
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE=1 ASUS_DISPLAY_MODE_DISABLE_SETTINGS=1 \
        _soft main
    # Duplicate-suppress path (attribution after prior main may be incomplete).
    _DUP_WINDOW_MS=50
    export ASUS_DISPLAY_MODE_DUP_MS=50
    _soft _is_duplicate_invoke
    _soft _is_duplicate_invoke
    ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE=1 ASUS_DISPLAY_MODE_DISABLE_SETTINGS=1 \
        _soft main
}

_run_display_entry_helpers() {
    # Thin slice: only asus-display-mode.sh entry/bootstrap/main paths.
    # Call bootstrap/mutter miss paths BEFORE main(): kcov stops attributing
    # later parent-shell lines after main() runs in this process.
    local tmp prefix fake_sock
    tmp=$(mktemp -d)
    trap 'rm -rf "'"$tmp"'"' RETURN
    prefix="$tmp/state"
    fake_sock="$tmp/fake.sock"
    export ASUS_DISPLAY_MODE_STATE_PREFIX="$prefix"
    _driver_bind_required "$fake_sock" display_helpers
    _run_display_entry_bootstrap_paths "$tmp"
    _run_display_entry_lock_paths "$prefix"
    _run_display_entry_main_paths
}

_run_display_kcov_slice() {
    case "${ASUS_KCOV_DISPLAY_SLICE:-all}" in
        session)
            _run_display_session_helpers
            ;;
        entry)
            _run_display_entry_helpers
            ;;
        backend)
            _run_display_backend_helpers
            ;;
        *)
            _run_display_entry_helpers
            _run_display_session_helpers
            _run_display_backend_helpers
            ;;
    esac
}

_run_display_kcov_slice
