#!/usr/bin/env bash

_soft() { "$@" || return 0; }

_soft_expect() {
    local allowed="$1" status=0
    shift
    "$@" || status=$?
    case ",${allowed}," in
        *",${status},"*) return 0 ;;
    esac
    return "$status"
}

_kcov_record_scenario_failure() {
    # Append one failure line for end-of-suite fail-closed checks.
    local kind="$1" detail="$2"
    local fail_file="${KCOV_SCENARIO_FAIL_FILE:-}"
    [ -n "$fail_file" ] || return 0
    printf '%s\t%s\n' "$kind" "$detail" >>"$fail_file" || true
}

_kcov_fail_file_has_entries() {
    local fail_file="${KCOV_SCENARIO_FAIL_FILE:-}"
    [ -n "$fail_file" ] && [ -s "$fail_file" ]
}

_kcov_bind_path_is_safe() {
    local bus_path="$1"
    case "$bus_path" in
        /run/user|/run/user/*)
            echo "Warning: refusing to bind over system runtime path $bus_path" >&2
            return 1
            ;;
    esac
    if [ -e "$bus_path" ] && [ ! -S "$bus_path" ]; then
        echo "Warning: refusing to remove non-socket path $bus_path" >&2
        return 1
    fi
}

_kcov_socket_owner_is_safe() {
    local bus_path="$1" owner
    local safe_path="/usr/bin:/bin"
    if [ -S "$bus_path" ]; then
        owner=$(PATH="$safe_path" stat -c '%u' "$bus_path" 2>/dev/null) || owner=""
        if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
            echo "Warning: refusing to remove socket owned by uid $owner: $bus_path" >&2
            return 1
        fi
    fi
}

_kcov_bind_warning() {
    local bus_path="$1" sock_tmp="$2"
    echo "Warning: AF_UNIX bind failed for $bus_path (staging path length: ${#sock_tmp})" >&2
}

_kcov_create_socket_stage() {
    local bus_path="$1" parent stage_dir
    local safe_path="/usr/bin:/bin"
    case "$bus_path" in
        */*) parent="${bus_path%/*}" ;;
        *) parent="." ;;
    esac
    [ -n "$parent" ] || parent="/"
    stage_dir=$(PATH="$safe_path" mktemp -d "$parent/.kcov-bus.XXXXXX" 2>/dev/null) || {
        _kcov_bind_warning "$bus_path" "$bus_path"
        return 1
    }
    if ! PATH="$safe_path" chmod 0700 "$stage_dir"; then
        PATH="$safe_path" rm -rf "$stage_dir"
        _kcov_bind_warning "$bus_path" "$bus_path"
        return 1
    fi
    printf '%s\n' "$stage_dir"
}

_kcov_create_staged_socket() {
    local bus_path="$1" sock_dir="$2" sock_tmp
    local safe_path="/usr/bin:/bin"
    sock_tmp="$sock_dir/sock"
    if [ -z "$sock_tmp" ] || [ "${#sock_tmp}" -ge 108 ]; then
        PATH="$safe_path" rm -rf "$sock_dir"
        _kcov_bind_warning "$bus_path" "$sock_tmp"
        return 1
    fi
    if ! PATH="$safe_path" python3 -c \
        "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()" \
        "$sock_tmp" 2>/dev/null; then
        PATH="$safe_path" rm -rf "$sock_dir"
        _kcov_bind_warning "$bus_path" "$sock_tmp"
        return 1
    fi
}

_kcov_move_staged_socket() {
    local bus_path="$1" sock_dir="$2" sock_tmp="$2/sock"
    local safe_path="/usr/bin:/bin"
    if ! PATH="$safe_path" mv -f "$sock_tmp" "$bus_path"; then
        PATH="$safe_path" rm -rf "$sock_dir"
        _kcov_bind_warning "$bus_path" "$sock_tmp"
        return 1
    fi
    PATH="$safe_path" rmdir "$sock_dir" 2>/dev/null || PATH="$safe_path" rm -rf "$sock_dir"
}

_kcov_prepare_socket_stage() {
    local bus_path="$1" out_name="$2" stage_dir
    _kcov_bind_path_is_safe "$bus_path" || return 1
    _kcov_socket_owner_is_safe "$bus_path" || return 1
    stage_dir=$(_kcov_create_socket_stage "$bus_path") || return 1
    printf -v "$out_name" '%s' "$stage_dir"
}

