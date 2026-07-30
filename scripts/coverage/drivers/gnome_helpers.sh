#!/usr/bin/env bash
# kcov driver: exercise lib/install-gnome.sh success and failure branches.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

_write_gnome_gsettings_stub() {
    local mock="$1" log="$2"
    printf '%s\n' "['Print']" > "${log}.val.show-screenshot-ui"
    printf '%s\n' "['<Super>p']" > "${log}.val.switch-monitor"
    printf '%s\n' "['<Super>p']" > "${log}.val.switch-video-mode"
    printf '%s\n' "[]" > "${log}.val.custom-keybindings"
    printf '%s\n' "['other@ext']" > "${log}.val.enabled-extensions"
    printf '%s\n' "false" > "${log}.val.disable-user-extensions"
    cat > "$mock/gsettings" <<EOF
#!/bin/sh
log="$log"
printf '%s\\n' "\$*" >> "\$log"
case "\$1" in
  list-keys)
    printf '%s\\n' switch-video-mode switch-monitor show-screenshot-ui custom-keybindings
    exit 0
    ;;
  get)
    [ "\${GNOME_GET_FAIL:-0}" = 1 ] && exit 1
    key="\$3"
    # Relocatable schemas pass key as \$3 still for simple gets.
    if [ -f "\${log}.val.\$key" ]; then cat "\${log}.val.\$key"; else echo "[]"; fi
    exit 0
    ;;
  set)
    [ "\${GNOME_SET_FAIL:-0}" = 1 ] && exit 1
    printf '%s\\n' "\$4" > "\${log}.val.\$3"
    exit 0
    ;;
  reset) exit 0 ;;
esac
exit 0
EOF
    cat > "$mock/gnome-extensions" <<'EOF'
