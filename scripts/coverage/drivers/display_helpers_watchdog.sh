#!/usr/bin/env bash
# Display kcov watchdog helpers (sourced by display_helpers.sh).

_wait_for_display_watchdog_exit() {
    local wd_pid="$1"
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$wd_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$wd_pid" 2>/dev/null; then
        echo "display_helpers: watchdog PID $wd_pid still alive after fallback wait" \
            "(cmdline unreadable; possible detached leak)" >&2
    fi
}

_stop_display_watchdog_if_owned() {
    local wd_pid="$1"
    if [ -r "/proc/$wd_pid/cmdline" ] && tr '\0' ' ' < "/proc/$wd_pid/cmdline" \
        | grep -q 'asus-display-mode'; then
        _soft kill "$wd_pid" 2>/dev/null
        return 0
    fi
    _wait_for_display_watchdog_exit "$wd_pid"
}

_display_watchdog_pid_is_live() {
    local wd_pid="$1"
    [ -n "$wd_pid" ] && [[ "$wd_pid" =~ ^[0-9]+$ ]] \
        && kill -0 "$wd_pid" 2>/dev/null
}

_display_watchdog_pid_is_missing() {
    local wd_pid="$1" prefix="$2"
    [ -z "$wd_pid" ] && [ ! -f "${prefix}.wd.pid" ]
}

_cleanup_display_watchdog_process() {
    local wd_pid="$1" prefix="$2"
    if _display_watchdog_pid_is_live "$wd_pid"; then
        _stop_display_watchdog_if_owned "$wd_pid"
    elif _display_watchdog_pid_is_missing "$wd_pid" "$prefix"; then
        echo "display_helpers: no watchdog PID returned and ${prefix}.wd.pid absent" \
            "(possible detached watchdog leak)" >&2
    fi
}

_resolve_spawned_display_watchdog_pid() {
    local iso="$1" prefix="$2" wd_pid
    wd_pid=$(PATH="$iso" _spawn_detached_watchdog "$prefix") || wd_pid=""
    if [ -z "$wd_pid" ] && [ -f "${prefix}.wd.pid" ]; then
        wd_pid=$(cat "${prefix}.wd.pid" 2>/dev/null) || wd_pid=""
    fi
    printf '%s\n' "$wd_pid"
}

_hold_display_mode_flock_briefly() {
    local prefix="$1" secs="$2"
    (
        _open_display_mode_flock_fd "$prefix" && flock 9 && sleep "$secs" && exec 9>&-
    ) &
}

_run_display_watchdog_helper_exercises() {
    local tmp="$1" prefix="$2" fake_sock="$3"
    _run_display_watchdog_release_exercises "$tmp" "$fake_sock"
    _run_display_watchdog_spawn_exercises "$tmp" "$prefix" "$fake_sock"
    _run_display_state_cache_exercises "$tmp" "$prefix"
}

_run_display_watchdog_expiry_paths() {
    local prefix_wd="$1"
    # Same-shell only: kcov drops _exercise subshell hits on watchdog bodies.
    _soft _watchdog_expiry_needs_release 0 "$(date +%s)"
    _soft _watchdog_expiry_needs_release 9999999999 "$(date +%s)"
    printf '%s\n' "$(( $(date +%s) + 60 ))" > "${prefix_wd}.session"
    _soft_expect 0 _watchdog_session_still_active "$prefix_wd"
    _soft _watchdog_pid_alive ""
    _soft _watchdog_pid_alive "${prefix_wd}.wd.pid"
    _soft _watchdog_lock_backoff_ms 1 >/dev/null
    _soft _watchdog_lock_backoff_ms 8 >/dev/null
    _soft _watchdog_lock_sleep_attempt 1
    _soft _watchdog_lock_sleep_attempt 5
    _soft _watchdog_force_release "$prefix_wd"
}

_run_display_watchdog_force_release_paths() {
    local prefix_wd="$1" fake_sock="$2"
    # Busy flock → force-release fallback (exec 9>&- path).
    _hold_display_mode_flock_briefly "$prefix_wd" 0.35
    sleep 0.05
    _soft _watchdog_force_release "$prefix_wd"
    _soft wait
    _soft _write_ctx "$prefix_wd" "$(id -un)" "$fake_sock" "ydotool"
    _soft _mark_osd_cancel_in_progress "$prefix_wd"
    _soft _watchdog_release_if_idle "$prefix_wd"
    _soft _release_osd_modifiers "$prefix_wd"
    _soft _write_ctx "$prefix_wd" "$(id -un)" "$fake_sock" "ydotool"
    _soft _dismiss_osd_modifiers "$prefix_wd"
    _soft _write_ctx "$prefix_wd" "$(id -un)" ":0" "xdotool"
    _soft _dismiss_osd_modifiers "$prefix_wd"
    _soft _clear_stuck_non_super_modifiers "$(id -un)" ":0" "xdotool"
    _soft _clear_stuck_non_super_modifiers "$(id -un)" "$fake_sock" "ydotool"
}

