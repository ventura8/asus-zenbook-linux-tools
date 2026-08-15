#!/usr/bin/env bash
# kcov driver: exercise lib/install-cinnamon.sh as covered product code.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

_write_cinnamon_gsettings_stub() {
    local mock="$1" log="$2"
    printf '%s\n' "['other']" > "${log}.val.custom-list"
    printf '%s\n' "['XF86Display']" > "${log}.val.video-outputs"
    cat > "$mock/gsettings" <<EOF
#!/bin/sh
log="$log"
printf '%s\\n' "\$*" >> "\$log"
case "\$1" in
  list-keys) printf '%s\\n' custom-list video-outputs; exit 0 ;;
  get)
    [ "\${CIN_GET_FAIL:-0}" = 1 ] && exit 1
    if [ -f "\${log}.val.\$3" ]; then cat "\${log}.val.\$3"; else echo '[]'; fi
    exit 0
    ;;
  set)
    [ "\${CIN_SET_FAIL:-0}" = 1 ] && exit 1
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

_driver_set_prefix _CIN_PREFIX_OWNED
_cin_rm_if_set() {
    [ -n "${1:-}" ] || return 0
    /bin/rm -rf "$1"
}
_cin_cleanup() {
    _cin_rm_if_set "${mock:-}"
    _cin_rm_if_set "${iso:-}"
    _cin_rm_if_set "${glog:-}"
    if [ "${_CIN_PREFIX_OWNED:-0}" = 1 ]; then
        _cin_rm_if_set "${PREFIX:-}"
    fi
}
trap '_cin_cleanup' EXIT

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
    _link_iso_additional_tools "$iso" id mktemp mv basename getent cut cat awk grep python3
_write_cinnamon_gsettings_stub "$mock" "$glog"
PATH="$mock:$iso"
SUDO_CMD="$mock/sudo"
export PATH SUDO_CMD BUS_ROOT STATE_DIR PREFIX

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" cinnamon_helpers quiet
# shellcheck source=lib/asus-session.sh
_driver_source_required "$REPO_ROOT/lib/asus-session.sh" cinnamon_helpers quiet
# shellcheck source=lib/asus-i18n.sh
_driver_source_required "$REPO_ROOT/lib/asus-i18n.sh" cinnamon_helpers quiet
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" cinnamon_helpers quiet
# shellcheck source=lib/install-cinnamon.sh
_driver_source_required "$REPO_ROOT/lib/install-cinnamon.sh" cinnamon_helpers quiet

_driver_bind_required "$BUS_ROOT/$uid/bus" cinnamon_helpers

_soft_expect 0 configure_cinnamon_component
_soft_expect 0 restore_cinnamon_shortcuts "$user" "$STATE_DIR/$uid"
_soft_expect 0 _exercise KCOV_EXERCISE_RETURN_STATUS=1 CIN_GET_FAIL=1 \
    configure_cinnamon_component
_soft_expect 0 restore_cinnamon_shortcuts "$user" "$STATE_DIR/$uid"
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 CIN_SET_FAIL=1 \
    configure_cinnamon_component
_soft_expect 1 _cinnamon_atomic_write "$STATE_DIR/missing/value" "old"
_soft_expect 1 _cinnamon_write_state_file "$STATE_DIR/missing/state" "cinnamon" "test"
_soft_expect 1 _cinnamon_clear_config_dir "$STATE_DIR"
_soft_expect 1 _cinnamon_finish_restore "$STATE_DIR/$uid" 1
: > "$STATE_DIR/not-a-directory"
_soft_expect 1 _cinnamon_prepare_state "$STATE_DIR/not-a-directory/state" "$user"
mkdir -p "$STATE_DIR/existing"
: > "$STATE_DIR/existing/slot"
_soft_expect 0 _cinnamon_backup_slot "$user" "$BUS_ROOT/$uid/bus" test \
    "$STATE_DIR/existing/slot"
# Failure and restore paths: table dump, absent-marker restore, and failed state writes.
_exercise _cinnamon_shortcut_table >/dev/null
_soft _cinnamon_mark_absent "$STATE_DIR/$uid/orig_cinnamon_xf86display"
_soft restore_cinnamon_shortcuts "$user" "$STATE_DIR/$uid"
_soft _cinnamon_write_state_file "/proc/self/nonexistent-dir/state" "x" "kcov"

trap - EXIT
_cin_cleanup
