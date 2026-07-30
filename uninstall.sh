#!/usr/bin/env bash
set -euo pipefail

# Variable overrides for testability
PREFIX="${DESTDIR:-}"
BIN_DIR="${PREFIX}/usr/local/bin"
LIB_DIR="${PREFIX}/usr/local/lib/asus-zenbook-linux-tools"
SYS_DIR="${PREFIX}/etc/systemd/system"
HOOK_DIR="${PREFIX}/lib/systemd/system-sleep"
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
BUS_ROOT="${BUS_ROOT:-${DBUS_BUS_ROOT:-${RUN_USER_ROOT:-/run/user}}}"
SYSTEMCTL="${SYSTEMCTL_CMD:-systemctl}"
SUDO_CMD="${SUDO_CMD:-sudo}"
# Staged DESTDIR runs default to skipping package removal unless explicitly set.
SKIP_PKG_REMOVE="${SKIP_PKG_REMOVE:-${DESTDIR:+1}}"
SKIP_PKG_REMOVE="${SKIP_PKG_REMOVE:-0}"
NO_SESSION_USER="__NO_SESSION_USER__"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SHARED_LIB="$SCRIPT_DIR/lib/install-shared.sh"
INSTALL_OS_DETECTION_LIB="$SCRIPT_DIR/lib/install-os-detection.sh"
INSTALL_COMPONENTS_LIB="$SCRIPT_DIR/lib/install-components.sh"
INSTALL_MANIFEST_LIB="$SCRIPT_DIR/lib/install-file-manifest.sh"

_require_uninstall_helper() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then
        echo "Missing $label: $path" >&2
        return 1
    fi
}

_source_core_uninstall_helpers() {
    _require_uninstall_helper "$INSTALL_SHARED_LIB" "installer shared helper" || return 1
    _require_uninstall_helper "$INSTALL_OS_DETECTION_LIB" "installer OS helper" || return 1
    _require_uninstall_helper "$INSTALL_COMPONENTS_LIB" "installer component helper" || return 1
    _require_uninstall_helper "$INSTALL_MANIFEST_LIB" "installer file manifest" || return 1
    # shellcheck source=lib/install-shared.sh
    source "$INSTALL_SHARED_LIB"
    # shellcheck source=lib/install-os-detection.sh
    source "$INSTALL_OS_DETECTION_LIB"
    # shellcheck source=lib/install-components.sh
    source "$INSTALL_COMPONENTS_LIB"
    # shellcheck source=lib/install-file-manifest.sh
    source "$INSTALL_MANIFEST_LIB"
}

_source_uninstall_i18n_helper() {
    local i18n_lib
    i18n_lib="$SCRIPT_DIR/lib/asus-i18n.sh"
    _require_uninstall_helper "$i18n_lib" "i18n helper" || return 1
    # shellcheck source=lib/asus-i18n.sh
    source "$i18n_lib"
}

# Desktop restore tables (LXQt/Cinnamon/MATE) call _asus_gettext for labels.
_source_required_uninstall_helpers() {
    _source_core_uninstall_helpers || return 1
    _source_uninstall_i18n_helper || return 1
}

_source_required_uninstall_helpers || exit 1
# GNOME restore helpers (sourced once; restore_gnome_shortcuts still checks the file exists).
INSTALL_GNOME_LIB="$SCRIPT_DIR/lib/install-gnome.sh"
_source_optional_gnome_helper() {
    if [ -f "$INSTALL_GNOME_LIB" ]; then
    # shellcheck source=lib/install-gnome.sh
        source "$INSTALL_GNOME_LIB"
    fi
}
_source_optional_gnome_helper
INSTALL_DESKTOP_RESTORE_LIB="$SCRIPT_DIR/lib/uninstall-desktop-restore.sh"
_source_desktop_restore_helper() {
    _require_uninstall_helper "$INSTALL_DESKTOP_RESTORE_LIB" \
        "uninstall desktop restore helper" || return 1
    # shellcheck source=lib/uninstall-desktop-restore.sh
    source "$INSTALL_DESKTOP_RESTORE_LIB"
}
_source_desktop_restore_helper || exit 1

_is_absent_unit_error() {
    local message="$1"
    printf '%s\n' "$message" | grep -Eqi 'not loaded|not-found|not found|does not exist|No such file|could not be found|Unit .* not found'
}

_UNINSTALL_SYSTEMCTL_TEMPS=()

