#!/usr/bin/env bash
# kcov driver: exercise uninstall.sh helpers as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

# shellcheck source=scripts/coverage/gates.sh
source "$REPO_ROOT/scripts/coverage/gates.sh"

_UNINSTALL_SOURCE_LOG="$(resolve_reports_root)/distro-logs/uninstall_helpers_source.log"
_UNINSTALL_MISSING_LIBS=""
_UNINSTALL_TEE_DIR=""
_UNINSTALL_TEE_PID=""
mkdir -p "$(dirname "$_UNINSTALL_SOURCE_LOG")"

_driver_set_prefix _UN_PREFIX_OWNED
export DESTDIR="${DESTDIR:-$PREFIX}"
BIN_DIR="${PREFIX}/usr/local/bin"
LIB_DIR="${PREFIX}/usr/local/lib/asus-zenbook-linux-tools"
SYS_DIR="${PREFIX}/etc/systemd/system"
HOOK_DIR="${PREFIX}/lib/systemd/system-sleep"
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
SYSTEMCTL="${SYSTEMCTL_CMD:-systemctl}"
SKIP_PKG_REMOVE="${SKIP_PKG_REMOVE:-1}"
INSTALL_COMMAND_TIMEOUT=1
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export PREFIX BIN_DIR LIB_DIR SYS_DIR HOOK_DIR STATE_DIR BUS_ROOT SYSTEMCTL \
    SKIP_PKG_REMOVE INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER

_uninstall_stop_tee() {
    if [ -n "${_UNINSTALL_TEE_PID:-}" ]; then
        _soft kill "$_UNINSTALL_TEE_PID" 2>/dev/null
        _soft wait "$_UNINSTALL_TEE_PID" 2>/dev/null
        _UNINSTALL_TEE_PID=""
    fi
}

_uninstall_remove_if_set() {
    [ -n "${1:-}" ] || return 0
    rm -rf "$1"
}

_uninstall_driver_cleanup() {
    _uninstall_stop_tee
    _uninstall_remove_if_set "${mock_bin:-}"
    _uninstall_remove_if_set "${_UNINSTALL_TEE_DIR:-}"
    _uninstall_remove_if_set "${_UNINSTALL_MISSING_LIBS:-}"
    if [ "${_UN_PREFIX_OWNED:-0}" = 1 ]; then
        rm -rf "$PREFIX"
    fi
}
trap '_uninstall_driver_cleanup' EXIT

uid="$(id -u)"
uname_cur="$(id -un)"
mock_bin=""

_setup_uninstall_env() {
    mkdir -p "$BIN_DIR" "$LIB_DIR" "$SYS_DIR" "$HOOK_DIR" "$STATE_DIR/$uid" "$BUS_ROOT/$uid"
    mock_bin=$(mktemp -d)
    _write_sudo_stub "$mock_bin"
    cat > "$mock_bin/gsettings" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$mock_bin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$mock_bin"/*
    PATH="$mock_bin:$PATH"
    SUDO_CMD="$mock_bin/sudo"
    export SUDO_CMD
    SYSTEMCTL="$mock_bin/systemctl"
}

_source_uninstall_helpers() {
    local source_status=0
    _setup_uninstall_env
    export ASUS_UNINSTALL_SOURCE_ONLY=1
    _UNINSTALL_TEE_DIR=$(mktemp -d)
    _UNINSTALL_TEE_FIFO="$_UNINSTALL_TEE_DIR/tee.fifo"
    mkfifo "$_UNINSTALL_TEE_FIFO"
    tee -a "$_UNINSTALL_SOURCE_LOG" < "$_UNINSTALL_TEE_FIFO" &
    _UNINSTALL_TEE_PID=$!
    # shellcheck source=uninstall.sh
    source "$REPO_ROOT/uninstall.sh" >"$_UNINSTALL_TEE_FIFO" 2>&1 || source_status=$?
    if [ "$source_status" -ne 0 ]; then
        echo "uninstall_helpers: sourcing uninstall.sh failed with status $source_status" >&2
        return 1
    fi
    if ! wait "$_UNINSTALL_TEE_PID"; then
        echo "uninstall_helpers: tee process exited nonzero while sourcing uninstall.sh" >&2
        return 1
    fi
    _UNINSTALL_TEE_PID=""
    # SOURCE_ONLY skips uninstall EXIT registration; re-arm so systemctl temps and
    # driver cleanup both run.
    trap '_cleanup_uninstall_systemctl_temps; _uninstall_driver_cleanup' EXIT
    # shellcheck source=lib/asus-session.sh
    source "$REPO_ROOT/lib/asus-session.sh" >/dev/null 2>&1
}

