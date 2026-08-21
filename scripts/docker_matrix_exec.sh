#!/usr/bin/env bash
# Parallel/serial target runners for run_docker_matrix.sh (sourced only).
# Relies on REPO_ROOT, DRY_RUN, PARALLEL, COMPAT_ONLY, RUN_COVERAGE_GATE,
# DE_FAMILY, and helpers defined by the caller (run_target, container_name_for_distro, …).

_print_distro_log() {
    local name="$1" log="$2"
    printf '\n%s\n' "══════════════════════════════════════"
    printf '  FAILURE LOG: %s\n' "$name"
    printf '%s\n\n' "══════════════════════════════════════"
    cat "$log"
}

_print_failure_details() {
    local -n __names="$1" __logs="$2" __failing_indices="$3"
    local idx
    for idx in "${__failing_indices[@]}"; do
        _print_distro_log "${__names[$idx]}" "${__logs[$idx]}"
    done
}

_parallel_report_done() {
    _parallel_report_done_job "$1" "$2" "$3" "$4" "$5" _print_distro_log
}

_collect_parallel_results() {
    local -n _pids="$1" _names="$2" _logs="$3"
    # Distinct copy names: local pids/names/logs would shadow nameref targets.
    local -a pid_copies=("${_pids[@]}")
    local -a name_copies=("${_names[@]}")
    local -a log_copies=("${_logs[@]}")
    local done_pid="" code=0 report_status=0

    while [ "${#pid_copies[@]}" -gt 0 ]; do
        done_pid=""
        set +e
        wait -n -p done_pid "${pid_copies[@]}"
        code=$?
        _parallel_report_done "$done_pid" "$code" pid_copies name_copies log_copies
        report_status=$?
        set -e
        if [ "$report_status" -eq 1 ]; then
            _kill_pgid_list "${pid_copies[@]}"
            return 1
        fi
        if [ "$report_status" -eq 2 ]; then
            break
        fi
    done
    return 0
}

_run_targets_dry() {
    local image
    for image in "$@"; do
        run_target "$image"
    done
}

_restore_buildx_skip_prune() {
    local had_skip_prune="$1" saved_skip_prune="$2"
    if [ "$had_skip_prune" = 1 ]; then
        DOCKER_BUILDX_SKIP_PRUNE="$saved_skip_prune"
    else
        unset DOCKER_BUILDX_SKIP_PRUNE
    fi
}

run_targets_parallel() {
    # In dry-run mode, just run sequentially so output isn't redirected.
    if [[ "$DRY_RUN" == "1" ]]; then
        _run_targets_dry "$@"
        return
    fi
    # Parallel buildx jobs can race with local cache pruning/removal.
    local had_skip_prune=0 saved_skip_prune=""
    if [ "${DOCKER_BUILDX_SKIP_PRUNE+x}" = "x" ]; then
        had_skip_prune=1
        saved_skip_prune="$DOCKER_BUILDX_SKIP_PRUNE"
    fi
    export DOCKER_BUILDX_SKIP_PRUNE=1
    local log_dir="$REPO_ROOT/reports/distro-logs"
    mkdir -p "$log_dir"
    local pids=() names=() logs=()
    local image slug log container_name
    for image in "$@"; do
        slug="$(_matrix_log_slug_for_image "$image")"
        log="$log_dir/${slug}.log"
        logs+=("$log")
        container_name=$(container_name_for_distro "$image")
        register_active_container "$container_name"
        printf '  ▶ Launching: %s  →  reports/distro-logs/%s.log\n' "$image" "$slug"
        setsid bash -c '
            trap - EXIT INT TERM
            set -o pipefail
            export ASUS_DOCKER_MATRIX_COMPAT_ONLY="$4"
            export ASUS_DOCKER_MATRIX_COVERAGE_GATE="$5"
            export ASUS_DOCKER_MATRIX_DE_FAMILY="$6"
            source "$1/scripts/run_docker_matrix.sh"
            run_target "$2" 2>&1 | tee "$3"
        ' bash "$REPO_ROOT" "$image" "$log" "$COMPAT_ONLY" "$RUN_COVERAGE_GATE" "$DE_FAMILY" &
        pids+=("$!")
        register_active_pid "$!"
        names+=("$image")
    done
    printf '\nWaiting for all distros...\n'
    local status=0
    _collect_parallel_results pids names logs || status=$?
    _restore_buildx_skip_prune "$had_skip_prune" "$saved_skip_prune"
    _docker_prune_buildx_local_cache "$DOCKER_BUILD_CACHE_DIR" "$DOCKER_BUILD_CACHE_DIR"
    return "$status"
}