_run_display_watchdog_retry_poll_paths() {
    local prefix_wd="$1"
    printf '0\n' > "${prefix_wd}.session"
    ASUS_DISPLAY_MODE_WD_RELEASE_SECS=1 _soft _watchdog_release_with_retries "$prefix_wd"
    # Held flock → release_if_idle fails until deadline → force_release branch.
    printf '0\n' > "${prefix_wd}.session"
    : > "${prefix_wd}.ctx"
    _hold_display_mode_flock_briefly "$prefix_wd" 1.2
    sleep 0.05
    ASUS_DISPLAY_MODE_WD_RELEASE_SECS=1 _soft _watchdog_release_with_retries "$prefix_wd"
    _soft wait
    # Future expiry → poll_tick sleeps and keeps looping.
    printf '%s\n' "$(( $(date +%s) + 60 ))" > "${prefix_wd}.session"
    _soft _watchdog_poll_tick "$prefix_wd"
    printf '0\n' > "${prefix_wd}.session"
    _soft _watchdog_poll_tick "$prefix_wd"
}

_run_display_watchdog_poll_loop_paths() {
    local prefix_wd="$1" fake_sock="$2"
    _soft rm -f "${prefix_wd}.session" "${prefix_wd}.ctx" "${prefix_wd}.cancel"
    _OSD_IDLE_SECS=0
    _soft_expect 0 _watchdog_poll_loop "$prefix_wd"
    # Session present → while-loop + poll_tick exit path.
    printf '0\n' > "${prefix_wd}.session"
    : > "${prefix_wd}.ctx"
    _OSD_IDLE_SECS=0
    _soft _watchdog_poll_loop "$prefix_wd"
    _soft rm -f "${prefix_wd}.session"
    _soft _write_ctx "$prefix_wd" "$(id -un)" "$fake_sock" "ydotool"
    _soft _watchdog_release_session_or_ctx "$prefix_wd"
    _soft rm -f "${prefix_wd}.session"
    ASUS_DISPLAY_MODE_WATCHDOG_PREFIX="" _soft _run_internal_watchdog
    printf '0\n' > "${prefix_wd}.session"
    _OSD_IDLE_SECS=0
    ASUS_DISPLAY_MODE_WATCHDOG_PREFIX="$prefix_wd" _soft _run_internal_watchdog
}

_run_display_watchdog_release_exercises() {
    local tmp="$1" fake_sock="$2" prefix_wd
    prefix_wd="$tmp/wd"
    mkdir -p "$(dirname "$prefix_wd")"
    printf '0\n' > "${prefix_wd}.session"
    : > "${prefix_wd}.ctx"
    _run_display_watchdog_expiry_paths "$prefix_wd"
    _run_display_watchdog_force_release_paths "$prefix_wd" "$fake_sock"
    _run_display_watchdog_retry_poll_paths "$prefix_wd"
    _run_display_watchdog_poll_loop_paths "$prefix_wd" "$fake_sock"
}

_run_display_watchdog_stale_lock_paths() {
    local prefix_wd="$1"
    mkdir -p "${prefix_wd}.wd.lock"
    : > "${prefix_wd}.wd.pid"
    _soft _try_clear_stale_watchdog_lock "${prefix_wd}.wd.lock" "${prefix_wd}.wd.pid"
    # Live pid → try_clear returns 1 (keep lock owner).
    echo "$$" > "${prefix_wd}.wd.pid"
    _soft_expect 1 _try_clear_stale_watchdog_lock "${prefix_wd}.wd.lock" "${prefix_wd}.wd.pid"
    _soft_expect 1 _acquire_watchdog_lock "${prefix_wd}.wd.lock" "${prefix_wd}.wd.pid"
    _soft rm -f "${prefix_wd}.wd.pid"
    _soft _try_clear_stale_watchdog_lock "${prefix_wd}.wd.lock" "${prefix_wd}.wd.pid"
    _soft _acquire_watchdog_lock "${prefix_wd}.wd.lock2" "${prefix_wd}.wd.pid"
    _soft rmdir "${prefix_wd}.wd.lock2" 2>/dev/null
    # Stale lock + dead pid → acquire retries clear path.
    mkdir -p "${prefix_wd}.wd.lock3"
    echo "1" > "${prefix_wd}.wd.pid"
    _soft _acquire_watchdog_lock "${prefix_wd}.wd.lock3" "${prefix_wd}.wd.pid"
    _soft rmdir "${prefix_wd}.wd.lock3" 2>/dev/null
    _soft _wait_watchdog_pid_file "${prefix_wd}.missing.wd.pid"
}

