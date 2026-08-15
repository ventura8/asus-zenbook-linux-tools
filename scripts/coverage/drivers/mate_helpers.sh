#!/usr/bin/env bash
# kcov driver: exercise lib/install-mate.sh as covered product code.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

_write_mate_gsettings_stub() {
    local mock="$1" log="$2"
    cat > "$mock/gsettings" <<EOF
#!/bin/sh
log="$log"
printf '%s\\n' "\$*" >> "\$log"
case "\$1" in
  list-keys) printf '%s\\n' name action binding; exit 0 ;;
  get)
    [ "\${MATE_GET_FAIL:-0}" = 1 ] && exit 1
    printf "'old-%s'\\n" "\$3"
    exit 0
    ;;
  set)
    [ "\${MATE_SET_FAIL:-0}" = 1 ] && exit 1
    printf '%s\\n' "\$4" > "\${log}.val.\$3"
    exit 0
    ;;
  reset-recursively) exit 0 ;;
esac
exit 0
EOF
    _make_fake_loginctl_current_user "$mock"
    _write_sudo_stub "$mock"
    chmod +x "$mock"/*
}

_driver_set_prefix _MATE_PREFIX_OWNED
_mate_rm_if_set() {
    [ -n "${1:-}" ] || return 0
    /bin/rm -rf "$1"
}
_mate_cleanup() {
    _mate_rm_if_set "${mock:-}"
    _mate_rm_if_set "${iso:-}"
    _mate_rm_if_set "${glog:-}"
    _mate_rm_if_set "${empty_bus:-}"
    if [ "${_MATE_PREFIX_OWNED:-0}" = 1 ]; then
        _mate_rm_if_set "${PREFIX:-}"
    fi
}
trap '_mate_cleanup' EXIT

BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
INSTALL_COMMAND_TIMEOUT=1
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER
uid="$(id -u)"
user="$(id -un)"
mkdir -p "$STATE_DIR/$uid" "$BUS_ROOT/$uid"
glog=$(mktemp)
mock=$(mktemp -d)
iso=$(mktemp -d)
_link_iso_tools "$iso"
    _link_iso_additional_tools "$iso" id mktemp mv basename getent cut cat awk
_write_mate_gsettings_stub "$mock" "$glog"
PATH="$mock:$iso"
SUDO_CMD="$mock/sudo"
export PATH SUDO_CMD BUS_ROOT STATE_DIR PREFIX

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" mate_helpers quiet
# shellcheck source=lib/asus-session.sh
_driver_source_required "$REPO_ROOT/lib/asus-session.sh" mate_helpers quiet
# shellcheck source=lib/asus-i18n.sh
_driver_source_required "$REPO_ROOT/lib/asus-i18n.sh" mate_helpers quiet
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" mate_helpers quiet
# shellcheck source=lib/install-mate.sh
_driver_source_required "$REPO_ROOT/lib/install-mate.sh" mate_helpers quiet

_driver_bind_required "$BUS_ROOT/$uid/bus" mate_helpers

_soft_expect 0 configure_mate_component
_soft_expect 0 restore_mate_shortcuts "$user" "$STATE_DIR/$uid"
_soft_expect 0 _exercise KCOV_EXERCISE_RETURN_STATUS=1 MATE_GET_FAIL=1 \
    configure_mate_component
_soft_expect 0 restore_mate_shortcuts "$user" "$STATE_DIR/$uid"
_soft_expect 1 _mate_atomic_write "$STATE_DIR/missing/value" "old"
_soft_expect 1 _mate_write_state_file "$STATE_DIR/missing/state" "mate" "test"
_soft_expect 1 _mate_clear_config_dir "$STATE_DIR"
_soft_expect 1 _mate_finish_restore "$STATE_DIR/$uid" 1
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 MATE_SET_FAIL=1 \
    configure_mate_component
: > "$STATE_DIR/not-a-directory"
_soft_expect 1 _mate_prepare_state "$STATE_DIR/not-a-directory/state" "$user"
mkdir -p "$STATE_DIR/existing"
: > "$STATE_DIR/existing/slot"
_soft_expect 0 _mate_backup_slot "$user" "$BUS_ROOT/$uid/bus" test \
    "$STATE_DIR/existing/slot"
_soft_expect 0 _mate_restore_slot "$user" "$BUS_ROOT/$uid/bus" test \
    "$STATE_DIR/existing/missing"
saved_bus_root="$BUS_ROOT"
empty_bus=$(mktemp -d)
BUS_ROOT="$empty_bus"
export BUS_ROOT
_soft_expect 1 configure_mate_component
BUS_ROOT="$saved_bus_root"
export BUS_ROOT
_exercise _mate_shortcut_table >/dev/null
_soft restore_mate_shortcuts "$user" "$STATE_DIR/$uid"
_soft _mate_write_state_file "/proc/self/nonexistent-dir/state" "x" "kcov"

trap - EXIT
_mate_cleanup
