#!/usr/bin/env bash

check_root() {
    local skip_raw=0 effective_raw="$EUID"
    local skip_check=0 effective_uid
    # Test-only overrides: honor SKIP_ROOT_CHECK / EFFECTIVE_UID_OVERRIDE only in ASUS_TEST_MODE.
    if [ "${ASUS_TEST_MODE:-0}" = "1" ]; then
        skip_raw="${SKIP_ROOT_CHECK:-0}"
        effective_raw="${EFFECTIVE_UID_OVERRIDE:-$EUID}"
    fi
    case "$skip_raw" in
        ''|*[!0-9]*) skip_check=0 ;;
        *) skip_check="$skip_raw" ;;
    esac
    case "$effective_raw" in
        ''|*[!0-9]*) effective_uid="$EUID" ;;
        *) effective_uid="$effective_raw" ;;
    esac
    _require_effective_root "$skip_check" "$effective_uid"
}

_require_effective_root() {
    local skip_check="$1" effective_uid="$2"
    if [ "$skip_check" -ne 1 ] && [ "$effective_uid" -ne 0 ]; then
        echo "Please run as root (use sudo)." >&2
        exit 1
    fi
}

_install_resolve_session_bus_root() {
    if [ -n "${BUS_ROOT:-}" ]; then
        printf '%s\n' "$BUS_ROOT"
        return 0
    fi
    if [ -n "${DBUS_BUS_ROOT:-}" ]; then
        printf '%s\n' "$DBUS_BUS_ROOT"
        return 0
    fi
    if [ -n "${RUN_USER_ROOT:-}" ]; then
        printf '%s\n' "$RUN_USER_ROOT"
        return 0
    fi
    printf '%s\n' "/run/user"
}

_resolve_version_file() {
    local candidate shared_dir
    local -a candidates=()
    shared_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    if [ -n "${INSTALL_SOURCE_DIR:-}" ]; then
        candidates+=("${INSTALL_SOURCE_DIR}/VERSION")
    fi
    if [ -n "${SCRIPT_DIR:-}" ]; then
        candidates+=("${SCRIPT_DIR}/VERSION")
    fi
    candidates+=("${shared_dir}/VERSION")

    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

_read_project_version() {
    local version_file version
    if ! version_file="$(_resolve_version_file)"; then
        printf '%s\n' "unknown"
        return 0
    fi
    IFS= read -r version <"$version_file" || true
    version="${version#"${version%%[![:space:]]*}"}"
    version="${version%"${version##*[![:space:]]}"}"
    if [ -z "$version" ]; then
        printf '%s\n' "unknown"
        return 0
    fi
    printf '%s\n' "$version"
}

_format_display_version() {
    local version
    version="$(_read_project_version)"
    case "$version" in
        unknown) printf '%s\n' "unknown" ;;
        v*) printf '%s\n' "$version" ;;
        *) printf 'v%s\n' "$version" ;;
    esac
}

print_setup_banner() {
    local out_fd="${1:-1}"
    local display_version
    display_version="$(_format_display_version)"
    {
        echo "=================================================="
        printf '      %s\n' "$(_asus_gettextf "ASUS ZenBook Linux Setup %s" "$display_version")"
        printf '      %s\n' "$(_asus_gettext "Hardware features for your Linux desktop")"
        echo "=================================================="
    } >&"$out_fd"
}

_asus_soft() {
    "$@" || return 0
}

_install_command_timeout_max() {
    local max_raw="${INSTALL_COMMAND_TIMEOUT_MAX:-120}"
    case "$max_raw" in
        '' | *[!0-9]*)
            echo "Invalid INSTALL_COMMAND_TIMEOUT_MAX: ${max_raw:-<empty>}" >&2
            return 1
            ;;
    esac
    if [ "$max_raw" -lt 1 ]; then
        max_raw=1
    fi
    printf '%s\n' "$max_raw"
}

_clamp_install_command_timeout() {
    local timeout_secs="$1" timeout_max="$2"
    if [ "$timeout_secs" -lt 1 ]; then
        printf '1\n'
    elif [ "$timeout_secs" -gt "$timeout_max" ]; then
        printf '%s\n' "$timeout_max"
    else
        printf '%s\n' "$timeout_secs"
    fi
}