# Stubs + source-only before loading uninstall helpers (do not run main).
_source_uninstall_helpers

_run_uninstall_unit_helpers() {
    _exercise _is_absent_unit_error "Unit foo.service not found" >/dev/null
    _exercise _is_absent_unit_error "totally different failure" >/dev/null
    _exercise _run_systemctl_unit_action stop asus-hotkey-daemon.service >/dev/null
    _exercise _verify_service_inactive asus-hotkey-daemon.service >/dev/null
    _exercise _run_systemctl_daemon_reload >/dev/null
    _exercise _stop_units asus-hotkey-daemon.service >/dev/null
    _exercise _verify_units_inactive asus-hotkey-daemon.service >/dev/null
    _exercise _disable_units asus-hotkey-daemon.service >/dev/null
    _exercise stop_and_disable_services >/dev/null
    _exercise remove_installed_files >/dev/null
}

_run_uninstall_residual_listing() {
    local _i failed=0
    mkdir -p "$LIB_DIR"
    for _i in $(seq 1 22); do
        : >"$LIB_DIR/residual-$_i.txt"
    done
    : >"$LIB_DIR/install-legacy-kcov.sh"
    _exercise _print_residual_entries >/dev/null
    _exercise _asus_remove_legacy_lib_install_helpers failed
    : "$failed"
}

_run_uninstall_manifest_list_exercises() {
    _exercise _asus_manifest_bin_basenames >/dev/null
    _exercise _asus_manifest_wmi_src_relpaths >/dev/null
    _exercise _asus_manifest_wmi_chmod_relpaths >/dev/null
    _exercise _asus_manifest_lib_basenames >/dev/null
    _exercise _asus_manifest_sys_unit_basenames >/dev/null
    _exercise _asus_manifest_desktop_basenames >/dev/null
    _exercise _asus_manifest_icon_basenames >/dev/null
    _exercise _asus_manifest_share_root >/dev/null
    _exercise PREFIX= _asus_manifest_share_root >/dev/null
}

_run_uninstall_manifest_seed_dirs() {
    mkdir -p "$BIN_DIR" "$LIB_DIR" "$SYS_DIR" \
        "$PREFIX/usr/local/share/applications" \
        "$PREFIX/usr/local/share/icons/hicolor/scalable/apps" \
        "$PREFIX/usr/local/share/icons/hicolor/48x48/apps" \
        "$PREFIX/usr/local/share/asus-zenbook-linux-tools/icons" \
        "$PREFIX/usr/local/share/locale/en/LC_MESSAGES"
}

_run_uninstall_manifest_seed_bin_lib_sys() {
    local name
    while IFS= read -r name; do
        : >"$BIN_DIR/$name"
    done < <(_asus_manifest_bin_basenames)
    while IFS= read -r name; do
        : >"$LIB_DIR/$name"
    done < <(_asus_manifest_lib_basenames)
    while IFS= read -r name; do
        : >"$SYS_DIR/$name"
    done < <(_asus_manifest_sys_unit_basenames)
}

_run_uninstall_manifest_seed_share() {
    local name
    while IFS= read -r name; do
        : >"$PREFIX/usr/local/share/applications/$name"
    done < <(_asus_manifest_desktop_basenames)
    while IFS= read -r name; do
        _uninstall_seed_one_icon "$name"
    done < <(_asus_manifest_icon_basenames)
    : >"$PREFIX/usr/local/share/locale/en/LC_MESSAGES/asus-zenbook-linux-tools.mo"
}

_uninstall_seed_one_icon() {
    local name="$1"
    case "$name" in
        *.png) : >"$PREFIX/usr/local/share/icons/hicolor/48x48/apps/$name" ;;
        *) : >"$PREFIX/usr/local/share/icons/hicolor/scalable/apps/$name" ;;
    esac
    : >"$PREFIX/usr/local/share/asus-zenbook-linux-tools/icons/$name"
}