_print_target_distros() {
    local image distro_name
    echo "Target distros:"
    for image in "$@"; do
        # Path first (handles registry:port/...), then digest/tag — not %%:* first.
        distro_name="${image##*/}"
        distro_name="${distro_name%%@*}"
        distro_name="${distro_name%%:*}"
        echo "- $distro_name -> $image"
    done
}

_matrix_log_slug_for_image() {
    # Coverage shards share image name "coverage-gate"; disambiguate logs so
    # parallel ASUS_COVERAGE_MODE/SHARD workers do not truncate each other.
    local image="$1"
    if [[ "$image" == "coverage-gate" && -n "${ASUS_COVERAGE_MODE:-}" ]]; then
        printf 'coverage-gate-%s-%s\n' "$ASUS_COVERAGE_MODE" "${ASUS_COVERAGE_SHARD:-all}"
        return 0
    fi
    printf '%s\n' "${image//[:\/]/-}"
}

_matrix_capture_run_target_status() {
    # nameref status_ref; run_target | tee log → status. Restores caller errexit.
    local image="$1" log="$2"
    local -n _mcs_status="$3"
    local had_errexit=0 rt_status=0 tee_status=0
    case "$-" in
        *e*) had_errexit=1 ;;
    esac
    set +e
    run_target "$image" 2>&1 | tee "$log"
    # One assignment: reading PIPESTATUS[0] alone resets the array under bash.
    local -a _mcs_pipe=("${PIPESTATUS[@]}")
    rt_status=${_mcs_pipe[0]:-1}
    tee_status=${_mcs_pipe[1]:-1}
    if [ "$rt_status" -ne 0 ]; then
        _mcs_status=$rt_status
    elif [ "$tee_status" -ne 0 ]; then
        _mcs_status=$tee_status
    else
        _mcs_status=0
    fi
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi
}

_matrix_fail_closed_on_kcov_log() {
    local image="$1" log="$2" code="$3"
    case "$code" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$code" -eq 0 ] && grep -Fq 'kcov scenario suite failed' "$log" 2>/dev/null; then
        echo "  ✗ $image log reports kcov suite failure but process exit was 0" >&2
        return 1
    fi
    return "$code"
}

_run_one_serial_target() {
    local image="$1" log="$2" code=0
    if [[ "$DRY_RUN" == "1" ]]; then
        run_target "$image" || code=$?
        return "$code"
    fi
    # Always capture PIPESTATUS[0] (do not rely on `cmd || code=$?` alone).
    _matrix_capture_run_target_status "$image" "$log" code
    _matrix_fail_closed_on_kcov_log "$image" "$log" "$code"
}

_report_serial_target() {
    local image="$1" log="$2" code="$3"
    if [[ "$code" -ne 0 ]]; then
        printf '  ✗ Failed: %s  →  %s\n' "$image" "$log" >&2
        return 1
    fi
    printf '  ✓ Passed: %s\n' "$image"
}

_run_serial_targets() {
    local image log_dir="$REPO_ROOT/reports/distro-logs"
    local slug log failures=0 code
    mkdir -p "$log_dir"
    for image in "$@"; do
        slug="$(_matrix_log_slug_for_image "$image")"
        log="$log_dir/${slug}.log"
        code=0
        _run_one_serial_target "$image" "$log" || code=$?
        _report_serial_target "$image" "$log" "$code" || failures=1
    done
    return "$failures"
}

_run_all_targets() {
    if [[ "$PARALLEL" -eq 1 && $# -gt 1 ]]; then
        run_targets_parallel "$@"
        return $?
    fi
    _run_serial_targets "$@"
}