_cleanup_uninstall_systemctl_temps() {
    local path
    for path in "${_UNINSTALL_SYSTEMCTL_TEMPS[@]+"${_UNINSTALL_SYSTEMCTL_TEMPS[@]}"}"; do
        rm -f "$path"
    done
    _UNINSTALL_SYSTEMCTL_TEMPS=()
}

_remove_uninstall_systemctl_temp() {
    # Drop the exact tracked path (not basename/loose match) so nested captures stay accurate.
    local target="$1"
    local -a kept=()
    local path
    for path in "${_UNINSTALL_SYSTEMCTL_TEMPS[@]+"${_UNINSTALL_SYSTEMCTL_TEMPS[@]}"}"; do
        [ "$path" = "$target" ] && continue
        kept+=("$path")
    done
    _UNINSTALL_SYSTEMCTL_TEMPS=("${kept[@]+"${kept[@]}"}")
}

_register_uninstall_cleanup() {
    # Register only when executed as main. Empty BASH_SOURCE[0] also counts as main.
    if [ "${ASUS_UNINSTALL_SOURCE_ONLY:-0}" != "1" ] \
        && { [ "${BASH_SOURCE[0]-}" = "$0" ] || [ -z "${BASH_SOURCE[0]-}" ]; }; then
        trap '_cleanup_uninstall_systemctl_temps' EXIT
    fi
}

_register_uninstall_cleanup

_run_systemctl_capture() {
    # Run systemctl with timeout; write stderr to *err_var* nameref; return status.
    # Track each err_file in _UNINSTALL_SYSTEMCTL_TEMPS so nested captures stay nest-safe.
    local -n _err_out="$1"
    shift
    local err_file status=0
    err_file=$(mktemp "${TMPDIR:-/tmp}/asus-uninstall-systemctl.XXXXXX")
    _UNINSTALL_SYSTEMCTL_TEMPS+=("$err_file")
    # Capture status via || — $? after a failed `if cmd; fi` is always 0.
    _run_command_with_timeout "${INSTALL_COMMAND_TIMEOUT:-5}" env LC_ALL=C "$@" 2>"$err_file" || status=$?
    if [ "$status" -eq 0 ]; then
        _err_out=""
    else
        _err_out=$(cat "$err_file" 2>/dev/null || true)
    fi
    rm -f "$err_file"
    _remove_uninstall_systemctl_temp "$err_file"
    return "$status"
}

_run_systemctl_unit_action() {
    local action="$1" unit="$2"
    local err_text=""
    if _run_systemctl_capture err_text "$SYSTEMCTL" "$action" "$unit"; then
        return 0
    fi
    if _is_absent_unit_error "$err_text"; then
        return 0
    fi
    [ -z "$err_text" ] && err_text="(no stderr output)"
    echo "Warning: systemctl $action failed for $unit: $err_text" >&2
    return 1
}

_verify_service_inactive() {
    local unit="$1"
    local err_text="" status=0
    _run_systemctl_capture err_text "$SYSTEMCTL" is-active --quiet "$unit" || status=$?
    _report_service_inactive_status "$unit" "$status" "$err_text"
}

_is_inactive_is_active_status() {
    # systemctl is-active --quiet: historically 3=inactive; systemd 259+ often
    # returns 4 for inactive/not-loaded (LSB-ish).
    local status="$1" err_text="$2"
    [ "$status" -eq 3 ] || [ "$status" -eq 4 ] || _is_absent_unit_error "$err_text"
}

_report_service_inactive_status() {
    local unit="$1" status="$2" err_text="$3"
    if [ "$status" -eq 0 ]; then
        echo "Warning: service remained active after stop: $unit" >&2
        return 1
    fi
    case "$status" in
        124|137)
        echo "Warning: unable to verify service state for $unit: timed out (exit $status)" >&2
        return 1
        ;;
    esac
    if _is_inactive_is_active_status "$status" "$err_text"; then
        return 0
    fi
    [ -z "$err_text" ] && err_text="(no stderr output)"
    echo "Warning: unable to verify service state for $unit: $err_text" >&2
    return 1
}

_run_systemctl_daemon_reload() {
    local err_text=""
    if _run_systemctl_capture err_text "$SYSTEMCTL" daemon-reload; then
        return 0
    fi
    [ -z "$err_text" ] && err_text="(no stderr output)"
    echo "Warning: systemctl daemon-reload failed: $err_text" >&2
    return 1
}