_run_uninstall_manifest_remove_exercises() {
    local failed=0
    _exercise _asus_remove_manifest_bin_files failed
    failed=0
    _exercise _asus_remove_manifest_lib_files failed
    failed=0
    _exercise _asus_remove_manifest_sys_files failed
    failed=0
    _exercise _asus_remove_manifest_share_files failed
    _exercise BIN_DIR= _asus_remove_manifest_bin_files failed
    _exercise LIB_DIR= _asus_remove_manifest_lib_files failed
    _exercise SYS_DIR= _asus_remove_manifest_sys_files failed
}

_run_uninstall_nullglob_exercises() {
    shopt -u nullglob
    _exercise _asus_nullglob_push >/dev/null
    _exercise _asus_nullglob_pop >/dev/null
    shopt -s nullglob
    _exercise _asus_nullglob_push >/dev/null
    _exercise _asus_nullglob_pop >/dev/null
}

_run_uninstall_service_helpers() {
    _run_uninstall_unit_helpers
    _run_uninstall_residual_listing
    _run_uninstall_manifest_list_exercises
    _run_uninstall_manifest_seed_dirs
    _run_uninstall_manifest_seed_bin_lib_sys
    _run_uninstall_manifest_seed_share
    _run_uninstall_manifest_remove_exercises
    _run_uninstall_nullglob_exercises
    _exercise remove_installed_files >/dev/null
    _exercise resolve_fallback_user >/dev/null
    _exercise SUDO_USER=root USER=root resolve_fallback_user >/dev/null
}

_run_uninstall_restore_env_checks() {
    _exercise _check_valid_restore_env "" "" "" >/dev/null
    _exercise _check_valid_restore_env "1000" "" "$BUS_ROOT/$uid/bus" >/dev/null
    _exercise _check_valid_restore_env "$uid" "$STATE_DIR/$uid" "/missing/bus" >/dev/null
    _exercise _check_valid_restore_env "" "$STATE_DIR/$uid" "$BUS_ROOT/$uid/bus" >/dev/null
    _exercise _gnome_backup_state_present "$STATE_DIR/$uid" >/dev/null
    _exercise _gnome_backup_state_present "$STATE_DIR/missing" >/dev/null
    _exercise _resolve_target_user_info >/dev/null
}

_seed_uninstall_backup_bus() {
    echo "['Print']" > "$STATE_DIR/$uid/orig_show_screenshot_ui"
    echo "['XF86Launch1']" > "$STATE_DIR/$uid/orig_control_center"
    echo "['<Super>p']" > "$STATE_DIR/$uid/orig_switch_video_mode"
    echo "['<Super>p']" > "$STATE_DIR/$uid/orig_switch_monitor"
    if ! _bind_unix_socket_path "$BUS_ROOT/$uid/bus"; then
        echo "uninstall_helpers: failed to bind session bus socket" >&2
        return 1
    fi
}

_run_uninstall_restore_helpers() {
    _seed_uninstall_backup_bus
    _exercise _restore_schema_file "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid/orig_show_screenshot_ui" \
        "org.gnome.shell.keybindings" "show-screenshot-ui" >/dev/null
    _exercise _restore_schema_file "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid/missing_file" \
        "org.gnome.shell.keybindings" "show-screenshot-ui" >/dev/null
    : > "$STATE_DIR/$uid/empty_val"
    _exercise _restore_schema_file "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid/empty_val" \
        "org.gnome.shell.keybindings" "show-screenshot-ui" >/dev/null
    _exercise restore_gnome_keybinding_schema "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" \
        "orig_show_screenshot_ui" "org.gnome.shell.keybindings" "show-screenshot-ui" >/dev/null
    _exercise _reset_gnome_custom_bindings "$uname_cur" "$BUS_ROOT/$uid/bus" >/dev/null
    _exercise _restore_primary_keybindings "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" >/dev/null
    # Optional-key skip path when backup file is absent (modern GNOME without switch-video-mode).
    rm -f "$STATE_DIR/$uid/orig_switch_video_mode"
    _exercise _restore_optional_named_keybinding "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" \
        "orig_switch_video_mode" "org.gnome.settings-daemon.plugins.media-keys" "switch-video-mode" >/dev/null
    _exercise _restore_custom_keybindings "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" >/dev/null
    echo "['/x']" > "$STATE_DIR/$uid/orig_custom_keybindings"
    _exercise _restore_custom_keybindings "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_user_keybindings "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_keybinding_set "$uname_cur" "$BUS_ROOT/$uid/bus" "$STATE_DIR/$uid" >/dev/null
}

