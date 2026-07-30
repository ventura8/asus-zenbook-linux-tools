#!/bin/bash
# Display-mode helper library (sourced by bin/asus-display-mode.sh).

_watchdog_force_release() {
    # Drop Super even when a peer holds the flock indefinitely.
    local prefix="$1"
    if _open_display_mode_flock_fd "$prefix" && flock -n 9 2>/dev/null; then
        _release_osd_modifiers "$prefix"
        _release_display_mode_lock
        return 0
    fi
    _release_osd_modifiers "$prefix"
    exec 9>&- || true
    return 0
}

_watchdog_release_with_retries() {
    local prefix="$1" deadline max_secs="${ASUS_DISPLAY_MODE_WD_RELEASE_SECS:-10}"
    [[ "$max_secs" =~ ^[1-9][0-9]*$ ]] || max_secs=10
    deadline=$(( $(date +%s) + max_secs ))
    while ! _watchdog_release_if_idle "$prefix"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            _watchdog_force_release "$prefix"
            return 0
        fi
        sleep 0.15
    done
}

_watchdog_session_still_active() {
    # True when .session exists with a future expiry (re-armed after release).
    local prefix="$1" expiry now
    [ -f "${prefix}.session" ] || return 1
    expiry=$(_session_expiry_epoch "$(cat "${prefix}.session" 2>/dev/null)") || return 1
    [ "$expiry" -gt 0 ] || return 1
    now=$(date +%s)
    [ "$now" -lt "$expiry" ]
}

_watchdog_release_then_maybe_continue() {
    # Release once; return 0 to keep polling if session was re-armed.
    local prefix="$1"
    _watchdog_release_with_retries "$prefix"
    _watchdog_session_still_active "$prefix"
}

_watchdog_expiry_needs_release() {
    # True when expiry is missing/zero or wall clock has passed it.
    local expiry="$1" now="$2"
    [ "$expiry" -eq 0 ] && return 0
    [ "$expiry" -gt 0 ] && [ "$now" -ge "$expiry" ]
}

_watchdog_poll_tick() {
    # Return 0 = keep looping, 1 = exit poll loop.
    local prefix="$1" expiry now
    expiry=$(_session_expiry_epoch "$(cat "${prefix}.session" 2>/dev/null)") || expiry=0
    now=$(date +%s)
    if _watchdog_expiry_needs_release "$expiry" "$now"; then
        _watchdog_release_then_maybe_continue "$prefix" && return 0
        return 1
    fi
    sleep 0.15
    return 0
}

_watchdog_poll_loop() {
    local prefix="$1"
    if [ ! -f "${prefix}.session" ]; then
        # State write failed; still drop Super after idle so it cannot stick.
        sleep "${_OSD_IDLE_SECS:-2}"
        _watchdog_release_with_retries "$prefix"
        return 0
    fi
    while [ -f "${prefix}.session" ]; do
        _watchdog_poll_tick "$prefix" || return 0
    done
}

_watchdog_release_session_or_ctx() {
    local prefix="$1" expiry now
    if [ ! -f "${prefix}.session" ]; then
        [ -f "${prefix}.ctx" ] && _release_osd_modifiers "$prefix"
        return 0
    fi
    expiry=$(_session_expiry_epoch "$(cat "${prefix}.session" 2>/dev/null)") || expiry=0
    now=$(date +%s)
    if _watchdog_expiry_needs_release "$expiry" "$now"; then
        _release_osd_modifiers "$prefix"
    fi
    return 0
}

_watchdog_release_if_idle() {
    # Serialize release against main/--cancel-osd so modifiers/session cannot race.
    local prefix="$1"
    _acquire_display_mode_lock "$prefix" || return 1
    if _osd_cancel_in_progress "$prefix"; then
        # Esc dismiss (--cancel-osd) owns modifier release; do not apply-release Super.
        _release_display_mode_lock
        return 0
    fi
    _watchdog_release_session_or_ctx "$prefix"
    _release_display_mode_lock
    return 0
}

