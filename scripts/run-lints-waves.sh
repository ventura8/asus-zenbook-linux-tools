#!/usr/bin/env bash
# Lint wave runners for run-lints.sh (sourced). Expects LINT_WAVE1_STEPS / LINT_WAVE2_STEPS.

_run_lint_wave() {
    local wave_name="$1"
    shift
    local -a steps=("$@")
    local -a pids=()
    local step pid status=0 step_status=0
    echo "--- Lint wave: $wave_name (${#steps[@]} parallel steps) ---"
    for step in "${steps[@]}"; do
        (
            set -euo pipefail
            "$step"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        set +e
        wait "$pid"
        step_status=$?
        set -e
        if [ "$step_status" -ne 0 ]; then
            status=1
        fi
    done
    if [ "$status" -ne 0 ]; then
        echo "  ✗ Lint wave '$wave_name' failed." >&2
        return 1
    fi
    echo "  ✓ Lint wave '$wave_name' passed."
}

_lint_wave_mode() {
    # CI/local matrix: ASUS_LINT_WAVE=cheap|heavy|all (default all).
    case "${ASUS_LINT_WAVE:-all}" in
        all|cheap|heavy) printf '%s\n' "${ASUS_LINT_WAVE:-all}" ;;
        *)
            echo "Unsupported ASUS_LINT_WAVE='${ASUS_LINT_WAVE}' (use all|cheap|heavy)" >&2
            return 1
            ;;
    esac
}

_run_selected_lint_waves() {
    local mode
    mode="$(_lint_wave_mode)" || return 1
    case "$mode" in
        cheap) _run_lint_wave "cheap-checks" "${LINT_WAVE1_STEPS[@]}" ;;
        heavy) _run_lint_wave "heavy-checks" "${LINT_WAVE2_STEPS[@]}" ;;
        all)
            _run_lint_wave "cheap-checks" "${LINT_WAVE1_STEPS[@]}" || return 1
            _run_lint_wave "heavy-checks" "${LINT_WAVE2_STEPS[@]}"
            ;;
    esac
}
