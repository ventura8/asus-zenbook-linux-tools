#!/usr/bin/env bash
# kcov driver: exercise lib/install-shared.sh helpers as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

# shellcheck source=lib/install-shared.sh
source "$REPO_ROOT/lib/install-shared.sh" >/dev/null 2>&1
# shellcheck source=lib/asus-i18n.sh
source "$REPO_ROOT/lib/asus-i18n.sh" >/dev/null 2>&1

# shellcheck source=scripts/coverage/gates.sh
source "$REPO_ROOT/scripts/coverage/gates.sh"

_SHARED_HELPERS_LOG_DIR="$(resolve_reports_root)/distro-logs"
mkdir -p "$_SHARED_HELPERS_LOG_DIR"

_run_version_helpers() {
    local empty_ver
    _exercise print_setup_banner 1 >/dev/null
    _exercise _format_display_version >/dev/null
    _exercise _read_project_version >/dev/null
    _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" _read_project_version >/dev/null
    _exercise SCRIPT_DIR="/nonexistent" _resolve_version_file >/dev/null
    _exercise INSTALL_SOURCE_DIR="/nonexistent" SCRIPT_DIR="/also-missing" _resolve_version_file >/dev/null
    empty_ver=$(mktemp -d)
    trap 'rm -rf "$empty_ver"' RETURN
    printf '' > "$empty_ver/VERSION"
    _exercise INSTALL_SOURCE_DIR="$empty_ver" _read_project_version >/dev/null
    printf 'v9.9.9\n' > "$empty_ver/VERSION"
    _exercise INSTALL_SOURCE_DIR="$empty_ver" _format_display_version >/dev/null
    trap - RETURN
    rm -rf "$empty_ver"
}

_run_root_and_timeout_helpers() {
    _exercise check_root
    _expect_bash_snippet_failure \
        "export ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=0 EFFECTIVE_UID_OVERRIDE=1000; source '$REPO_ROOT/lib/install-shared.sh'; check_root" \
        "$_SHARED_HELPERS_LOG_DIR/shared_helpers_root.log" \
        "expected check_root to fail for non-root override" || return 1
    _exercise _run_command_with_timeout 1 true >/dev/null
    _exercise INSTALL_SKIP_TIMEOUT_WRAPPER=1 _run_command_with_timeout 1 true >/dev/null
    _exercise _run_command_with_timeout bad true >/dev/null
    _exercise _run_command_with_timeout 0 true >/dev/null
    _exercise _run_command_with_timeout 9 true >/dev/null
    _exercise INSTALL_SKIP_TIMEOUT_WRAPPER=0 _run_command_with_timeout 1 true >/dev/null
    _exercise INSTALL_SKIP_TIMEOUT_WRAPPER=0 PATH="/nonexistent" _run_command_with_timeout 1 true >/dev/null
    _exercise INSTALL_COMMAND_TIMEOUT_MAX=bad _run_command_with_timeout 1 true >/dev/null
    _exercise INSTALL_COMMAND_TIMEOUT_MAX=0 _run_command_with_timeout 1 true >/dev/null
    _exercise INSTALL_COMMAND_TIMEOUT_MAX=5 _run_command_with_timeout 9 true >/dev/null
    _exercise _install_run_as_user "$(id -un)" true >/dev/null
}

_run_lib_resolve_helpers() {
    local stage=""
    _exercise _resolve_script_lib_path "$REPO_ROOT" "asus-session.sh" "session helper" >/dev/null
    _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" _resolve_script_lib_path "/nope" "asus-session.sh" "session helper" >/dev/null
    _exercise LIB_DIR="" _resolve_script_lib_path "/nope" "missing.sh" "missing helper" >/dev/null
    _exercise LIB_DIR="$REPO_ROOT/lib" _resolve_script_lib_path "/nope" "asus-session.sh" "session helper" >/dev/null
    _exercise _resolve_session_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_common_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_bootstrap_helper_path "$REPO_ROOT" >/dev/null
    _exercise _source_asus_session_from_dir "$REPO_ROOT/lib" >/dev/null
    _exercise _source_session_helper "$REPO_ROOT" >/dev/null
    _expect_bash_snippet_failure \
        "source '$REPO_ROOT/lib/install-shared.sh'; _source_session_helper '/nope'" \
        "$_SHARED_HELPERS_LOG_DIR/shared_helpers_session1.log" \
        "expected _source_session_helper '/nope' to fail" || return 1
    _expect_bash_snippet_failure \
        "source '$REPO_ROOT/lib/install-shared.sh'; unset LIB_DIR; _source_session_helper '/nope'" \
        "$_SHARED_HELPERS_LOG_DIR/shared_helpers_session2.log" \
        "expected _source_session_helper '/nope' (missing LIB_DIR) to fail" || return 1
    stage=$(mktemp)
    trap 'rm -f "$stage"' RETURN
    _exercise _stage_resolved_lib_copy "$REPO_ROOT/lib/asus-session.sh" "$stage" >/dev/null
    _cleanup_staged_lib_file "$stage"
    _exercise _stage_resolved_lib_copy "/missing" "$stage" >/dev/null
    _cleanup_staged_lib_file "$stage"
    trap - RETURN
    rm -f "$stage"
}