_run_command_with_timeout() {
    local timeout_secs="$1"
    local kill_after_secs timeout_max requested_timeout_secs
    shift

    case "$timeout_secs" in
        '' | *[!0-9]*)
            echo "Invalid install command timeout: ${timeout_secs:-<empty>}" >&2
            return 1
            ;;
    esac
    if ! timeout_max=$(_install_command_timeout_max); then
        return 1
    fi
    requested_timeout_secs="$timeout_secs"
    timeout_secs="$(_clamp_install_command_timeout "$timeout_secs" "$timeout_max")"
    if [ "$timeout_secs" != "$requested_timeout_secs" ]; then
        echo "Warning: install command timeout clamped from" \
            "${requested_timeout_secs}s to ${timeout_secs}s" >&2
    fi

    if [ "${INSTALL_SKIP_TIMEOUT_WRAPPER:-0}" = "1" ]; then
        "$@"
        return $?
    fi

    if ! command -v timeout >/dev/null 2>&1; then
        echo "Missing required 'timeout' command for bounded install operations." >&2
        return 1
    fi
    kill_after_secs=2
    timeout --signal=TERM --kill-after="${kill_after_secs}s" "${timeout_secs}s" "$@"
}

_install_run_as_other_user() {
    local timeout_secs="$1" user="$2"
    shift 2
    if ! getent passwd "$user" >/dev/null 2>&1; then
        echo "Error: Unknown target user '$user'." >&2
        return 1
    fi
    # Prefer runuser then sudo (same order as product lib/asus-common.sh _run_as_user).
    if command -v runuser >/dev/null 2>&1; then
        _run_command_with_timeout "$timeout_secs" runuser -u "$user" -- "$@"
        return $?
    fi
    if command -v "${SUDO_CMD:-sudo}" >/dev/null 2>&1; then
        _run_command_with_timeout "$timeout_secs" "${SUDO_CMD:-sudo}" -n -u "$user" -- "$@"
        return $?
    fi
    echo "Error: Unable to drop privileges to '$user' (need runuser or sudo)." >&2
    return 1
}

_install_run_as_user() {
    local user="$1"
    shift
    local timeout_secs="${INSTALL_COMMAND_TIMEOUT:-15}"
    if [ "$(id -un 2>/dev/null)" = "$user" ]; then
        _run_command_with_timeout "$timeout_secs" "$@"
        return $?
    fi
    _install_run_as_other_user "$timeout_secs" "$user" "$@"
}

_try_echo_existing_file() {
    local path="$1"
    [ -f "$path" ] || return 1
    printf '%s\n' "$path"
}

_try_echo_lib_under_dir() {
    local dir="$1" helper_name="$2"
    [ -n "$dir" ] || return 1
    _try_echo_existing_file "${dir}/${helper_name}"
}

_resolve_script_lib_path() {
    local script_dir="$1"
    local helper_name="$2"
    local helper_label="$3"

    if _try_echo_lib_under_dir "${INSTALL_SOURCE_DIR:+${INSTALL_SOURCE_DIR}/lib}" "$helper_name"; then
        return 0
    fi
    if _try_echo_existing_file "$script_dir/lib/${helper_name}"; then
        return 0
    fi
    if _try_echo_lib_under_dir "${LIB_DIR:-}" "$helper_name"; then
        return 0
    fi
    echo "Missing ${helper_label}: lib/${helper_name}" >&2
    return 1
}

_resolve_session_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-session.sh" "session helper"
}

_resolve_common_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-common.sh" "common helper"
}

_resolve_bootstrap_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-bootstrap.sh" "bootstrap helper"
}

_resolve_display_mutter_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-display-mutter.sh" "display mutter helper"
}

_resolve_display_state_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-display-state.sh" "display state helper"
}

_resolve_display_watchdog_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-display-watchdog.sh" "display watchdog helper"
}

_resolve_display_osd_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-display-osd.sh" "display osd helper"
}

_resolve_notif_icons_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-notif-icons.sh" "notification icon helper"
}

_resolve_i18n_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-i18n.sh" "i18n helper"
}

_resolve_screenpad_helper_path() {
    local script_dir="$1"
    _resolve_script_lib_path "$script_dir" "asus-screenpad.sh" "screenpad helper"
}

_source_asus_session_from_dir() {
    local dir="$1"
    [ -f "$dir/asus-session.sh" ] || return 1
    # shellcheck source=lib/asus-session.sh
    source "$dir/asus-session.sh"
}

_try_source_asus_session_from_optional_dir() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    _source_asus_session_from_dir "$dir"
}

_source_session_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_session_helper_path "$script_dir") || return 1
    # shellcheck source=lib/asus-session.sh
    source "$helper_path"
}

_cleanup_staged_lib_file() {
    local staging_path="$1"
    rm -f "$staging_path"
}

_stage_resolved_lib_copy() {
    local source_path="$1"
    local staging_path="$2"

    if ! cp "$source_path" "$staging_path"; then
        echo "  ✗ Failed to stage library copy from $source_path to $staging_path" >&2
        _cleanup_staged_lib_file "$staging_path"
        return 1
    fi
    if [ ! -e "$staging_path" ]; then
        echo "  ✗ Staged library copy missing after copy: $staging_path" >&2
        _cleanup_staged_lib_file "$staging_path"
        return 1
    fi
    return 0
}