_stop_units() {
    local status=0 unit
    for unit in "$@"; do
        _run_systemctl_unit_action stop "$unit" || status=1
    done
    return "$status"
}

_verify_units_inactive() {
    local status=0 unit
    for unit in "$@"; do
        _verify_service_inactive "$unit" || status=1
    done
    return "$status"
}

_disable_units() {
    local status=0 unit
    for unit in "$@"; do
        _run_systemctl_unit_action disable "$unit" || status=1
    done
    return "$status"
}

_require_systemctl() {
    if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "$SYSTEMCTL" ] && [ -x "$SYSTEMCTL" ]; then
        return 0
    fi
    echo "Error: systemctl command not available: $SYSTEMCTL" >&2
    return 1
}

_print_residual_entries() {
    local entry count=0
    for entry in "$LIB_DIR"/* "$LIB_DIR"/.[!.]* "$LIB_DIR"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        printf '  %s\n' "${entry##*/}" >&2
        count=$((count + 1))
        if [ "$count" -ge 20 ]; then
            echo "  ... truncated (showing first 20 residual entries)" >&2
            break
        fi
    done
    return 0
}

stop_and_disable_services() {
    local status=0
    local units=(
        asus-hotkey-daemon.service
        asus-touchpad-share.service
        asus-sound-fix.service
    )

    echo "Stopping and disabling systemd services..."
    _require_systemctl || return 1

    _stop_units "${units[@]}" || status=1
    _verify_units_inactive "${units[@]}" || status=1
    _disable_units "${units[@]}" || status=1

    return "$status"
}

_remove_manifest_installed_files() {
    local failed=0
    _asus_remove_manifest_bin_files failed
    _asus_remove_manifest_lib_files failed
    _asus_remove_legacy_lib_install_helpers failed
    _asus_remove_manifest_sys_files failed
    rm -f "$HOOK_DIR/asus-sound-fix" || failed=1
    rm -f "${PREFIX:-}/etc/udev/rules.d/99-asus-uinput.rules" || failed=1
    return "$failed"
}

_reload_udev_after_remove() {
    if [ -z "${PREFIX:-}" ] && command -v udevadm >/dev/null 2>&1; then
        _asus_soft udevadm control --reload-rules 2>/dev/null
        _asus_soft udevadm trigger --subsystem-match=misc --name-match=uinput 2>/dev/null
    fi
}

_remove_shared_install_files() {
    local failed=0
    _asus_remove_manifest_share_files failed
    _asus_soft rmdir "${PREFIX:-}/usr/local/share/asus-zenbook-linux-tools/icons" 2>/dev/null
    _asus_soft rmdir "${PREFIX:-}/usr/local/share/asus-zenbook-linux-tools" 2>/dev/null
    _asus_soft gtk-update-icon-cache -f -t "${PREFIX:-}/usr/local/share/icons/hicolor"
    return "$failed"
}

_remove_empty_install_dirs() {
    if [ -d "$LIB_DIR" ]; then
        if ! rmdir "$LIB_DIR" 2>/dev/null; then
            echo "Warning: $LIB_DIR is not empty; leaving residual entries in place." >&2
            _print_residual_entries
        fi
    fi
    if [ -d "$STATE_DIR" ]; then
        _asus_soft rmdir "$STATE_DIR" 2>/dev/null
    fi
}

remove_installed_files() {
    local failed=0
    echo "Removing installed binaries and systemd units..."
    _remove_manifest_installed_files || failed=1
    _reload_udev_after_remove
    _remove_shared_install_files || failed=1
    _remove_empty_install_dirs
    if ! _run_systemctl_daemon_reload; then
        echo "Warning: daemon-reload after file removal failed; continuing." >&2
        failed=1
    fi
    return "$failed"
}

resolve_fallback_user() {
    local real_user="${SUDO_USER:-${USER-}}"
    if [ "$real_user" = "root" ] || [ -z "$real_user" ]; then
        real_user=$(who 2>/dev/null | awk 'NR==1{print $1}' || true)
        [ -z "$real_user" ] && real_user="$NO_SESSION_USER"
    fi
    echo "$real_user"
}

_restore_schema_file() {
    local user="$1" bus="$2" file_path="$3" schema="$4" key="$5"
    local bus_addr="unix:path=$bus" runtime_dir
    runtime_dir=$(dirname "$bus")
    if [ -f "$file_path" ]; then
        local val
        val=$(cat "$file_path" 2>/dev/null)
        if [ -n "$val" ]; then
            _install_run_as_user "$user" env DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                XDG_RUNTIME_DIR="$runtime_dir" \
                gsettings set "$schema" "$key" "$val"
            return $?
        fi
    fi
    _install_run_as_user "$user" env DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        gsettings reset "$schema" "$key"
    return $?
}

