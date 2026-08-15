#!/usr/bin/env bash

usage() {
    cat <<'EOF'
Usage: run_docker_matrix.sh [--dry-run] [--serial|--parallel] [--compat-only] [--coverage-gate]
                            [--distro <image>] [--distro-family <family>] [--de-family <family>]

Runs the repository test-only pipeline inside Docker containers for supported distros.
Default matrix is always the nine distro lanes (empty ASUS_CI_DE_FAMILY / stub-CLI).
Containers run in parallel by default; use --serial for sequential execution.
Press Ctrl+C to stop all running matrix containers immediately.

Options:
  --dry-run         Print targets without executing containers.
  --serial          Run distro containers one at a time (easier to read live output).
  --parallel        Run distro containers concurrently (default).
  --compat-only     Skip coverage gates and run compatibility checks only.
  --coverage-gate   Run only the dedicated canonical coverage-gate image (debian:trixie).
  --print-supported-distros
                    Print supported matrix distro images (one per line) and exit.
  --distro <image>  Run only the specified distro image. Can be passed multiple times.
  --distro-family <name>
                    Select a package-family matrix slice: debian|rhel|suse-arch
                    (can be combined with --distro; expands to the family's images).
  --de-family <name>
                    Build with ASUS_CI_DE_FAMILY (gnome|kde|xfce|lxqt|cinnamon|mate).
                    Also accepted via env ASUS_CI_DE_FAMILY. Always-on CI full-DE job
                    uses this; local --distro + --de-family is for debug.
EOF
}

_handle_distro_arg() {
    if [[ -z "$2" || "$2" == --* ]]; then
        echo "--distro requires an image argument" >&2
        exit 1
    fi
    SELECTED_DISTROS+=("$2")
}

_handle_distro_family_arg() {
    if [[ -z "$2" || "$2" == --* ]]; then
        echo "--distro-family requires debian|rhel|suse-arch" >&2
        exit 1
    fi
    case "$2" in
        debian|rhel|suse-arch) _append_distro_family "$2" ;;
        *)
            echo "Unsupported --distro-family: $2 (use debian|rhel|suse-arch)" >&2
            exit 1
            ;;
    esac
}

_handle_de_family_arg() {
    if [[ -z "$2" || "$2" == --* ]]; then
        echo "--de-family requires gnome|kde|xfce|lxqt|cinnamon|mate" >&2
        exit 1
    fi
    case "$2" in
        gnome|kde|xfce|lxqt|cinnamon|mate)
            # Consumed by run_docker_matrix.sh after this file is sourced.
            export DE_FAMILY="$2"
            # Local --de-family implies full-DE smoke CLI/schema probes (CI sets both).
            ASUS_CI_FULL_DE="${ASUS_CI_FULL_DE:-1}"
            export ASUS_CI_FULL_DE
            ;;
        *)
            echo "Unsupported --de-family: $2" >&2
            exit 1
            ;;
    esac
}

_handle_unknown_arg() {
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 1
}

_handle_mode_arg() {
    if [[ "$1" == "--parallel" ]]; then
        export PARALLEL=1
    else
        export PARALLEL=0
    fi
}

_handle_output_switch_arg() {
    case "$1" in
        --dry-run)
            export DRY_RUN=1
            ;;
        --print-supported-distros)
            printf '%s\n' "${DISTROS[@]}"
            exit 0
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

_handle_mode_switch_arg() {
    case "$1" in
        --compat-only) COMPAT_ONLY=1 ;;
        --coverage-gate) RUN_COVERAGE_GATE=1 ;;
        --parallel|--serial) _handle_mode_arg "$1" ;;
        *) return 1 ;;
    esac
}

_handle_switch_arg() {
    _handle_output_switch_arg "$1" && return 0
    _handle_mode_switch_arg "$1"
}

_is_valued_matrix_flag() {
    case "$1" in
        --distro|--distro-family|--de-family) return 0 ;;
        *) return 1 ;;
    esac
}

_dispatch_valued_flag() {
    case "$1" in
        --distro) _handle_distro_arg "$1" "$2" ;;
        --distro-family) _handle_distro_family_arg "$1" "$2" ;;
        --de-family) _handle_de_family_arg "$1" "$2" ;;
        *) return 1 ;;
    esac
    return 0
}

_process_arg() {
    if _handle_switch_arg "$1"; then
        return
    fi
    if _dispatch_valued_flag "$1" "${2:-}"; then
        return
    fi
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        exit 0
    fi
    _handle_unknown_arg "$1"
}

_matrix_arg_has_value() {
    [ "$#" -ge 2 ] && [[ "$2" != --* ]]
}

_matrix_valued_shift_count() {
    # How many argv slots a valued flag consumes (1 without value, else 2).
    if _matrix_arg_has_value "$@"; then
        echo 2
        return
    fi
    echo 1
}

parse_args() {
    local shift_n
    while [[ $# -gt 0 ]]; do
        if _is_valued_matrix_flag "$1"; then
            shift_n="$(_matrix_valued_shift_count "$@")"
            if [[ "$shift_n" -eq 2 ]]; then
                _process_arg "$1" "$2"
            else
                _process_arg "$1" ""
            fi
            shift "$shift_n"
            continue
        fi
        _process_arg "$1"
        shift
    done
}

_validate_selected_distros() {
    local image
    for image in "${SELECTED_DISTROS[@]}"; do
        if ! is_supported_distro "$image"; then
            echo "Unsupported distro: $image" >&2
            exit 1
        fi
    done
}

validate_mode_selection() {
    if [[ "$RUN_COVERAGE_GATE" -eq 1 && "${#SELECTED_DISTROS[@]}" -gt 0 ]]; then
        echo "Do not combine --coverage-gate with --distro / --distro-family." >&2
        exit 1
    fi

    if [[ "$RUN_COVERAGE_GATE" -eq 1 && "$COMPAT_ONLY" -eq 1 ]]; then
        echo "Do not combine --coverage-gate with --compat-only." >&2
        exit 1
    fi
}