_uninstall_restore_shortcuts_cleanup() {
    local cleanup_path="$1" cleanup_backup="$2"
    PATH="$cleanup_path"
    if [ -n "$cleanup_backup" ] && [ -f "$cleanup_backup" ]; then
        cp "$cleanup_backup" "$mock_bin/gsettings"
        chmod +x "$mock_bin/gsettings" 2>/dev/null
        rm -f "$cleanup_backup"
    fi
}

_backup_uninstall_gsettings_stub() {
    if [ -f "$mock_bin/gsettings" ]; then
        gsettings_backup=$(mktemp)
        cp "$mock_bin/gsettings" "$gsettings_backup"
        chmod --reference="$mock_bin/gsettings" "$gsettings_backup" 2>/dev/null \
            || chmod +x "$gsettings_backup"
    fi
}

_run_uninstall_no_session_restore() {
    local saved_path="$1"
    local saved_user="${USER-}" saved_sudo_user="${SUDO_USER-}" had_sudo_user=0
    [ "${SUDO_USER+x}" = "x" ] && had_sudo_user=1
    SUDO_USER=root USER=root _soft restore_gnome_shortcuts "$NO_SESSION_USER" "" >/dev/null
    # Fallback user with empty uid path: SUDO_USER unset and who empty.
    unset SUDO_USER
    USER=""
    _soft restore_gnome_shortcuts "$NO_SESSION_USER" "" >/dev/null
    if [ "$had_sudo_user" = 1 ]; then
        SUDO_USER="$saved_sudo_user"
    else
        unset SUDO_USER
    fi
    USER="$saved_user"
    PATH="$mock_bin:$saved_path"
}

_run_uninstall_restore_shortcuts() {
    local gsettings_backup="" saved_path
    _seed_uninstall_backup_bus
    saved_path="$PATH"
    # Always restore PATH / gsettings stub, including early bind-failure returns.
    trap '_uninstall_restore_shortcuts_cleanup "$saved_path" "${gsettings_backup:-}"' RETURN
    # Active session user via loginctl stub (real find_active_session_user).
    cat > "$mock_bin/loginctl" <<EOF
#!/bin/sh
case "\$*" in
    *list-sessions*) echo "c1 $uid $uname_cur seat0" ;;
    *show-session*)
        case "\$*" in
            *-p Type*) echo wayland ;;
            *-p State*) echo active ;;
            *-p Name*) echo $uname_cur ;;
            *) echo "" ;;
        esac
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$mock_bin/loginctl"
    PATH="$mock_bin:$saved_path"
    _soft restore_gnome_shortcuts "$uname_cur" "$uid" >/dev/null
    _backup_uninstall_gsettings_stub
    cat > "$mock_bin/gsettings" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$mock_bin/gsettings"
    mkdir -p "$STATE_DIR/$uid"
    echo "['Print']" > "$STATE_DIR/$uid/orig_show_screenshot_ui"
    _driver_bind_required "$BUS_ROOT/$uid/bus" uninstall_helpers
    _soft restore_gnome_shortcuts "$uname_cur" "$uid" >/dev/null
    # No active session: empty loginctl; fallback via who stub → NO_SESSION_USER.
    cat > "$mock_bin/loginctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$mock_bin/loginctl"
    cat > "$mock_bin/who" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$mock_bin/who"
    PATH="$mock_bin:$saved_path"
    _run_uninstall_no_session_restore "$saved_path"
    trap - RETURN
    _uninstall_restore_shortcuts_cleanup "$saved_path" "$gsettings_backup"
}

