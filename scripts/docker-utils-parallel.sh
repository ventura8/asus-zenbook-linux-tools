#!/usr/bin/env bash
# Process-group kill + parallel job bookkeeping helpers (sourced by docker-utils.sh).

_kill_pgid_if_running() {
    local pid="$1"
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
    return $?
}

_kill_pgid_any_alive() {
    local pid=""
    for pid in "$@"; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

_kill_pgid_wait_exit() {
    local deadline=$((SECONDS + 5))
    while [[ "$SECONDS" -lt "$deadline" ]]; do
        _kill_pgid_any_alive "$@" || return 0
        sleep 0.2
    done
}

_kill_pgid_force() {
    local pid=""
    for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    return $?
}

_kill_pgid_reap() {
    local pid=""
    for pid in "$@"; do
        wait "$pid" 2>/dev/null || true
    done
    return $?
}

_kill_pgid_list() {
    local pid=""
    for pid in "$@"; do
        _kill_pgid_if_running "$pid"
    done
    _kill_pgid_wait_exit "$@"
    _kill_pgid_force "$@"
    _kill_pgid_reap "$@"
    return $?
}

_parallel_array_drop_index() {
    local -n _arr_ref="$1"
    local drop_index="$2"
    unset "_arr_ref[$drop_index]"
    _arr_ref=("${_arr_ref[@]}")
    return $?
}

_parallel_report_done_job() {
    local done_pid="$1" code="$2"
    local -n _pids_ref="$3" _names_ref="$4" _logs_ref="$5"
    local on_fail_fn="${6:-}"
    local i=0
    for i in "${!_pids_ref[@]}"; do
        if [[ "${_pids_ref[$i]}" != "$done_pid" ]]; then
            continue
        fi
        if [[ "$code" -eq 0 ]]; then
            printf '  ✓ Passed: %s\n' "${_names_ref[$i]}"
        else
            printf '  ✗ Failed: %s  →  %s\n' "${_names_ref[$i]}" "${_logs_ref[$i]}" >&2
            if [[ -n "$on_fail_fn" ]]; then
                "$on_fail_fn" "${_names_ref[$i]}" "${_logs_ref[$i]}"
            fi
            return 1
        fi
        _parallel_array_drop_index _pids_ref "$i"
        _parallel_array_drop_index _names_ref "$i"
        _parallel_array_drop_index _logs_ref "$i"
        return 0
    done
    return 2
}