_kcov_bind_unix_bus() {
    # Bind under a private 0700 dir then rename into place (staging reduces bind race).
    # Use a fixed safe PATH so isolated-driver PATHs still resolve mktemp/mv/stat/python3.
    local bus_path="$1" sock_dir
    _kcov_prepare_socket_stage "$bus_path" sock_dir || return 1
    _kcov_create_staged_socket "$bus_path" "$sock_dir" || return 1
    _kcov_move_staged_socket "$bus_path" "$sock_dir" || return 1
    return 0
}

_bind_unix_socket_path() {
    _kcov_bind_unix_bus "$@"
}

_kcov_repo_root_from_source() {
    [ -n "${BASH_SOURCE[0]:-}" ] || return 1
    (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
}

_kcov_repo_root() {
    # Memoize in KCOV_REPO_ROOT in the caller shell; subshells from $(...) cannot
    # persist assignments made here, so callers must assign: KCOV_REPO_ROOT="$(_kcov_repo_root)".
    local resolved
    if [ -n "${KCOV_REPO_ROOT:-}" ]; then
        printf '%s\n' "$KCOV_REPO_ROOT"
        return 0
    fi
    if resolved=$(_kcov_repo_root_from_source); then
        KCOV_REPO_ROOT="$resolved"
        printf '%s\n' "$KCOV_REPO_ROOT"
        return 0
    fi
    resolved=$(pwd) || return 1
    KCOV_REPO_ROOT="$resolved"
    printf '%s\n' "$KCOV_REPO_ROOT"
}

_kcov_clamp_run_timeout() {
    local timeout_secs="${KCOV_RUN_TIMEOUT_SECS:-45}"
    case "$timeout_secs" in
        ''|*[!0-9]*)
            echo "Warning: KCOV_RUN_TIMEOUT_SECS=${timeout_secs:-<empty>} is non-numeric; clamping to 45" >&2
            printf '45\n'
            return 0
            ;;
    esac
    # Values below 1 intentionally clamp to 45 (same ceiling as >45), not to 1.
    if [ "$timeout_secs" -lt 1 ] || [ "$timeout_secs" -gt 45 ]; then
        echo "Warning: KCOV_RUN_TIMEOUT_SECS=${timeout_secs} outside 1–45; clamping to 45" >&2
        printf '45\n'
        return 0
    fi
    printf '%s\n' "$timeout_secs"
}

_kcov_run() {
    local kcov_root="$1" label="$2"
    shift 2
    local out="$kcov_root/runs/$label"
    local log_file="$kcov_root/logs/${label}.log"
    local status timeout_secs repo_root
    local -a include_args
    timeout_secs="$(_kcov_clamp_run_timeout)"
    KCOV_REPO_ROOT="$(_kcov_repo_root)"
    repo_root="$KCOV_REPO_ROOT"
    # Product shell + coverage drivers (drivers live outside bin/lib; without them
    # in include-path, kcov drops hits for sourced product libs when the entry
    # script is a driver). Do not widen to the whole repository root.
    include_args=(
        --include-path="${repo_root}/bin,${repo_root}/lib,${repo_root}/install.sh,${repo_root}/uninstall.sh,${repo_root}/scripts/coverage/drivers"
    )
    mkdir -p "$out" "$kcov_root/logs"
    if ! command -v timeout >/dev/null 2>&1; then
        echo "    ✗ kcov scenario $label requires timeout on PATH (refusing unbounded run)" >&2
        return 127
    fi
    if ! command -v kcov >/dev/null 2>&1; then
        echo "    ✗ kcov scenario $label requires kcov on PATH" >&2
        return 127
    fi
    status=0
    # Force msgid-only gettext under kcov: real gettext nesting makes kcov+bash
    # drop caller line hits (fan/camera/display notify paths fall below 90%).
    # i18n_helpers unset ASUS_I18N_FORCE_MSGID to exercise the real gettext path.
    timeout --signal=KILL "${timeout_secs}s" \
        env ASUS_I18N_FORCE_MSGID="${ASUS_I18N_FORCE_MSGID:-1}" \
        kcov "${include_args[@]}" "$out" "${@}" \
        >"$log_file" 2>&1 || status=$?
    echo "    - kcov scenario: $label (exit: $status, log: $log_file)"
    return "$status"
}

