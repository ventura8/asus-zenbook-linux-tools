#!/usr/bin/env bash
# kcov driver: exercise lib/install-lxqt.sh as covered product code.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

_write_lxqt_stubs() {
    local mock="$1" user="$2"
    printf '#!/bin/sh\nexit 0\n' > "$mock/pkill"
    cat > "$mock/mktemp" <<'EOF'
#!/bin/sh
if [ -n "${LXQT_MKTEMP_COUNT_FILE:-}" ]; then
  count=$(cat "$LXQT_MKTEMP_COUNT_FILE" 2>/dev/null || printf '0')
  count=$((count + 1))
  printf '%s\n' "$count" > "$LXQT_MKTEMP_COUNT_FILE"
  [ "$count" = "${LXQT_MKTEMP_FAIL_CALL:-0}" ] && exit 1
fi
exec /usr/bin/mktemp "$@"
EOF
    # Session discovery fallbacks when PATH is isolated to mock+iso.
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$user" > "$mock/whoami"
    _make_fake_loginctl_current_user "$mock"
    _write_sudo_stub "$mock"
    chmod +x "$mock"/*
}

_seed_lxqt_home_conf() {
    local home_dir="$1" conf_dir conf
    conf_dir="${home_dir}/.config/lxqt"
    mkdir -p "$conf_dir"
    conf="${conf_dir}/globalkeyshortcuts.conf"
    cat > "$conf" <<'EOF'
[XF86Display.42]
Comment=Old Display
Enabled=true
Exec=/usr/bin/old-display

[Other.1]
Comment=Keep Me
Enabled=true
Exec=/usr/bin/keep
EOF
}

_seed_lxqt_restore_state() {
    local state_uid="$1"
    printf '[XF86Display.42]\nComment=Old Display\nEnabled=true\nExec=/usr/bin/old-display\n' \
        > "$state_uid/orig_lxqt_xf86display"
    printf 'XF86Display.42\n' > "$state_uid/orig_lxqt_xf86display.section"
    : > "$state_uid/orig_lxqt_meta_p.absent"
    printf 'Meta%%2BP.98\n' > "$state_uid/orig_lxqt_meta_p.section"
    : > "$state_uid/orig_lxqt_meta_f12.absent"
    printf 'Meta%%2BF12.99\n' > "$state_uid/orig_lxqt_meta_f12.section"
    : > "$state_uid/orig_lxqt_meta_shift_s.absent"
    printf 'Meta%%2BShift%%2BS.100\n' > "$state_uid/orig_lxqt_meta_shift_s.section"
}

_run_lxqt_restore_paths() {
    local user="$1" state_uid="$2"
    restore_lxqt_shortcuts "$user" "$state_uid"
}

_run_lxqt_state_branch_paths() {
    local user="$1" conf="$2" scratch blocked max_file mv_conf
    scratch="$STATE_DIR/lxqt-branch-paths"
    blocked="$scratch/not-a-directory"
    mkdir -p "$scratch/no-backups" "$scratch/section-missing" "$scratch/markers"
    _soft_expect 1 _lxqt_atomic_write_file "$scratch/missing/value" value old
    _soft_expect 1 _lxqt_write_state_file "$scratch/missing/state" lxqt test
    _soft_expect 1 _lxqt_require_one_backup "$scratch/no-backups/value" missing
    : > "$scratch/section-missing/value"
    _soft_expect 1 _lxqt_require_one_backup "$scratch/section-missing/value" missing-section
    max_file="$scratch/max"
    printf '0\n' > "$max_file"
    _soft_expect 0 _lxqt_choose_section_id "$conf" XF86Display "$max_file" >/dev/null
    _soft_expect 0 _lxqt_seed_work_file "$scratch/missing.conf" "$scratch/empty-work"
    _soft_expect 0 _lxqt_restore_one "$user" "$conf" "$scratch/no-section"
    printf 'Missing.1\n' > "$scratch/no-backup.section"
    _soft_expect 0 _lxqt_restore_one "$user" "$conf" "$scratch/no-backup"
    mkdir -p "$scratch/markers/target_user.tmp"
    _soft_expect 1 _lxqt_write_markers "$scratch/markers" "$user"
    : > "$blocked"
    _soft_expect 1 _lxqt_prepare_configure_dirs "$user" "$conf" "$blocked/state"
    _soft_expect 1 _lxqt_atomic_write_conf "$user" "$scratch/missing/conf" "$conf"
    mv_conf="$scratch/mv-conf"
    mkdir -p "$mv_conf/$(basename "$mv_conf").tmp"
    _soft_expect 1 _lxqt_atomic_write_conf "$user" "$mv_conf" "$conf"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        LXQT_MKTEMP_COUNT_FILE="$scratch/mktemp-count" LXQT_MKTEMP_FAIL_CALL=2 \
        _lxqt_apply_all_bindings "$user" "$conf" "$scratch/no-backups"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        LXQT_MKTEMP_COUNT_FILE="$scratch/mktemp-count-three" LXQT_MKTEMP_FAIL_CALL=3 \
        _lxqt_apply_all_bindings "$user" "$conf" "$scratch/no-backups"
}

_run_lxqt_context_failure_paths() {
    local user="$1" conf="$2" scratch blocked_home readonly_conf
    scratch="$STATE_DIR/lxqt-context-failures"
    mkdir -p "$scratch"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 LXQT_GETENT_FAIL=1 \
        _lxqt_resolve_configure_context
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 LXQT_GETENT_FAIL=1 \
        restore_lxqt_shortcuts "$user" "$scratch"
    blocked_home="$scratch/blocked-home"
    : > "$blocked_home"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        LXQT_HOME_OVERRIDE="$blocked_home" _lxqt_ensure_conf_dir "$user"
    readonly_conf="$scratch/readonly.conf"
    : > "$readonly_conf"
    chmod 0444 "$readonly_conf"
    _soft_expect 1 _lxqt_prepare_configure_dirs "$user" "$readonly_conf" "$scratch/state"
    : > "$scratch/not-a-directory"
    _soft_expect 1 _lxqt_try_set_or_fail "$user" "$conf" "$scratch/not-a-directory/state"
}

_run_lxqt_restore_failure_path() {
    local user="$1" state_uid="$2"
    mkdir -p "$state_uid"
    : > "$state_uid/orig_lxqt_xf86display.section"
    _soft_expect 1 restore_lxqt_shortcuts "$user" "$state_uid"
}

_driver_set_prefix _LXQT_PREFIX_OWNED
_lxqt_rm_if_set() {
    [ -n "${1:-}" ] || return 0
    # Prefer absolute rm so cleanup still works after iso (which may provide rm) is deleted.
    /bin/rm -rf "$1"
}

_lxqt_driver_cleanup() {
    _lxqt_rm_if_set "${mock:-}"
    _lxqt_rm_if_set "${iso:-}"
    _lxqt_rm_if_set "${_LXQT_EMPTY_BUS:-}"
    _lxqt_rm_if_set "${_LXQT_HOME_ROOT:-}"
    if [ "${_LXQT_PREFIX_OWNED:-0}" = 1 ]; then
        _lxqt_rm_if_set "${PREFIX:-}"
    fi
}
trap '_lxqt_driver_cleanup' EXIT
BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
INSTALL_COMMAND_TIMEOUT=1
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER
uid="$(id -u)"
user="$(id -un)"
_LXQT_HOME_ROOT=$(mktemp -d)
home_dir="$_LXQT_HOME_ROOT/$user"
mkdir -p "$home_dir" "$STATE_DIR/$uid" "$BUS_ROOT/$uid"
_seed_lxqt_home_conf "$home_dir"
_driver_bind_required "$BUS_ROOT/$uid/bus" lxqt_helpers

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" lxqt_helpers quiet
# shellcheck source=lib/asus-session.sh
_driver_source_required "$REPO_ROOT/lib/asus-session.sh" lxqt_helpers quiet
# shellcheck source=lib/asus-i18n.sh
_driver_source_required "$REPO_ROOT/lib/asus-i18n.sh" lxqt_helpers quiet
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" lxqt_helpers quiet
# shellcheck source=lib/install-lxqt.sh
_driver_source_required "$REPO_ROOT/lib/install-lxqt.sh" lxqt_helpers quiet

mock=$(mktemp -d)
iso=$(mktemp -d)
_link_iso_tools "$iso"
    _link_iso_additional_tools "$iso" id mktemp mv basename getent cut cat awk
# Override getent so HOME resolves under the temp tree (not the real home).
cat > "$mock/getent" <<EOF
#!/bin/sh
[ "\${LXQT_GETENT_FAIL:-0}" = 1 ] && exit 1
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:%s:%s:%s::%s:/bin/bash\\n' "$user" x "$uid" "$uid" \
    "\${LXQT_HOME_OVERRIDE:-$home_dir}"
  exit 0
fi
if [ -x /usr/bin/getent ]; then
  exec /usr/bin/getent "\$@"
fi
exit 1
EOF
_write_lxqt_stubs "$mock" "$user"
PATH="$mock:$iso"
SUDO_CMD="$mock/sudo"
export PATH SUDO_CMD BUS_ROOT STATE_DIR PREFIX

_soft_expect 0 configure_lxqt_component
conf="${home_dir}/.config/lxqt/globalkeyshortcuts.conf"
_run_lxqt_state_branch_paths "$user" "$conf"
_run_lxqt_context_failure_paths "$user" "$conf"
_seed_lxqt_restore_state "$STATE_DIR/$uid"
_soft_expect 0 _run_lxqt_restore_paths "$user" "$STATE_DIR/$uid"
_run_lxqt_restore_failure_path "$user" "$STATE_DIR/$uid"

# Empty BUS_ROOT: real _resolve_user_bus_info finds no session bus socket.
_LXQT_EMPTY_BUS=$(mktemp -d)
BUS_ROOT="$_LXQT_EMPTY_BUS"
export BUS_ROOT
_soft_expect 1 configure_lxqt_component
/bin/rm -rf "$_LXQT_EMPTY_BUS"
unset _LXQT_EMPTY_BUS
BUS_ROOT="${DBUS_BUS_ROOT:-$PREFIX/run/user}"
export BUS_ROOT
mkdir -p "$BUS_ROOT/$uid"
_driver_bind_required "$BUS_ROOT/$uid/bus" lxqt_helpers

# Reload miss path: pkill always fails → warning only.
printf '#!/bin/sh\nexit 1\n' > "$mock/pkill"
chmod +x "$mock/pkill"
_seed_lxqt_home_conf "$home_dir"
_soft_expect 0 configure_lxqt_component

PATH="$iso"
_soft_expect 1 configure_lxqt_component
PATH="$mock:$iso"

trap - EXIT
_lxqt_driver_cleanup