restore_gnome_keybinding_schema() {
    local user="$1" bus="$2" config_dir="$3" file_name="$4" schema="$5" key="$6"
    _restore_schema_file "$user" "$bus" "$config_dir/$file_name" "$schema" "$key"
}

_reset_gnome_custom_bindings() {
    local user="$1" bus="$2"
    local bus_addr="unix:path=$bus" runtime_dir
    runtime_dir=$(dirname "$bus")
    _install_run_as_user "$user" env DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        XDG_RUNTIME_DIR="$runtime_dir" gsettings reset \
        org.gnome.settings-daemon.plugins.media-keys custom-keybindings
}

_restore_named_keybinding() {
    local user="$1" bus="$2" dir="$3" file_name="$4" schema="$5" key="$6"
    restore_gnome_keybinding_schema "$user" "$bus" "$dir" "$file_name" "$schema" "$key"
}

_restore_optional_named_keybinding() {
    local user="$1" bus="$2" dir="$3" file_name="$4" schema="$5" key="$6"
    [ -f "$dir/$file_name" ] || return 0
    restore_gnome_keybinding_schema "$user" "$bus" "$dir" "$file_name" "$schema" "$key"
}

_restore_primary_keybindings() {
    local user="$1" bus="$2" dir="$3"
    local status=0

    _restore_named_keybinding "$user" "$bus" "$dir" "orig_show_screenshot_ui" \
        "org.gnome.shell.keybindings" "show-screenshot-ui" || status=1
    _restore_named_keybinding "$user" "$bus" "$dir" "orig_control_center" \
        "org.gnome.settings-daemon.plugins.media-keys" "control-center" || status=1
    _restore_optional_named_keybinding "$user" "$bus" "$dir" "orig_switch_video_mode" \
        "org.gnome.settings-daemon.plugins.media-keys" "switch-video-mode" || status=1
    _restore_optional_named_keybinding "$user" "$bus" "$dir" "orig_switch_monitor" \
        "org.gnome.mutter.keybindings" "switch-monitor" || status=1

    return "$status"
}

_restore_custom_keybindings() {
    local user="$1" bus="$2" dir="$3"
    if [ -f "$dir/orig_custom_keybindings" ]; then
        _restore_named_keybinding "$user" "$bus" "$dir" "orig_custom_keybindings" "org.gnome.settings-daemon.plugins.media-keys" "custom-keybindings"
        return $?
    fi

    echo "Warning: orig_custom_keybindings backup missing; resetting custom-keybindings to schema default." >&2
    _reset_gnome_custom_bindings "$user" "$bus"
}

_restore_keybinding_set() {
    local user="$1" bus="$2" dir="$3"
    local status=0

    _restore_primary_keybindings "$user" "$bus" "$dir" || status=1
    _restore_custom_keybindings "$user" "$bus" "$dir" || status=1

    return "$status"
}

_restore_user_keybindings() {
    local user="$1" bus="$2" dir="$3"
    echo "Restoring original GNOME keybindings for $user..."
    _restore_keybinding_set "$user" "$bus" "$dir"
}

_check_valid_restore_env() {
    local uid="$1" dir="$2" bus="$3"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 1
    fi
    if [ -z "$uid" ]; then
        echo "Warning: Skipping GNOME keybinding restore (missing user id)." >&2
        return 1
    fi
    if [ ! -S "$bus" ]; then
        echo "Warning: Skipping GNOME keybinding restore (missing D-Bus socket $bus)." >&2
        return 1
    fi
    return 0
}

_UNINSTALL_TARGET_USER=""
_UNINSTALL_TARGET_UID=""

_resolve_target_user_info() {
    local target_user user_id
    target_user=$(find_active_session_user || true)
    [ -z "$target_user" ] && target_user=$(resolve_fallback_user)
    if [ "$target_user" = "$NO_SESSION_USER" ]; then
        user_id=""
    else
        user_id=$(id -u "$target_user" 2>/dev/null || true)
    fi
    _UNINSTALL_TARGET_USER="$target_user"
    _UNINSTALL_TARGET_UID="$user_id"
}

