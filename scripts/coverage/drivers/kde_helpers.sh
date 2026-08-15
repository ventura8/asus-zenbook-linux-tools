#!/usr/bin/env bash
# kcov driver: exercise lib/install-kde.sh as covered product code.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

_kde_rm_if_set() {
    [ -n "${1:-}" ] || return 0
    /bin/rm -rf "$1"
}

_kde_driver_cleanup() {
    _kde_rm_if_set "${mock:-}"
    _kde_rm_if_set "${iso:-}"
    if [ "${_KDE_PREFIX_OWNED:-0}" = 1 ]; then
        _kde_rm_if_set "${PREFIX:-}"
        return 0
    fi
    if [ "${_KDE_BUS_OWNED:-0}" = 1 ]; then
        _kde_rm_if_set "${BUS_ROOT:-}"
    fi
}
trap '_kde_driver_cleanup' EXIT

_write_kde_stubs() {
    local mock="$1"
    printf '#!/bin/sh\nexit 0\n' > "$mock/kwriteconfig6"
    # Return a prior binding so kscreen backup covers the non-absent write path.
    printf '#!/bin/sh\nprintf "Meta+P\\n"\nexit 0\n' > "$mock/kreadconfig6"
    cat > "$mock/qdbus" <<'EOF'
#!/bin/sh
[ "${KDE_QDBUS_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
    _write_sudo_stub "$mock"
    chmod +x "$mock"/*
}

_run_kde_state_branch_paths() {
    local user="$1" conf="$2" scratch blocked backup
    scratch="$STATE_DIR/kde-branch-paths"
    blocked="$scratch/not-a-directory"
    backup="$scratch/absent-backup"
    mkdir -p "$scratch"
    _soft_expect 0 _kde_write_backup_value_or_absent "$backup" ""
    _soft_expect 0 _kde_restore_kscreen_key "$user" "$conf" kscreen _launch "$backup"
    _soft_expect 1 _kde_require_kscreen_backup "$scratch/no-backups"
    _soft_expect 1 _kde_atomic_write_file "$scratch/missing/value" value old
    _soft_expect 1 _kde_atomic_write_file "$scratch/missing/absent" absent
    : > "$blocked"
    _soft_expect 1 _kde_write_target_user_state "$blocked" "$user"
    _soft_expect 1 _kde_prepare_install_state "$blocked" "$blocked/kde" "$user"
}

_run_kde_reconfigure_failure_paths() {
    local user="$1" scratch
    scratch="$STATE_DIR/kde-reconfigure-failure"
    mkdir -p "$scratch"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 KDE_QDBUS_FAIL=1 \
        _kde_reconfigure_kglobalaccel "$user"
    _soft_expect 0 _exercise KCOV_EXERCISE_RETURN_STATUS=1 KDE_QDBUS_FAIL=1 \
        _kde_finish_restore "$user" "$scratch" 0
}

_setup_kde_bus_root() {
    BUS_ROOT="${BUS_ROOT:-${DBUS_BUS_ROOT:-${RUN_USER_ROOT:-}}}"
    if [ -z "$BUS_ROOT" ] || ! mkdir -p "$BUS_ROOT" 2>/dev/null; then
        BUS_ROOT="$PREFIX/run/user"
        mkdir -p "$BUS_ROOT"
        _KDE_BUS_OWNED=1
    fi
}

_remove_kde_owned_bus_socket() {
    local uid="$1"
    if [ "${_KDE_BUS_OWNED:-0}" = 1 ]; then
        rm -f "$BUS_ROOT/$uid/bus"
    fi
}

_driver_set_prefix _KDE_PREFIX_OWNED
_KDE_BUS_OWNED=0
_setup_kde_bus_root
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
INSTALL_COMMAND_TIMEOUT=1
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER
mkdir -p "$PREFIX/usr/local/share/applications" "$STATE_DIR"

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" kde_helpers
# shellcheck source=lib/asus-session.sh
_driver_source_required "$REPO_ROOT/lib/asus-session.sh" kde_helpers
# shellcheck source=lib/asus-i18n.sh
_driver_source_required "$REPO_ROOT/lib/asus-i18n.sh" kde_helpers
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" kde_helpers
# shellcheck source=lib/install-kde.sh
_driver_source_required "$REPO_ROOT/lib/install-kde.sh" kde_helpers

uid="$(id -u)"
user="$(id -un)"
mock=$(mktemp -d)
iso=$(mktemp -d)
_link_iso_tools "$iso"
    _link_iso_additional_tools "$iso" id mktemp mv loginctl awk whoami python3 stat
_write_kde_stubs "$mock"
_make_fake_loginctl_current_user "$mock"
PATH="$mock:$iso"
SUDO_CMD="$mock/sudo"
export PATH SUDO_CMD BUS_ROOT STATE_DIR PREFIX

mkdir -p "$BUS_ROOT/$uid"
_driver_bind_required "$BUS_ROOT/$uid/bus" kde_helpers

_soft_expect 0 configure_kde_component
conf=$(_soft_expect 0 _kde_kwriteconfig_bin | tail -n 1)
conf="${conf:-kwriteconfig6}"
_soft_expect 0 _write_kde_helper_desktops
config_dir="$STATE_DIR/$uid/kde"
mkdir -p "$config_dir"
_soft_expect 0 _set_kde_keybindings "$user" "$conf" "$config_dir"
_soft_expect 0 restore_kde_shortcuts "$user" "$STATE_DIR/$uid"
_run_kde_state_branch_paths "$user" "$conf"
_run_kde_reconfigure_failure_paths "$user"

# Only remove sockets under the driver-owned fallback root.
_remove_kde_owned_bus_socket "$uid"
_soft_expect 1 configure_kde_component
_driver_bind_required "$BUS_ROOT/$uid/bus" kde_helpers

PATH="$iso"
_soft_expect 1 configure_kde_component

PATH="$mock:$iso"
printf '#!/bin/sh\nexit 1\n' > "$mock/kwriteconfig6"
_soft_expect 1 configure_kde_component

rm -f "$mock/kwriteconfig6"
printf '#!/bin/sh\nexit 0\n' > "$mock/kwriteconfig5"
chmod +x "$mock/kwriteconfig5"
_soft_expect 0 _kde_kwriteconfig_bin >/dev/null
_soft_expect 0 configure_kde_component
_soft_expect 0 restore_kde_shortcuts "$user" "$STATE_DIR/$uid"

rm -f "$mock/kreadconfig6"
_soft_expect 1 _kde_install_precheck "$user:$uid:$BUS_ROOT/$uid/bus"
printf '#!/bin/sh\nprintf "Meta+P\\n"\nexit 0\n' > "$mock/kreadconfig6"
chmod +x "$mock/kreadconfig6"
rm -f "$mock/qdbus"
_soft_expect 1 _kde_install_precheck "$user:$uid:$BUS_ROOT/$uid/bus"
trap - EXIT
_kde_driver_cleanup