_run_uninstall_systemctl_failure_paths() {
    local systemctl_save="$SYSTEMCTL"
    cat > "$mock_bin/systemctl-quiet-inactive" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$mock_bin/systemctl-quiet-inactive"
    _exercise SYSTEMCTL="$mock_bin/systemctl-quiet-inactive" \
        _verify_service_inactive asus-hotkey-daemon.service >/dev/null
    cat > "$mock_bin/systemctl-active" <<'EOF'
#!/bin/sh
if [ "$1" = "is-active" ]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$mock_bin/systemctl-active"
    _exercise SYSTEMCTL="$mock_bin/systemctl-active" _verify_service_inactive asus-hotkey-daemon.service >/dev/null
    _exercise SYSTEMCTL="$mock_bin/systemctl-active" stop_and_disable_services >/dev/null
    cat > "$mock_bin/systemctl-absent" <<'EOF'
#!/bin/sh
echo "Unit x.service not found" >&2
exit 1
EOF
    chmod +x "$mock_bin/systemctl-absent"
    _exercise SYSTEMCTL="$mock_bin/systemctl-absent" _run_systemctl_unit_action stop x.service >/dev/null
    cat > "$mock_bin/systemctl-hardfail" <<'EOF'
#!/bin/sh
echo "permission denied" >&2
exit 1
EOF
    chmod +x "$mock_bin/systemctl-hardfail"
    _exercise SYSTEMCTL="$mock_bin/systemctl-hardfail" _run_systemctl_unit_action stop x.service >/dev/null
    _exercise SYSTEMCTL="$mock_bin/systemctl-hardfail" _verify_service_inactive x.service >/dev/null
    cat > "$mock_bin/systemctl-silentfail" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$mock_bin/systemctl-silentfail"
    _exercise SYSTEMCTL="$mock_bin/systemctl-silentfail" _run_systemctl_daemon_reload >/dev/null
    _exercise SYSTEMCTL="$mock_bin/systemctl-silentfail" _run_systemctl_unit_action stop x.service >/dev/null
    SYSTEMCTL="$systemctl_save"
}

_run_uninstall_desktop_family_restore() {
    local missing_libs
    mkdir -p "$STATE_DIR/$uid"
    _exercise _restore_by_desktop_family kde "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_by_desktop_family xfce "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_by_desktop_family lxqt "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_by_desktop_family cinnamon "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_by_desktop_family mate "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_by_desktop_family gnome "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    _exercise _restore_by_desktop_family other "$uname_cur" "$uid" "$STATE_DIR/$uid" >/dev/null
    missing_libs=$(mktemp -d)
    _UNINSTALL_MISSING_LIBS="$missing_libs"
    mkdir -p "$missing_libs/lib"
    _exercise SCRIPT_DIR="$missing_libs" \
        _restore_kde_desktop_shortcuts "$uname_cur" "$STATE_DIR/$uid" >/dev/null
    _exercise SCRIPT_DIR="$missing_libs" \
        _restore_xfce_desktop_shortcuts "$uname_cur" "$STATE_DIR/$uid" >/dev/null
    _exercise SCRIPT_DIR="$missing_libs" \
        _restore_lxqt_desktop_shortcuts "$uname_cur" "$STATE_DIR/$uid" >/dev/null
    # Restore-fn failure preserves backup (warning path in generic helper).
    _exercise _restore_desktop_shortcuts_generic "KDE" "$REPO_ROOT/lib/install-kde.sh" \
        false "$uname_cur" "$STATE_DIR/$uid" 0 >/dev/null
    # Unknown desktop restore helper basename.
    _exercise _source_desktop_restore_lib_secondary "$REPO_ROOT/lib/install-bogus.sh" >/dev/null
    # Touch associative map keys so declare-line coverage can land.
    : "${_DESKTOP_RESTORE_FN_BY_FAMILY[kde]}"
    : "${_DESKTOP_RESTORE_FN_BY_FAMILY[xfce]}"
    : "${_DESKTOP_RESTORE_FN_BY_FAMILY[lxqt]}"
    : "${_DESKTOP_RESTORE_FN_BY_FAMILY[cinnamon]}"
    : "${_DESKTOP_RESTORE_FN_BY_FAMILY[mate]}"
}

_run_uninstall_service_helpers
_run_uninstall_restore_env_checks
_run_uninstall_restore_helpers
_run_uninstall_restore_shortcuts
_run_uninstall_systemctl_failure_paths
_run_uninstall_desktop_family_restore
