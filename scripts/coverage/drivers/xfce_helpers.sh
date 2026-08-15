#!/usr/bin/env bash
# kcov driver: exercise lib/install-xfce.sh as covered product code.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

_write_xfce_stubs() {
    local mock="$1"
    cat > "$mock/xfconf-query" <<'EOF'
#!/bin/sh
case " $* " in
    *" -s "*|*" -n "*) exit 0 ;;
    *" -p /commands/custom/New "*) exit 1 ;;
esac
# Plain property read: pretend the binding already exists.
echo "/usr/bin/old-binding"
exit 0
EOF
    _write_sudo_stub "$mock"
    chmod +x "$mock"/*
}

_seed_xfce_restore_state() {
    local state_uid="$1"
    printf '/usr/bin/old-display\n' > "$state_uid/orig_xfce_xf86display"
    printf '/usr/bin/true\n' > "$state_uid/orig_xfce_super_f12"
    printf '/usr/bin/true\n' > "$state_uid/orig_xfce_super_shift_s"
}

_run_xfce_restore_paths() {
    local user="$1" state_uid="$2" bus_path="$3"
    _soft_expect 0 _xfce_restore_one "$user" "$bus_path" "/commands/custom/XF86Display" \
        "$state_uid/orig_xfce_xf86display"
    _soft_expect 0 _xfce_restore_one "$user" "$bus_path" "/commands/custom/<Super>F12" \
        "$state_uid/orig_xfce_super_f12"
    _soft_expect 0 _xfce_restore_one "$user" "$bus_path" "/missing" "$state_uid/does-not-exist"
    _soft_expect 0 restore_xfce_shortcuts "$user" "$state_uid"
}

_run_xfce_helper_paths() {
    local user="$1" state_uid="$2" bus_path="$3" scratch
    scratch="$STATE_DIR/xfce-helper-paths"
    mkdir -p "$scratch"
    _soft_expect 0 _xfce_run_query "$user" "unix:path=$bus_path" \
        -c xfce4-keyboard-shortcuts -l >/dev/null
    _soft_expect 0 _xfce_backup_value_or_absent "$scratch/value" "old"
    _soft_expect 0 _xfce_backup_value_or_absent "$scratch/empty" ""
    _soft_expect 0 _xfce_backup_from_query "$scratch/status-one" 1 ""
    _soft_expect 0 _xfce_set_command_binding "$user" "$bus_path" \
        "/commands/custom/New" "/usr/bin/new-binding"
    _soft_expect 0 _xfce_restore_one "$user" "$bus_path" "/absent" "$scratch/empty"
    rm -f "$state_uid/xfce_bus_path"
    _soft_expect 0 _xfce_resolve_restore_bus "$state_uid" >/dev/null
    mkdir -p "$scratch/no-backups"
    _soft_expect 1 _xfce_require_backup_files "$scratch/no-backups"
    : > "$scratch/not-a-directory"
    _soft_expect 1 _xfce_prepare_component_state "$scratch/not-a-directory/state" \
        "$user" "$bus_path"
    _soft_expect 1 _xfce_write_backup_value "$scratch/missing/value" "old"
    _soft_expect 1 _xfce_write_state_file "$scratch/missing/state" "xfce" "test"
    _soft_expect 1 _xfce_mark_backup_absent "$scratch/missing/absent"
}

_driver_set_prefix _XFCE_PREFIX_OWNED
_xfce_rm_if_set() {
    [ -n "${1:-}" ] || return 0
    /bin/rm -rf "$1"
}

_xfce_driver_cleanup() {
    _xfce_rm_if_set "${mock:-}"
    _xfce_rm_if_set "${iso:-}"
    _xfce_rm_if_set "${_XFCE_EMPTY_BUS:-}"
    if [ "${_XFCE_PREFIX_OWNED:-0}" = 1 ]; then
        _xfce_rm_if_set "${PREFIX:-}"
    fi
}
trap '_xfce_driver_cleanup' EXIT
BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
INSTALL_COMMAND_TIMEOUT=1
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER
uid="$(id -u)"
user="$(id -un)"
mkdir -p "$STATE_DIR/$uid" "$BUS_ROOT/$uid"
_driver_bind_required "$BUS_ROOT/$uid/bus" xfce_helpers

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" xfce_helpers quiet
# shellcheck source=lib/asus-session.sh
_driver_source_required "$REPO_ROOT/lib/asus-session.sh" xfce_helpers quiet
# shellcheck source=lib/asus-i18n.sh
_driver_source_required "$REPO_ROOT/lib/asus-i18n.sh" xfce_helpers quiet
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" xfce_helpers quiet
# shellcheck source=lib/install-xfce.sh
_driver_source_required "$REPO_ROOT/lib/install-xfce.sh" xfce_helpers quiet

mock=$(mktemp -d)
iso=$(mktemp -d)
_link_iso_tools "$iso"
    _link_iso_additional_tools "$iso" id mktemp mv basename awk whoami
_write_xfce_stubs "$mock"
_make_fake_loginctl_current_user "$mock"
PATH="$mock:$iso"
SUDO_CMD="$mock/sudo"
export PATH SUDO_CMD BUS_ROOT STATE_DIR PREFIX

_soft_expect 0 configure_xfce_component
_run_xfce_helper_paths "$user" "$STATE_DIR/$uid" "$BUS_ROOT/$uid/bus"
_seed_xfce_restore_state "$STATE_DIR/$uid"
_run_xfce_restore_paths "$user" "$STATE_DIR/$uid" "$BUS_ROOT/$uid/bus"

# Empty BUS_ROOT: real _resolve_user_bus_info finds no session bus socket.
_XFCE_EMPTY_BUS=$(mktemp -d)
BUS_ROOT="$_XFCE_EMPTY_BUS"
export BUS_ROOT
_soft_expect 1 configure_xfce_component
rm -rf "$_XFCE_EMPTY_BUS"
unset _XFCE_EMPTY_BUS
BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
export BUS_ROOT
mkdir -p "$BUS_ROOT/$uid"
_driver_bind_required "$BUS_ROOT/$uid/bus" xfce_helpers

PATH="$iso"
_soft_expect 1 configure_xfce_component
PATH="$mock:$iso"

printf '#!/bin/sh\nexit 1\n' > "$mock/xfconf-query"
mkdir -p "$STATE_DIR/$uid"
_seed_xfce_restore_state "$STATE_DIR/$uid"
_soft_expect 1 restore_xfce_shortcuts "$user" "$STATE_DIR/$uid"
_soft_expect 1 configure_xfce_component
trap - EXIT
_xfce_driver_cleanup