_resolve_persisted_target_user() {
    local config_dir="$1" fallback_user="$2" persisted
    if [ ! -f "$config_dir/target_user" ]; then
        printf '%s\n' "$fallback_user"
        return 0
    fi
    IFS= read -r persisted <"$config_dir/target_user" || persisted=""
    if [ -n "$persisted" ] && getent passwd "$persisted" >/dev/null 2>&1; then
        printf '%s\n' "$persisted"
        return 0
    fi
    printf '%s\n' "$fallback_user"
}

_gnome_backup_state_present() {
    local config_dir="$1"
    [ -d "$config_dir" ] || return 1
    [ -n "$(ls -A "$config_dir" 2>/dev/null || true)" ]
}

restore_gnome_shortcuts() {
    local target_user="$1" user_id="$2" config_dir bus_path gnome_lib
    if [ -z "$user_id" ]; then
        echo "Warning: Skipping GNOME keybinding restore (missing user id)." >&2
        return 0
    fi
    config_dir="$STATE_DIR/$user_id"
    bus_path="$BUS_ROOT/$user_id/bus"
    if ! _check_valid_restore_env "$user_id" "$config_dir" "$bus_path"; then
        _invalid_gnome_restore_status "$config_dir"
        return $?
    fi
    gnome_lib="${INSTALL_GNOME_LIB:-$SCRIPT_DIR/lib/install-gnome.sh}"
    if [ ! -f "$gnome_lib" ]; then
        echo "Missing installer GNOME helper: $gnome_lib" >&2
        return 1
    fi
    _asus_soft remove_gnome_window_swap_extension "$target_user" "$bus_path"
    _restore_and_remove_gnome_backup "$target_user" "$bus_path" "$config_dir"
}

_invalid_gnome_restore_status() {
    local config_dir="$1"
    if _gnome_backup_state_present "$config_dir"; then
        return 1
    fi
    return 0
}

_restore_and_remove_gnome_backup() {
    local target_user="$1" bus_path="$2" config_dir="$3"
    if ! _restore_user_keybindings "$target_user" "$bus_path" "$config_dir"; then
    echo "Warning: failed to fully restore GNOME keybindings; preserving backup directory for recovery." >&2
    return 1
    fi
    _is_safe_config_dir "$config_dir" || return 1
    rm -rf "$config_dir"
}

_read_desktop_family() {
    local config_dir="$1"
    [ -f "$config_dir/desktop_family" ] || return 0
    cat "$config_dir/desktop_family" 2>/dev/null
}

restore_desktop_shortcuts() {
    local target_user user_id config_dir family
    _resolve_target_user_info
    target_user="$_UNINSTALL_TARGET_USER"
    user_id="$_UNINSTALL_TARGET_UID"

    if [ -z "$user_id" ]; then
        echo "Warning: Skipping desktop keybinding restore (missing user id)." >&2
        return 0
    fi

    config_dir="$STATE_DIR/$user_id"
    family=$(_read_desktop_family "$config_dir")
    target_user=$(_resolve_persisted_target_user "$config_dir" "$target_user")
    _restore_by_desktop_family "$family" "$target_user" "$user_id" "$config_dir"
}

_remove_uinput_group() {
    if [ -z "${PREFIX:-}" ]; then
        _asus_soft groupdel asus-uinput
    fi
}

_run_pre_file_uninstall_steps() {
    local failed=0
    stop_and_disable_services || failed=1
    restore_desktop_shortcuts || failed=1
    revoke_input_group_members || failed=1
    _remove_uinput_group
    remove_system_deps || failed=1
    return "$failed"
}

_run_uninstall_steps() {
    local failed=0
    _run_pre_file_uninstall_steps || failed=1
    remove_installed_files || failed=1
    return "$failed"
}

main() {
    _source_session_helper "$SCRIPT_DIR" || exit 1

    check_root
    if ! _run_uninstall_steps; then
        echo "ASUS ZenBook Linux Tools uninstall completed with errors." >&2
        exit 1
    fi
    echo "ASUS ZenBook Linux Tools cleanly uninstalled."
}

_maybe_run_uninstall_main() {
    if [ "${ASUS_UNINSTALL_SOURCE_ONLY:-0}" = "1" ]; then
        return 0
    fi
    if [ "${BASH_SOURCE[0]-}" = "$0" ] || [ -z "${BASH_SOURCE[0]-}" ]; then
        main "$@"
    fi
}

_maybe_run_uninstall_main "$@"