_kill_watchdog_if_live() {
    local wd_pid="$1"
    if _display_watchdog_pid_is_live "${wd_pid:-}"; then
        _soft kill -9 "$wd_pid" 2>/dev/null
    fi
}

_run_display_watchdog_spawn_iso_paths() {
    local tmp="$1" prefix="$2" prefix_wd="$3" iso wd_pid saved_path
    iso=$(mktemp -d "$tmp/iso.XXXXXX")
    _link_iso_tools "$iso" bash sh cat echo sleep date kill mkdir env setsid
    export _ASUS_DISPLAY_MODE_ENTRY="$REPO_ROOT/bin/asus-display-mode.sh"
    saved_path="$PATH"
    PATH="$iso"
    wd_pid=$(_resolve_spawned_display_watchdog_pid "$iso" "$prefix")
    PATH="$saved_path"
    _cleanup_display_watchdog_process "$wd_pid" "$prefix"
    _kill_watchdog_if_live "${wd_pid:-}"
    _soft rm -f "${prefix}.wd.pid" "${prefix}.session" "${prefix}.ctx" "${prefix}.cancel"
    _soft rm -f "${prefix_wd}.session" "${prefix_wd}.ctx" "${prefix_wd}.cancel"
    _soft rm -rf "${prefix_wd}.wd.lock"
    _ASUS_DISPLAY_MODE_ENTRY="" BIN_ROOT="$tmp/missing-bin" \
        _soft _spawn_detached_watchdog "$prefix_wd" >/dev/null
}

_run_display_watchdog_ensure_paths() {
    local prefix="$1" wd_pid
    # ensure_watchdog happy path (setsid spawn + wait).
    printf '%s\n' "$(( $(date +%s) + 2 ))" > "${prefix}.session"
    : > "${prefix}.ctx"
    export _ASUS_DISPLAY_MODE_ENTRY="$REPO_ROOT/bin/asus-display-mode.sh"
    _soft _ensure_watchdog "$prefix"
    if [ -f "${prefix}.wd.pid" ]; then
        wd_pid=$(cat "${prefix}.wd.pid" 2>/dev/null) || wd_pid=""
        _cleanup_display_watchdog_process "${wd_pid:-}" "$prefix"
        _kill_watchdog_if_live "${wd_pid:-}"
    fi
    _soft rm -f "${prefix}.wd.pid" "${prefix}.session" "${prefix}.ctx" "${prefix}.cancel"
}

_run_display_watchdog_spawn_exercises() {
    local tmp="$1" prefix="$2" fake_sock="$3" prefix_wd
    prefix_wd="$tmp/wd"
    _run_display_watchdog_stale_lock_paths "$prefix_wd"
    _run_display_watchdog_spawn_iso_paths "$tmp" "$prefix" "$prefix_wd"
    _run_display_watchdog_ensure_paths "$prefix"
    : "$fake_sock"
}

_run_display_state_cache_exercises() {
    local tmp="$1" prefix="$2"
    # Cache hits must run in the parent shell (_exercise subshells drop cache).
    # Use empty strings (not unset) so set -u product checks stay safe.
    _ASUS_DISPLAY_MODE_DIR_CACHE=""
    _ASUS_DISPLAY_MODE_PREFIX_CACHE=""
    export NOTIF_ID_ROOT="$tmp/notif-cache"
    _soft unset ASUS_DISPLAY_MODE_STATE_PREFIX
    _soft_expect 0 _display_state_dir >/dev/null
    _soft_expect 0 _display_state_dir >/dev/null
    _soft_expect 0 _display_state_prefix >/dev/null
    _soft_expect 0 _display_state_prefix >/dev/null
    export ASUS_DISPLAY_MODE_STATE_PREFIX="$prefix"
}