_spawn_detached_watchdog() {
    local prefix="$1" self
    # Prefer the entry script path set by bin/asus-display-mode.sh. BASH_SOURCE here
    # is lib/asus-display-watchdog.sh after the state/watchdog/osd split.
    self="${_ASUS_DISPLAY_MODE_ENTRY:-}"
    if [ -z "$self" ] || [ ! -f "$self" ]; then
        self="${BIN_ROOT:-/usr/local/bin}/asus-display-mode.sh"
    fi
    if [ ! -f "$self" ]; then
        echo "Error: display-mode entry script not found for watchdog spawn." >&2
        return 1
    fi
    if command -v setsid >/dev/null 2>&1; then
        # Re-exec in watchdog mode (avoids nested bash -c that breaks shellcheck).
        # 9<&- drops the display-mode flock FD so idle watchdogs cannot hold it.
        setsid env ASUS_DISPLAY_MODE_WATCHDOG_PREFIX="$prefix" \
            bash "$self" --internal-watchdog </dev/null >/dev/null 2>&1 9<&- &
    else
        (
            _soft_write_stdout "${prefix}.wd.pid" echo "$BASHPID"
            _watchdog_poll_loop "$prefix"
        ) </dev/null >/dev/null 2>&1 9<&- &
    fi
    echo "$!"
}

_watchdog_pid_alive() {
    local pid_file="$1" pid
    [ -f "$pid_file" ] || return 1
    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_watchdog_lock_backoff_ms() {
    local attempt="$1" ms=10
    while [ "$attempt" -gt 1 ]; do
        ms=$((ms * 2))
        attempt=$((attempt - 1))
        [ "$ms" -gt 50 ] && { printf '50\n'; return 0; }
    done
    printf '%s\n' "$ms"
}

_try_clear_stale_watchdog_lock() {
    local lock_dir="$1" pid_file="$2"
    if _watchdog_pid_alive "$pid_file"; then
        return 1
    fi
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
}

_watchdog_lock_sleep_attempt() {
    local attempt="$1" backoff_ms
    [ "$attempt" -ge 5 ] && return 0
    backoff_ms=$(_watchdog_lock_backoff_ms "$attempt")
    sleep "$(printf '0.%03d' "$backoff_ms")"
}

_acquire_watchdog_lock() {
    local lock_dir="$1" pid_file="$2" _i
    for _i in 1 2 3 4 5; do
        mkdir "$lock_dir" 2>/dev/null && return 0
        _try_clear_stale_watchdog_lock "$lock_dir" "$pid_file" || return 1
        _watchdog_lock_sleep_attempt "$_i"
    done
    _watchdog_pid_alive "$pid_file" && return 1
    return 2
}

_wait_watchdog_pid_file() {
    local pid_file="$1" _i
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        _watchdog_pid_alive "$pid_file" && return 0
        sleep 0.05
    done
    return 1
}

_ensure_watchdog() {
    local prefix="$1" pid_file="${1}.wd.pid" lock_dir="${1}.wd.lock" lock_status=0
    # Atomic per-prefix guard so rapid hotkey presses cannot spawn duplicate watchdogs.
    _acquire_watchdog_lock "$lock_dir" "$pid_file" || lock_status=$?
    [ "$lock_status" -eq 1 ] && return 0
    [ "$lock_status" -eq 0 ] || return 1
    # Expand lock_dir when arming the trap: under set -u, RETURN can fire after
    # locals are unset and a deferred "$lock_dir" becomes an unbound variable.
    trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' RETURN
    _watchdog_pid_alive "$pid_file" && return 0
    # Spawn returns $! but liveness is owned exclusively by ${prefix}.wd.pid.
    _spawn_detached_watchdog "$prefix" >/dev/null
    _wait_watchdog_pid_file "$pid_file"
}

_run_internal_watchdog() {
    local prefix="${ASUS_DISPLAY_MODE_WATCHDOG_PREFIX:-}" pid_file
    [ -n "$prefix" ] || return 1
    pid_file="${prefix}.wd.pid"
    _soft_write_stdout "$pid_file" echo "$BASHPID"
    _watchdog_poll_loop "$prefix"
}