#!/bin/sh
exit 0
EOF
    _make_fake_loginctl_current_user "$mock"
    _write_sudo_stub "$mock"
    chmod +x "$mock"/*
}

_driver_set_prefix _GNOME_PREFIX_OWNED
_gnome_rm_if_set() {
    [ -n "${1:-}" ] || return 0
    /bin/rm -rf "$1"
}
_gnome_cleanup() {
    _gnome_rm_if_set "${mock:-}"
    _gnome_rm_if_set "${iso:-}"
    _gnome_rm_if_set "${glog:-}"
    if [ "${_GNOME_PREFIX_OWNED:-0}" = 1 ]; then
        _gnome_rm_if_set "${PREFIX:-}"
    fi
}
trap '_gnome_cleanup' EXIT

BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
SCRIPT_DIR="$REPO_ROOT"
INSTALL_COMMAND_TIMEOUT=1
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER
uid="$(id -u)"
user="$(id -un)"
mkdir -p "$STATE_DIR/$uid" "$BUS_ROOT/$uid" \
    "$PREFIX/home/$user/.local/share/gnome-shell/extensions"
# Extension install looks up home via getent; keep state under PREFIX only.
glog=$(mktemp)
mock=$(mktemp -d)
iso=$(mktemp -d)
_link_iso_tools "$iso"
_link_iso_additional_tools "$iso" id mktemp mv basename getent cut cat awk grep python3 cp mkdir chmod rm true
_write_gnome_gsettings_stub "$mock" "$glog"
PATH="$mock:$iso"
SUDO_CMD="$mock/sudo"
export PATH SUDO_CMD BUS_ROOT STATE_DIR PREFIX SCRIPT_DIR

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" gnome_helpers quiet
# shellcheck source=lib/asus-session.sh
_driver_source_required "$REPO_ROOT/lib/asus-session.sh" gnome_helpers quiet
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" gnome_helpers quiet

_driver_bind_required "$BUS_ROOT/$uid/bus" gnome_helpers

_soft_expect 0 configure_gnome_component
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 GNOME_GET_FAIL=1 \
    configure_gnome_component
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 GNOME_SET_FAIL=1 \
    configure_gnome_component
_soft_expect 0 _ensure_keybinding_path "[]" "/org/gnome/x/" >/dev/null
_soft_expect 0 _gsettings_as_array_op merge "[]" "/org/gnome/a/" "/org/gnome/b/" >/dev/null
_soft_expect 0 _gsettings_as_array_op drop "['/org/gnome/a/']" "/org/gnome/a/" >/dev/null
_soft_expect 1 _gsettings_set_key "$user" "$BUS_ROOT/$uid/bus" \
    org.gnome.shell.keybindings show-screenshot-ui ""
_soft_expect 0 _gnome_write_desktop_family_state "$STATE_DIR/$uid"
_soft_expect 1 _gnome_write_desktop_family_state "/proc/1/root/blocked-gnome-state-$$"
_soft_expect 1 _is_safe_config_dir ""
_soft_expect 1 _is_safe_config_dir /
_soft_expect 1 _is_safe_config_dir "$STATE_DIR"
_soft_expect 0 _is_safe_config_dir "$STATE_DIR/$uid"
_soft_expect 0 backup_gnome_keybinding "$user" "$BUS_ROOT/$uid/bus" \
    "org.gnome.shell.keybindings" "show-screenshot-ui" "$STATE_DIR/$uid/orig_show_screenshot_ui"
_soft_expect 0 _merge_custom_keybindings "[]" "/org/gnome/x/" >/dev/null
_soft_expect 0 _drop_keybinding_path "['/org/gnome/x/']" "/org/gnome/x/" >/dev/null
_soft_expect 0 apply_gnome_shortcuts "$user" "$BUS_ROOT/$uid/bus" \
    "$STATE_DIR/$uid/orig_ss" "$STATE_DIR/$uid/orig_ctrl" \
    "$STATE_DIR/$uid/orig_vm" "$STATE_DIR/$uid" "$STATE_DIR/$uid/orig_sm"
# Failure paths for backup write / optional keys.
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
    backup_gnome_keybinding "$user" "$BUS_ROOT/$uid/bus" \
    "org.gnome.shell.keybindings" "show-screenshot-ui" \
    "/proc/1/root/blocked-backup-$$/orig"
_soft_expect 0 _gsettings_restore_key "$user" "$BUS_ROOT/$uid/bus" \
    org.gnome.shell.keybindings show-screenshot-ui "['Print']" show-screenshot-ui
_soft_expect 0 _set_custom_binding_slot "$user" "$BUS_ROOT/$uid/bus" \
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom99/" \
    "ASUS Test" "/bin/true" "<Super>F24" >/dev/null
_soft_expect 0 _set_myasus_keybindings "$user" "$BUS_ROOT/$uid/bus" >/dev/null
_soft_expect 0 _backup_optional_gnome_key "$user" "$BUS_ROOT/$uid/bus" \
    org.gnome.settings-daemon.plugins.media-keys switch-video-mode \
    "$STATE_DIR/$uid/orig_switch_video_mode" >/dev/null
# Failure paths: no gi python, backup/target_user mv fail, restore fail, wayland hint.
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 PATH="/nonexistent" \
    _gsettings_python3_with_gi >/dev/null
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 PATH="/nonexistent" \
    _gsettings_as_array_op merge "[]" "/org/gnome/x/" >/dev/null
(
    mv() { return 1; }
    _soft_expect 1 backup_gnome_keybinding "$user" "$BUS_ROOT/$uid/bus" \
        "org.gnome.shell.keybindings" "show-screenshot-ui" \
        "$STATE_DIR/$uid/orig_mv_fail_$$" >/dev/null
    _soft_expect 1 apply_gnome_shortcuts "$user" "$BUS_ROOT/$uid/bus" \
        "$STATE_DIR/$uid/orig_ss" "$STATE_DIR/$uid/orig_ctrl" \
        "$STATE_DIR/$uid/orig_vm" "$STATE_DIR/$uid" \
        "$STATE_DIR/$uid/orig_sm" >/dev/null
)
_soft_expect 1 _gsettings_restore_key "$user" "$BUS_ROOT/$uid/bus" \
    org.gnome.shell.keybindings show-screenshot-ui "['Print']" show-screenshot-ui \
    >/dev/null
# Force restore warning by stubbing set to fail.
(
    _gsettings_set_key() { return 1; }
    _soft_expect 1 _gsettings_restore_key "$user" "$BUS_ROOT/$uid/bus" \
        org.gnome.shell.keybindings show-screenshot-ui "['Print']" show-screenshot-ui \
        >/dev/null
)
_soft_expect 0 _gnome_disable_extension_cli "$user" "" \
    "$ASUS_GNOME_WINDOW_SWAP_UUID" >/dev/null
(
    asus_session_type() { printf 'wayland\n'; }
    _soft_expect 0,1 _gnome_hint_wayland_extension_reload "$user" >/dev/null
)
_soft_expect 1 _gnome_resolve_user_home "no-such-asus-user-$$" >/dev/null
# desktop_family write failure after mkdir succeeds (read-only file).
mkdir -p "$STATE_DIR/$uid"
: > "$STATE_DIR/$uid/desktop_family"
chmod a-w "$STATE_DIR/$uid/desktop_family"
_soft_expect 1 _gnome_write_desktop_family_state "$STATE_DIR/$uid" >/dev/null
chmod u+w "$STATE_DIR/$uid/desktop_family" 2>/dev/null
# Extension install + keybinding/optional miss paths.
_soft_expect 0 _install_gnome_window_swap_extension "$user" \
    "$BUS_ROOT/$uid/bus" >/dev/null
_soft_expect 0 _gnome_enable_window_swap_extension "$user" "$BUS_ROOT/$uid/bus" \
    "$ASUS_GNOME_WINDOW_SWAP_UUID" >/dev/null
_soft_expect 0,1 _set_gnome_keybindings "$user" "$BUS_ROOT/$uid/bus" >/dev/null
_soft_expect 0 _backup_optional_gnome_key "$user" "$BUS_ROOT/$uid/bus" \
    org.gnome.shell.keybindings missing-key-$$ \
    "$STATE_DIR/$uid/orig_missing_key" >/dev/null
_soft_expect 0 _reset_native_display_binding "$user" "$BUS_ROOT/$uid/bus" \
    >/dev/null
_soft_expect 0 _set_display_keybinding "$user" "$BUS_ROOT/$uid/bus" \
    >/dev/null
_soft_expect 0 _set_display_binding_slots "$user" "$BUS_ROOT/$uid/bus" \
    >/dev/null
_soft_expect 0 _gnome_install_optional_window_swap "$user" \
    "$BUS_ROOT/$uid/bus" >/dev/null
_soft_expect 0 remove_gnome_window_swap_extension "$user" \
    "$BUS_ROOT/$uid/bus" >/dev/null
: > "$STATE_DIR/$uid/orig_ss"
: > "$STATE_DIR/$uid/orig_ctrl"
: > "$STATE_DIR/$uid/orig_vm"
: > "$STATE_DIR/$uid/orig_sm"
_soft_expect 0 rollback_gnome_shortcuts "$user" "$BUS_ROOT/$uid/bus" \
    "$STATE_DIR/$uid" \
    "$STATE_DIR/$uid/orig_ss" "$STATE_DIR/$uid/orig_ctrl" \
    "$STATE_DIR/$uid/orig_vm" "$STATE_DIR/$uid/orig_sm" >/dev/null
_soft_expect 0,1 _gsettings_as_array_op merge "['a@x']" "b@y" >/dev/null
_soft_expect 0,1 _gsettings_as_array_op drop "['a@x','b@y']" "b@y" >/dev/null
_soft_expect 0 _gnome_mark_extension_enabled "$user" "$BUS_ROOT/$uid/bus" \
    "asus-window-swap@ventura8.github.com" >/dev/null
_soft_expect 0 _gnome_mark_extension_disabled "$user" "$BUS_ROOT/$uid/bus" \
    "asus-window-swap@ventura8.github.com" >/dev/null
_soft_expect 0,1 _gnome_hint_wayland_extension_reload "$user" >/dev/null
_soft_expect 0,1 _gnome_resolve_user_home "$user" >/dev/null
_soft_expect 0 _apply_gnome_config "$user" "$BUS_ROOT/$uid/bus" \
    "$STATE_DIR/$uid" >/dev/null
