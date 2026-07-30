#!/usr/bin/env bash
# Shared kcov driver helpers (sourced by coverage drivers).
# By default discards nonzero status so set -e drivers can keep exercising
# negative paths. Set KCOV_EXERCISE_RETURN_STATUS=1 to propagate status.
# _exercise runs the target in a subshell: variable and shell-option changes do
# not persist in the driver, while filesystem side effects do.

# shellcheck source=scripts/coverage/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

_driver_source_i18n() {
    # Install helpers call _asus_gettext; load the same helper install.sh sources.
    # shellcheck source=lib/asus-i18n.sh
    if ! source "${REPO_ROOT}/lib/asus-i18n.sh" >/dev/null 2>&1; then
        echo "driver: failed to source lib/asus-i18n.sh" >&2
        return 1
    fi
}

_link_iso_tools() {
    local iso="$1" tool src
    shift
    local -a tools=(
        bash sh cut mkdir cat rm chmod true getent env dirname tail
    )
    if [ "$#" -gt 0 ]; then
        tools=("$@")
    fi
    mkdir -p "$iso"
    for tool in "${tools[@]}"; do
        src=$(type -P "$tool" 2>/dev/null || true)
        [ -n "$src" ] || continue
        ln -sf "$src" "$iso/$tool"
    done
}

_link_iso_additional_tools() {
    local iso="$1" tool src
    shift
    for tool in "$@"; do
        src=$(type -P "$tool" 2>/dev/null) || src=""
        [ -n "$src" ] || continue
        ln -sf "$src" "$iso/$tool"
    done
}

_driver_set_prefix() {
    local owned_name="$1" prefix
    if [ -n "${DESTDIR:-}" ]; then
        prefix="$DESTDIR"
        printf -v "$owned_name" '%s' 0
    else
        prefix=$(mktemp -d) || return 1
        printf -v "$owned_name" '%s' 1
    fi
    export PREFIX="$prefix"
}

_driver_source_required() {
    local path="$1" label="$2" quiet="${3:-}"
    local status=0
    if [ "$quiet" = "quiet" ]; then
        source "$path" >/dev/null 2>&1 || status=$?
    else
        source "$path" || status=$?
    fi
    if [ "$status" -ne 0 ]; then
        echo "$label: failed to source ${path#"$REPO_ROOT/"}" >&2
        return 1
    fi
}

_driver_bind_required() {
    local path="$1" label="$2"
    if ! _bind_unix_socket_path "$path"; then
        echo "$label: failed to bind session bus socket at $path" >&2
        return 1
    fi
}

# _write_sudo_stub / _make_fake_sudo_script come from scripts/coverage/common.sh.

_restore_or_unset() {
    # Restore exported var from saved value; unset when saved was empty.
    local name="$1" saved="$2"
    if [ -n "$saved" ]; then
        printf -v "$name" '%s' "$saved"
        # ${name?} marks intentional nameref export (SC2163).
        export "${name?}"
    else
        unset "$name"
    fi
}

_exercise_apply_env_assigns() {
    _kcov_shift_leading_env_exports "$@"
}

_exercise_propagate_after_other_assign() {
    local default="$1" arg="${2:-}" assign_key
    shift 2 || return 1
    case "$arg" in
        *=*) ;;
        *) printf '%s\n' "$default"; return 0 ;;
    esac
    assign_key="${arg%%=*}"
    if [[ ! "$assign_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    _exercise_propagate_status "$default" "$@"
}

_exercise_propagate_status() {
    local default="$1" arg="${2:-}"
    shift 2 || return 1
    case "$arg" in
        KCOV_EXERCISE_RETURN_STATUS=1)
            _exercise_propagate_status 1 "$@"
            ;;
        KCOV_EXERCISE_RETURN_STATUS=0)
            _exercise_propagate_status 0 "$@"
            ;;
        "")
            printf '%s\n' "$default"
            ;;
        *)
            _exercise_propagate_after_other_assign "$default" "$arg" "$@"
            ;;
    esac
}

_exercise() {
    local status=0
    local had_errexit=0
    local propagate
    # Only leading key=value assigns may override propagate (match env-export shift).
    propagate="$(_exercise_propagate_status "${KCOV_EXERCISE_RETURN_STATUS:-0}" "$@" "")"
    case "$-" in
        *e*) had_errexit=1 ;;
    esac
    set +e
    ( _exercise_apply_env_assigns "$@" )
    status=$?
    _restore_errexit_state "$had_errexit"
    if [ "$propagate" = "1" ]; then
        return "$status"
    fi
    return 0
}

_expect_bash_snippet_failure() {
    # Run a bash -o pipefail snippet through tee; return 1 when it unexpectedly succeeds.
    local snippet="$1" log_path="$2" fail_message="$3"
    local status=0 had_errexit=0
    case "$-" in
        *e*) had_errexit=1 ;;
    esac
    set +e
    bash -o pipefail -c "$snippet" 2>&1 | tee "$log_path" >&2
    status=${PIPESTATUS[0]}
    _restore_errexit_state "$had_errexit"
    if [ "$status" -eq 0 ]; then
        echo "$fail_message" >&2
        return 1
    fi
    return 0
}