_kcov_shift_leading_env_exports() {
    local assign_key
    while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
        assign_key="${1%%=*}"
        [[ "$assign_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break
        export "${assign_key}=${1#*=}"
        shift
    done
    if [ "$#" -eq 0 ]; then
        echo "kcov env-shift: no command remaining after leading assignments" >&2
        return 127
    fi
    "$@"
}

_export_leading_env_assigns() {
    _kcov_shift_leading_env_exports "$@"
}

_run_with_optional_env() {
    if [ "$#" -gt 0 ] && [ "$1" = "env" ]; then
        shift
        ( _export_leading_env_assigns "$@" )
        return $?
    fi
    "$@"
}

_restore_errexit_state() {
    local had_errexit="$1"
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    else
        set +e
    fi
}

_kcov_expect_exit() {
    local expected_csv="$1"
    shift
    local status
    local had_errexit=0
    case "$-" in
        *e*) had_errexit=1 ;;
    esac
    set +e
    _run_with_optional_env "$@"
    status=$?
    _restore_errexit_state "$had_errexit"
    case "$status" in
        124|137)
            echo "  ✗ kcov scenario timed out or killed: exit $status" >&2
            _kcov_record_scenario_failure "timeout" "exit $status"
            return 1
            ;;
    esac
    case ",${expected_csv}," in
        *,"$status",*) return 0 ;;
    esac
    echo "  ✗ Unexpected kcov scenario exit: got $status, expected one of [$expected_csv]" >&2
    _kcov_record_scenario_failure "unexpected" "got $status expected [$expected_csv]"
    return 1
}

_kcov_expect_run() {
    local expected_csv="$1" kcov_root="$2" label="$3"
    shift 3
    _kcov_expect_exit "$expected_csv" _kcov_run "$kcov_root" "$label" "$@"
}

_kcov_expect_run_env() {
    local expected_csv="$1" kcov_root="$2" label="$3"
    shift 3
    local -a env_pairs
    env_pairs=()
    while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
        env_pairs+=("$1")
        shift
    done
    _kcov_expect_exit "$expected_csv" env "${env_pairs[@]}" _kcov_run "$kcov_root" "$label" "$@"
}

_kcov_expect_direct_run_env() {
    # Direct (non-kcov) runs still must capture stdout/stderr under kcov_root/logs so
    # expected product errors do not leak into the live pipeline log as false alarms.
    local expected_csv="$1" kcov_root="$2" label="$3"
    shift 3
    local -a env_pairs
    local status log_file timeout_secs
    local had_errexit=0
    env_pairs=()
    while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
        env_pairs+=("$1")
        shift
    done
    case "$-" in
        *e*) had_errexit=1 ;;
    esac
    mkdir -p "$kcov_root/logs"
    log_file="$kcov_root/logs/${label}.log"
    timeout_secs="$(_kcov_clamp_run_timeout)"
    if ! command -v timeout >/dev/null 2>&1; then
        echo "    ✗ Direct scenario $label requires timeout on PATH (refusing unbounded run)" >&2
        return 127
    fi
    set +e
    _run_with_optional_env env "${env_pairs[@]}" \
        timeout --signal=KILL "${timeout_secs}s" "$@" >"$log_file" 2>&1
    status=$?
    _restore_errexit_state "$had_errexit"
    echo "    - direct scenario: $label (exit: $status, log: $log_file)"
    case "$status" in
        124|137)
            echo "  ✗ Direct scenario timed out/killed: exit $status (log: $log_file)" >&2
            _kcov_record_scenario_failure "direct-timeout" "$label exit $status"
            return 1
            ;;
    esac
    case ",${expected_csv}," in
        *,"$status",*) return 0 ;;
    esac
    echo "  ✗ Unexpected direct scenario exit: got $status, expected one of [$expected_csv]" >&2
    echo "    log: $log_file" >&2
    _kcov_record_scenario_failure "direct-unexpected" "$label got $status expected [$expected_csv]"
    return 1
}