_run_privilege_and_path_exercises() {
    _exercise _install_run_as_other_user 1 "nosuch-user-$$" true >/dev/null
    _exercise PATH="/nonexistent" _install_run_as_other_user 1 "$(id -un)" true >/dev/null
    # Neither runuser nor sudo on PATH → privilege-drop error.
    _exercise PATH="/nonexistent" SUDO_CMD="/nonexistent/sudo" \
        _install_run_as_other_user 1 root true >/dev/null
    if getent passwd root >/dev/null 2>&1 && [ "$(id -un)" != "root" ]; then
        _exercise _install_run_as_user root true >/dev/null
    fi
    _exercise _canonical_install_path "$REPO_ROOT/lib" >/dev/null
    _exercise _canonical_install_path "/nope/$$" >/dev/null
    _exercise _install_resolve_session_bus_root >/dev/null
    _exercise BUS_ROOT="/tmp/bus-$$" _install_resolve_session_bus_root >/dev/null
    _exercise BUS_ROOT="" DBUS_BUS_ROOT="/tmp/dbus-$$" _install_resolve_session_bus_root >/dev/null
    _exercise BUS_ROOT="" DBUS_BUS_ROOT="" RUN_USER_ROOT="/tmp/run-$$" \
        _install_resolve_session_bus_root >/dev/null
    _exercise BUS_ROOT="" DBUS_BUS_ROOT="" RUN_USER_ROOT="" \
        _install_resolve_session_bus_root >/dev/null
    _exercise _source_asus_session_from_dir "" >/dev/null
    _exercise ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=bad EFFECTIVE_UID_OVERRIDE=bad check_root >/dev/null
    _exercise INSTALL_SOURCE_DIR="/nope" SCRIPT_DIR="/nope" _format_display_version >/dev/null
}

_run_helper_install_exercises() {
    local dest state
    dest=$(mktemp -d)
    state=$(mktemp -d)
    trap 'rm -rf "$dest" "$state"' RETURN
    mkdir -p "$dest/lib" "$state/uid"
    LIB_DIR="$dest/lib"
    STATE_DIR="$state"
    export LIB_DIR STATE_DIR
    _exercise _resolve_display_mutter_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_display_state_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_display_watchdog_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_display_osd_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_notif_icons_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_i18n_helper_path "$REPO_ROOT" >/dev/null
    _exercise _resolve_screenpad_helper_path "$REPO_ROOT" >/dev/null
    _exercise _install_session_helper "$REPO_ROOT" >/dev/null
    _exercise _install_common_helper "$REPO_ROOT" >/dev/null
    _exercise _install_bootstrap_helper "$REPO_ROOT" >/dev/null
    _exercise _install_display_mutter_helper "$REPO_ROOT" >/dev/null
    _exercise _install_display_state_helper "$REPO_ROOT" >/dev/null
    _exercise _install_display_watchdog_helper "$REPO_ROOT" >/dev/null
    _exercise _install_display_osd_helper "$REPO_ROOT" >/dev/null
    _exercise _install_notif_icons_helper "$REPO_ROOT" >/dev/null
    _exercise _install_i18n_helper "$REPO_ROOT" >/dev/null
    _exercise _install_screenpad_helper "$REPO_ROOT" >/dev/null
    _exercise _try_echo_existing_file "$REPO_ROOT/lib/asus-session.sh" >/dev/null
    _exercise _try_echo_lib_under_dir "$REPO_ROOT/lib" "asus-session.sh" >/dev/null
    _exercise _try_source_asus_session_from_optional_dir "$REPO_ROOT/lib" >/dev/null
    _exercise _reject_empty_or_root_path "" >/dev/null
    _exercise _reject_empty_or_root_path / >/dev/null
    _exercise _is_safe_config_dir_under_state "$state" "$state/uid" >/dev/null
    _exercise _is_safe_config_dir "" >/dev/null
    _exercise STATE_DIR="$state" _is_safe_config_dir "$state/uid" >/dev/null
    _exercise _install_lib_paths_match "$REPO_ROOT/lib/asus-session.sh" \
        "$dest/lib/asus-session.sh" >/dev/null
    _exercise _install_resolved_lib_file "$REPO_ROOT" "asus-session.sh" \
        "session helper" >/dev/null
    _exercise _asus_soft true >/dev/null
    _exercise _install_command_timeout_max >/dev/null
    _exercise _clamp_install_command_timeout 999 >/dev/null
    _exercise _require_effective_root >/dev/null
    trap - RETURN
    rm -rf "$dest" "$state"
}

_run_version_helpers
_run_root_and_timeout_helpers
_run_lib_resolve_helpers
_run_privilege_and_path_exercises
_run_helper_install_exercises