_canonical_install_path() {
    local path="$1" canonical="$1"
    if command -v realpath >/dev/null 2>&1; then
        canonical=$(realpath -m -- "$path") || canonical="$path"
    elif command -v readlink >/dev/null 2>&1; then
        canonical=$(readlink -f -- "$path") || canonical="$path"
    fi
    printf '%s\n' "$canonical"
}

_install_lib_paths_match() {
    local source_path="$1" dest_path="$2"
    [ ! -L "$dest_path" ] &&
        [ "$(_canonical_install_path "$source_path")" = "$(_canonical_install_path "$dest_path")" ]
}

_install_staged_lib_file() {
    local staging_path="$1" dest_path="$2"
    if ! chmod 0644 "$staging_path"; then
        _cleanup_staged_lib_file "$staging_path"
        return 1
    fi
    if mv -f "$staging_path" "$dest_path"; then
        return 0
    fi
    _cleanup_staged_lib_file "$staging_path"
    return 1
}

_install_resolved_lib_file() {
    local source_path="$1"
    local dest_path="$2"
    local dest_dir staging_path

    dest_dir="$(dirname "$dest_path")"
    mkdir -p "$dest_dir" || return 1
    if _install_lib_paths_match "$source_path" "$dest_path"; then
        return 0
    fi
    staging_path=$(mktemp "${dest_dir}/.asus-lib.XXXXXX") || return 1
    _stage_resolved_lib_copy "$source_path" "$staging_path" || return 1
    _install_staged_lib_file "$staging_path" "$dest_path"
}

_install_session_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_session_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-session.sh"
}

_install_common_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_common_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-common.sh"
}

_install_bootstrap_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_bootstrap_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-bootstrap.sh"
}

_install_display_mutter_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_display_mutter_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-display-mutter.sh"
}

_install_display_state_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_display_state_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-display-state.sh"
}

_install_display_watchdog_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_display_watchdog_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-display-watchdog.sh"
}

_install_display_osd_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_display_osd_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-display-osd.sh"
}

_install_notif_icons_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_notif_icons_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-notif-icons.sh"
}

_install_i18n_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_i18n_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-i18n.sh"
}

_install_screenpad_helper() {
    local script_dir="$1"
    local helper_path
    helper_path=$(_resolve_screenpad_helper_path "$script_dir") || return 1
    _install_resolved_lib_file "$helper_path" "$LIB_DIR/asus-screenpad.sh"
}

_reject_empty_or_root_path() {
    local path="$1" msg="$2"
    if [ -z "$path" ] || [ "$path" = "/" ]; then
        echo "$msg" >&2
        return 1
    fi
    return 0
}

_is_safe_config_dir_under_state() {
    local canonical="$1" state_canonical="$2" config_dir="$3"
    # Require a path under STATE_DIR (reject equality to STATE_DIR itself).
    case "$canonical" in
        "$state_canonical"/*) return 0 ;;
        *)
            echo "Warning: refusing to remove config_dir outside state path: $config_dir" >&2
            return 1
            ;;
    esac
}

_is_safe_config_dir() {
    local config_dir="$1" canonical state_canonical
    if [ -z "${STATE_DIR:-}" ]; then
        echo "Warning: refusing to remove config_dir: STATE_DIR is empty" >&2
        return 1
    fi
    canonical=$(_canonical_install_path "$config_dir")
    state_canonical=$(_canonical_install_path "$STATE_DIR")
    _reject_empty_or_root_path "$canonical" \
        "Warning: refusing to remove invalid config_dir: '${config_dir}'" || return 1
    _reject_empty_or_root_path "$state_canonical" \
        "Warning: refusing to remove config_dir: STATE_DIR resolves invalid" || return 1
    _is_safe_config_dir_under_state "$canonical" "$state_canonical" "$config_dir"
}

_install_choice_includes_desktop() {
    local choice="$1"
    case " ${choice//GNOME/DESKTOP} " in
        *" DESKTOP "*) return 0 ;;
    esac
    return 1
}

_install_plan_progress_steps() {
    local choice="$1"
    local total=1
    INSTALL_STEP_CURRENT=0
    if [ "${SKIP_PKG_INSTALL:-0}" != "1" ]; then
        total=$((total + 1))
    fi
    if _install_choice_includes_desktop "$choice"; then
        total=$((total + 1))
    fi
    INSTALL_STEP_TOTAL=$total
    export INSTALL_STEP_CURRENT INSTALL_STEP_TOTAL
}

_install_print_next_step() {
    local label="$1"
    # kcov DE drivers call configure_* without install.sh planning these counters.
    INSTALL_STEP_CURRENT=$((${INSTALL_STEP_CURRENT:-0} + 1))
    printf '[%s/%s] %s\n' "$INSTALL_STEP_CURRENT" \
        "${INSTALL_STEP_TOTAL:-$INSTALL_STEP_CURRENT}" "$label"
}