_make_fake_loginctl_script() {
    local repo_root
    KCOV_REPO_ROOT="$(_kcov_repo_root)"
    repo_root="$KCOV_REPO_ROOT"
    python3 "$repo_root/tools/make_fake_loginctl.py" "$@"
}

_make_fake_loginctl_current_user() {
    # Session user must exist in passwd so fail-closed _run_as_user can same-user exec.
    local tmp="$1"
    _make_fake_loginctl_script --current-user "$tmp"
    _make_fake_id_current_user "$tmp"
}

_make_fake_id_current_user() {
    # PATH-shadowed `id` must still report the real username so _run_as_user
    # same-user-exec works (a stub that only echoes UID breaks id -un).
    local tmp="$1" user uid
    user="$(id -un)"
    uid="$(id -u)"
    if ! [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
        echo "fake id stub: invalid username '$user'" >&2
        return 1
    fi
    if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
        echo "fake id stub: invalid uid '$uid'" >&2
        return 1
    fi
    cat > "$tmp/id" <<EOF
#!/bin/sh
if [ "\$1" = "-un" ] || [ "\$1" = "-nu" ]; then
    printf '%s\\n' '$user'
    exit 0
fi
if [ "\$1" = "-u" ]; then
    printf '%s\\n' '$uid'
    exit 0
fi
printf '%s\\n' '$uid'
EOF
    chmod +x "$tmp/id"
}

_kcov_isolated_bin_dir() {
    # Build a PATH directory with only the tools we need so real DE binaries
    # (systemsettings, gnome-control-center, ydotool, …) cannot short-circuit
    # fallback coverage paths.
    local dest="$1"
    local tool src
    shift
    mkdir -p "$dest"
    for tool in bash sh env cat echo cut head tr grep awk sed id getent mkdir rm \
        chmod mktemp sleep timeout kcov python3 true false dirname basename which \
        printf ls "$@"
    do
        src=$(type -P "$tool" 2>/dev/null || true)
        if [ -n "$src" ] && [ -x "$src" ]; then
            ln -sf "$src" "$dest/$tool"
        fi
    done
}

_write_sudo_stub() {
    local mock="$1"
    cat > "$mock/sudo" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n) shift ;;
        -u)
            if [ "$#" -ge 2 ]; then
                shift 2
            else
                shift
                break
            fi
            ;;
        -*) shift ;;
        *=*) export "$1"; shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
    chmod +x "$mock/sudo"
}

_make_fake_sudo_script() {
    _write_sudo_stub "$1"
}

_make_fake_gsettings_script() {
    local tmp="$1"
    cat <<'EOF' > "$tmp/gsettings"
#!/bin/sh
case "$1" in
    list-keys) echo "switch-video-mode" ;;
    get) echo "['mock_value']" ;;
    set) [ "${FAIL_GSETTINGS:-0}" = "1" ] && exit 1 ;;
esac
exit 0
EOF
    chmod +x "$tmp/gsettings"
}

_kcov_make_stub() {
    local path="$1" body="${2:-exit 0}"
    printf '#!/bin/sh\n%s\n' "$body" > "$path"
    chmod +x "$path"
}

_link_kcov_tool() {
    local iso_tmp="$1" tool="$2" tool_path
    tool_path=$(type -P "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ] && [ -x "$tool_path" ]; then
        ln -sf "$tool_path" "$iso_tmp/$tool"
    fi
}

_copy_kcov_env_files() {
    local tmp="$1" iso_tmp="$2" entry
    for entry in "$tmp/"*; do
        [ -f "$entry" ] || continue
        cp "$entry" "$iso_tmp/" || return 1
    done
}

_setup_isolated_kcov_env() {
    local tmp="$1" iso_tmp="$2" tool
    _copy_kcov_env_files "$tmp" "$iso_tmp" || return 1
    for tool in sh bash env cat echo cut head tr grep test [ dirname basename mktemp rm mkdir hda-verb; do
        if [ "$tool" = "hda-verb" ]; then
            if ! type -P "$tool" >/dev/null 2>&1; then
                printf '#!/bin/sh\nexit 0\n' > "$iso_tmp/$tool"
                chmod +x "$iso_tmp/$tool"
            fi
        else
            _link_kcov_tool "$iso_tmp" "$tool"
        fi
    done
}
