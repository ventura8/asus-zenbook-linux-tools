#!/usr/bin/env bash
# kcov driver: exercise lib/install-components.sh helpers as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

# shellcheck source=lib/install-shared.sh
_driver_source_required "$REPO_ROOT/lib/install-shared.sh" components_helpers
# shellcheck source=lib/install-gnome.sh
_driver_source_required "$REPO_ROOT/lib/install-gnome.sh" components_helpers
# shellcheck source=lib/install-kde.sh
_driver_source_required "$REPO_ROOT/lib/install-kde.sh" components_helpers
# shellcheck source=lib/install-xfce.sh
_driver_source_required "$REPO_ROOT/lib/install-xfce.sh" components_helpers
# shellcheck source=lib/install-lxqt.sh
_driver_source_required "$REPO_ROOT/lib/install-lxqt.sh" components_helpers
# shellcheck source=lib/install-cinnamon.sh
_driver_source_required "$REPO_ROOT/lib/install-cinnamon.sh" components_helpers
# shellcheck source=lib/install-mate.sh
_driver_source_required "$REPO_ROOT/lib/install-mate.sh" components_helpers
# shellcheck source=lib/install-components.sh
_driver_source_required "$REPO_ROOT/lib/install-components.sh" components_helpers

PREFIX="${DESTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/asus-kcov-comp.XXXXXX")}"
_COMP_PREFIX_OWNED=0
_COMP_OWNED_PREFIX_PATH=""
if [ -z "${DESTDIR:-}" ]; then
    _COMP_PREFIX_OWNED=1
    _COMP_OWNED_PREFIX_PATH="$PREFIX"
    trap 'if [ "${_COMP_PREFIX_OWNED:-0}" = 1 ]; then rm -rf "${_COMP_OWNED_PREFIX_PATH:-}"; fi' EXIT
fi
BIN_DIR="${PREFIX}/usr/local/bin"
LIB_DIR="${PREFIX}/usr/local/lib/asus-zenbook-linux-tools"
SYS_DIR="${PREFIX}/etc/systemd/system"
HOOK_DIR="${PREFIX}/lib/systemd/system-sleep"
SYSTEMCTL="${SYSTEMCTL_CMD:-true}"
BUS_ROOT="${BUS_ROOT:-${DBUS_BUS_ROOT:-${RUN_USER_ROOT:-$PREFIX/run/user}}}"
SUDO_CMD="${SUDO_CMD:-true}"
STRICT_COMPONENTS="${INSTALL_STRICT_COMPONENTS:-0}"
INSTALL_COMMAND_TIMEOUT="${INSTALL_COMMAND_TIMEOUT:-1}"
INSTALL_SKIP_TIMEOUT_WRAPPER=1
export STRICT_COMPONENTS INSTALL_COMMAND_TIMEOUT INSTALL_SKIP_TIMEOUT_WRAPPER
mkdir -p "$BIN_DIR" "$SYS_DIR" "$HOOK_DIR" "$LIB_DIR" "$BUS_ROOT"

_run_component_predicates() {
    _exercise _should_use_strict_component_mode 0 >/dev/null
    _exercise STRICT_COMPONENTS=1 _should_use_strict_component_mode 0 >/dev/null
    _exercise _verify_unit_state_after_action 1 "x.service" disable >/dev/null
    _exercise _is_component_selected "WMI SOUND" WMI >/dev/null
    _exercise _is_component_selected "WMI" SOUND >/dev/null
    _exercise create_suspend_hook >/dev/null
    _exercise rollback_sound_component >/dev/null
    _exercise INSTALL_ASSUME_UNIT_ACTIVE=0 _report_wmi_unit_result >/dev/null
    _exercise _copy_install_file "/missing-asus-src" "$BIN_DIR/" >/dev/null
}

_run_unit_ops() {
    _exercise _run_unit_management_ops_common "asus-hotkey-daemon.service" restart >/dev/null
    _exercise _run_unit_management_ops_unverified "asus-hotkey-daemon.service" restart >/dev/null
    _exercise INSTALL_ASSUME_UNIT_ACTIVE=1 _is_systemd_unit_active "asus-hotkey-daemon.service" >/dev/null
}

_run_fail_systemctl_ops() {
    [ -n "${KCOV_FAIL_SYSTEMCTL:-}" ] || return 0
    local saved_systemctl="${SYSTEMCTL:-}"
    SYSTEMCTL="$KCOV_FAIL_SYSTEMCTL"
    _exercise _run_unit_management_ops_common "asus-hotkey-daemon.service" restart >/dev/null
    _exercise _install_unit "$REPO_ROOT" "asus-hotkey-daemon.service" restart 1 >/dev/null
    SYSTEMCTL="$saved_systemctl"
}

_run_component_deploys() {
    _exercise deploy_wmi_component "$REPO_ROOT" >/dev/null
    _exercise deploy_touchpad_component "$REPO_ROOT" >/dev/null
    _exercise deploy_sound_component "$REPO_ROOT" >/dev/null
    _exercise INSTALL_ASSUME_UNIT_ACTIVE=0 SYSTEMCTL="${KCOV_FAIL_SYSTEMCTL:-$SYSTEMCTL}" \
        deploy_wmi_component "$REPO_ROOT" >/dev/null
    _exercise _install_unit "/missing-src" "asus-hotkey-daemon.service" restart 0 >/dev/null
    _exercise run_installer_selected_components "WMI" "$REPO_ROOT" >/dev/null
    _exercise run_installer_selected_components "" "$REPO_ROOT" >/dev/null
    _exercise _deploy_selected_component DESKTOP "$REPO_ROOT" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=kde _deploy_selected_component DESKTOP "$REPO_ROOT" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=xfce _deploy_selected_component DESKTOP "$REPO_ROOT" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=lxqt _deploy_selected_component DESKTOP "$REPO_ROOT" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=cinnamon _deploy_selected_component DESKTOP "$REPO_ROOT" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=mate _deploy_selected_component DESKTOP "$REPO_ROOT" >/dev/null
}

_run_sound_failure_paths() {
    (
        local sys_tmp
        sys_tmp=$(mktemp -d)
        trap 'rm -rf "$sys_tmp"' EXIT
        cat > "$sys_tmp/systemctl-soundfail" <<'EOF'
#!/bin/sh
if [ "$1" = "enable" ] || [ "$1" = "daemon-reload" ]; then
    exit 1
fi
exit 0
EOF
        chmod +x "$sys_tmp/systemctl-soundfail"
        _exercise SYSTEMCTL="$sys_tmp/systemctl-soundfail" deploy_sound_component "$REPO_ROOT" >/dev/null
        cat > "$sys_tmp/systemctl-ok" <<'EOF'
#!/bin/sh
exit 0
EOF
        chmod +x "$sys_tmp/systemctl-ok"
        _exercise SYSTEMCTL="$sys_tmp/systemctl-ok" SOUND_FIX_PROBE_TIMEOUT=1 \
            DEV_SND_ROOT=/missing PROC_ASOUND_ROOT=/missing \
            deploy_sound_component "$REPO_ROOT" >/dev/null
    )
}

_comp_var_was_exported() {
    local decl
    decl=$(declare -p "$1" 2>/dev/null) || return 1
    [[ "$decl" =~ ^declare\ -[A-Za-z]*x ]]
}

_comp_restore_env_var() {
    # Restore saved value; unexport when it was not originally exported.
    local name="$1" was_exported="$2" saved_ref="$3"
    if [ -n "${!saved_ref+set}" ]; then
        printf -v "$name" '%s' "${!saved_ref}"
    else
        unset "$name"
    fi
    if [ "$was_exported" != 1 ]; then
        # ${name?} keeps shellcheck SC2163 quiet for dynamic unexport.
        _soft export -n "${name?}" 2>/dev/null
    fi
}

_comp_save_env_var() {
    # Save value into _COMP_SAVED_<suffix>; set _COMP_HAD_<suffix>=1 if exported.
    # Args: var_name had_suffix saved_suffix
    local var_name="$1" had_name="$2" saved_name="$3"
    printf -v "$had_name" '%s' 0
    unset "$saved_name"
    if [ -n "${!var_name+set}" ]; then
        printf -v "$saved_name" '%s' "${!var_name}"
        if _comp_var_was_exported "$var_name"; then
            printf -v "$had_name" '%s' 1
        fi
    fi
}

_comp_restore_kde_xfce_env() {
    PATH="${_COMP_SAVED_PATH:-$PATH}"
    _comp_restore_env_var STATE_DIR "${_COMP_HAD_STATE_DIR:-0}" _COMP_SAVED_STATE_DIR
    _comp_restore_env_var PREFIX "${_COMP_HAD_PREFIX:-0}" _COMP_SAVED_PREFIX
    _comp_restore_env_var SUDO_CMD "${_COMP_HAD_SUDO:-0}" _COMP_SAVED_SUDO
    _comp_restore_env_var BUS_ROOT "${_COMP_HAD_BUS:-0}" _COMP_SAVED_BUS
    if [ -n "${_COMP_KDE_XFCE_TMP:-}" ]; then
        rm -rf "$_COMP_KDE_XFCE_TMP"
    fi
    unset _COMP_KDE_XFCE_TMP _COMP_SAVED_PATH _COMP_SAVED_STATE_DIR _COMP_SAVED_PREFIX \
        _COMP_SAVED_SUDO _COMP_SAVED_BUS _COMP_HAD_STATE_DIR _COMP_HAD_PREFIX \
        _COMP_HAD_SUDO _COMP_HAD_BUS
}

_run_kde_xfce_direct() {
    local mock uid user path_prefix
    _COMP_SAVED_PATH="$PATH"
    _comp_save_env_var STATE_DIR _COMP_HAD_STATE_DIR _COMP_SAVED_STATE_DIR
    _comp_save_env_var PREFIX _COMP_HAD_PREFIX _COMP_SAVED_PREFIX
    _comp_save_env_var SUDO_CMD _COMP_HAD_SUDO _COMP_SAVED_SUDO
    _comp_save_env_var BUS_ROOT _COMP_HAD_BUS _COMP_SAVED_BUS
    path_prefix="$_COMP_SAVED_PATH"
    # Non-local so RETURN/EXIT cleanup stays valid under set -u after locals end.
    # STATE_DIR/SUDO_CMD must remain in the surrounding environment for later helpers.
    _COMP_KDE_XFCE_TMP=$(mktemp -d)
    trap '_comp_restore_kde_xfce_env' RETURN
    mock="$_COMP_KDE_XFCE_TMP/bin"
    uid="$(id -u)"
    user="$(id -un)"
    STATE_DIR="$_COMP_KDE_XFCE_TMP/state"
    mkdir -p "$mock" "$STATE_DIR/$uid" "$PREFIX/usr/local/share/applications"
    printf '#!/bin/sh\nexit 0\n' > "$mock/kwriteconfig6"
    printf '#!/bin/sh\nexit 0\n' > "$mock/qdbus"
    printf '#!/bin/sh\nexit 0\n' > "$mock/pkill"
    # Get → exit 1 (absent); set/create/remove → exit 0 so configure can apply bindings.
    cat > "$mock/xfconf-query" <<'EOF'
#!/bin/sh
case " $* " in
    *" -s "*|*" -n "*|*" -r "*) exit 0 ;;
esac
exit 1
EOF
    _write_sudo_stub "$mock"
    cat > "$mock/getent" <<EOF
#!/bin/sh
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s\\n' "$user:x:$uid:$uid::$_COMP_KDE_XFCE_TMP/home:/bin/bash"
  exit 0
fi
if [ -x /usr/bin/getent ]; then
  exec /usr/bin/getent "\$@"
fi
exit 1
EOF
    mkdir -p "$_COMP_KDE_XFCE_TMP/home"
    chmod +x "$mock"/*
    PATH="$mock:$path_prefix"
    SUDO_CMD="$mock/sudo"
    export PATH STATE_DIR PREFIX SUDO_CMD BUS_ROOT
    mkdir -p "$BUS_ROOT/$uid"
    if ! _bind_unix_socket_path "$BUS_ROOT/$uid/bus"; then
        echo "components_helpers: failed to bind session bus socket" >&2
        return 1
    fi
    _exercise configure_kde_component >/dev/null
    _exercise restore_kde_shortcuts "$user" "$STATE_DIR/$uid" >/dev/null
    _exercise configure_xfce_component >/dev/null
    mkdir -p "$STATE_DIR/$uid"
    : > "$STATE_DIR/$uid/orig_xfce_xf86display.absent"
    printf '/usr/bin/true\n' > "$STATE_DIR/$uid/orig_xfce_super_f12"
    printf '/usr/bin/true\n' > "$STATE_DIR/$uid/orig_xfce_super_shift_s"
    _exercise restore_xfce_shortcuts "$user" "$STATE_DIR/$uid" >/dev/null
    _exercise configure_lxqt_component >/dev/null
    mkdir -p "$STATE_DIR/$uid"
    : > "$STATE_DIR/$uid/orig_lxqt_xf86display.absent"
    printf 'XF86Display.1\n' > "$STATE_DIR/$uid/orig_lxqt_xf86display.section"
    : > "$STATE_DIR/$uid/orig_lxqt_meta_p.absent"
    printf 'Meta%%2BP.4\n' > "$STATE_DIR/$uid/orig_lxqt_meta_p.section"
    : > "$STATE_DIR/$uid/orig_lxqt_meta_f12.absent"
    printf 'Meta%%2BF12.2\n' > "$STATE_DIR/$uid/orig_lxqt_meta_f12.section"
    : > "$STATE_DIR/$uid/orig_lxqt_meta_shift_s.absent"
    printf 'Meta%%2BShift%%2BS.3\n' > "$STATE_DIR/$uid/orig_lxqt_meta_shift_s.section"
    _exercise restore_lxqt_shortcuts "$user" "$STATE_DIR/$uid" >/dev/null
    trap - RETURN
    _comp_restore_kde_xfce_env
}

_run_uinput_locale_ydotool_exercises() {
    local mock saved_prefix saved_path saved_state saved_destdir saved_destdir_was_set \
        saved_destdir_was_exported uid user
    uid="$(id -u)"
    user="$(id -un)"
    mock=$(mktemp -d)
    trap 'rm -rf "$mock"; PREFIX="$saved_prefix"; PATH="$saved_path"; STATE_DIR="$saved_state"; \
        if [ "$saved_destdir_was_set" = 1 ]; then \
            DESTDIR="$saved_destdir"; \
            if [ "$saved_destdir_was_exported" = 1 ]; then export DESTDIR; fi; \
        else \
            unset DESTDIR; \
        fi; \
        trap - RETURN' RETURN
    saved_prefix="${PREFIX:-}"
    saved_path="$PATH"
    saved_state="${STATE_DIR:-}"
    if [ -n "${DESTDIR+x}" ]; then
        saved_destdir="$DESTDIR"
        saved_destdir_was_set=1
        saved_destdir_was_exported=0
        case "$(declare -p DESTDIR 2>/dev/null)" in
            "declare -x "*) saved_destdir_was_exported=1 ;;
        esac
    else
        saved_destdir=""
        saved_destdir_was_set=0
        saved_destdir_was_exported=0
    fi
    cat > "$mock/getent" <<EOF
#!/bin/sh
if [ "\$1" = "group" ] && [ "\$2" = "asus-uinput" ]; then
  printf '%s\\n' "asus-uinput:x:4242:$user"
  exit 0
fi
if [ "\$1" = "passwd" ]; then
  exec /usr/bin/getent "\$@"
fi
exit 1
EOF
    cat > "$mock/id" <<EOF
#!/bin/sh
if [ "\$1" = "-nG" ]; then
  printf '%s\\n' "$user asus-uinput"
  exit 0
fi
exec /usr/bin/id "\$@"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$mock/groupadd"
    printf '#!/bin/sh\nexit 0\n' > "$mock/usermod"
    printf '#!/bin/sh\nexit 1\n' > "$mock/gpasswd"
    printf '#!/bin/sh\nexit 0\n' > "$mock/udevadm"
    chmod +x "$mock"/*
    PATH="$mock:$saved_path"
    STATE_DIR="$mock/state"
    mkdir -p "$STATE_DIR"
    # PREFIX empty → real uinput group/udev branches (mocked commands).
    PREFIX=""
    export PREFIX STATE_DIR PATH
    _exercise _resolve_ydotool_session_user >/dev/null
    _exercise _uinput_group_users_record_path >/dev/null
    _exercise _legacy_input_group_users_record_path >/dev/null
    _exercise _record_uinput_group_user "" >/dev/null
    _exercise _record_uinput_group_user "$user" >/dev/null
    _exercise _record_uinput_group_user "$user" >/dev/null
    _exercise _user_in_exact_group "$user" asus-uinput >/dev/null
    _exercise _user_in_exact_group "$user" nosuchgroup >/dev/null
    _exercise _uinput_revoke_record_ready "$STATE_DIR/missing" asus-uinput >/dev/null
    printf '%s\n' "$user" > "$STATE_DIR/asus-uinput-group-users"
    _exercise _revoke_one_uinput_group_member "" asus-uinput >/dev/null
    _exercise _revoke_one_uinput_group_member "$user" asus-uinput >/dev/null
    _exercise revoke_uinput_group_members >/dev/null
    _exercise revoke_input_group_members >/dev/null
    _exercise _resolve_uinput_rule_source "$REPO_ROOT" >/dev/null
    _exercise _ensure_uinput_group >/dev/null
    _exercise _reload_uinput_udev_rule >/dev/null
    _exercise _install_uinput_udev_rule "$REPO_ROOT" >/dev/null
    _exercise _install_uinput_udev_rule "/missing-src" >/dev/null
    _exercise _uinput_user_can_be_added "" >/dev/null
    _exercise _uinput_user_can_be_added "$user" >/dev/null
    _exercise _add_user_to_uinput_group "$user" >/dev/null
    # Force "already in group" short-circuit then usermod-success path with empty group membership.
    cat > "$mock/id" <<EOF
#!/bin/sh
if [ "\$1" = "-nG" ]; then
  printf '%s\\n' "$user"
  exit 0
fi
exec /usr/bin/id "\$@"
EOF
    chmod +x "$mock/id"
    printf '#!/bin/sh\nexit 0\n' > "$mock/usermod"
    _exercise _add_user_to_uinput_group "$user" >/dev/null
    printf '#!/bin/sh\nexit 1\n' > "$mock/usermod"
    _exercise _add_user_to_uinput_group "$user" >/dev/null
    printf '#!/bin/sh\nexit 1\n' > "$mock/groupadd"
    _exercise _ensure_uinput_group >/dev/null
    _exercise INSTALL_ASSUME_UNIT_ACTIVE=1 _report_wmi_unit_result >/dev/null
    _exercise INSTALL_ASSUME_UNIT_ACTIVE=0 _report_wmi_unit_result >/dev/null
    _exercise _run_unit_management_ops_unverified "asus-hotkey-daemon.service" restart >/dev/null
    # Missing units helper path (sibling file absent beside a temp copy).
    units_tmp=$(mktemp -d)
    cat > "$units_tmp/install-components.sh" <<'EOF'
_source_install_component_unit_helpers() {
    local helper_dir helper
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    helper="$helper_dir/install-components-units.sh"
    if [ ! -f "$helper" ]; then
        echo "Missing installer unit helper: $helper" >&2
        return 1
    fi
    . "$helper"
}
_source_install_component_unit_helpers
EOF
    _exercise bash "$units_tmp/install-components.sh" >/dev/null
    rm -rf "$units_tmp"
    _exercise _soft_systemctl is-active ydotool.service >/dev/null
    _exercise _systemd_system_unit_exists ydotool.service >/dev/null
    _exercise _enable_ydotool_system_units >/dev/null
    _exercise _enable_ydotoold_if_available >/dev/null
    mkdir -p "$BUS_ROOT/$uid"
    _soft _bind_unix_socket_path "$BUS_ROOT/$uid/bus"
    _exercise _enable_ydotool_user_unit "$user" >/dev/null
    # Locale helpers with a tiny catalog tree (avoid full 99-language compile).
    PREFIX="$saved_prefix"
    export PREFIX
    mkdir -p "$mock/po" "$mock/locale/jw/LC_MESSAGES"
    printf 'en\n' > "$mock/po/SUPPORTED_LANGUAGES"
    cp "$REPO_ROOT/po/en.po" "$mock/po/en.po"
    _exercise _require_locale_build_inputs "$mock" >/dev/null
    _exercise _compile_one_locale_catalog "$mock/po/en.po" "$mock/locale" >/dev/null
    : > "$mock/locale/jw/LC_MESSAGES/asus-zenbook-linux-tools.mo"
    _exercise _install_javanese_locale_alias "$mock/locale" >/dev/null
    _exercise PATH="/nonexistent:$PATH" _require_locale_build_inputs "$mock" >/dev/null
    _exercise _require_locale_build_inputs "$mock/missing" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=other configure_desktop_component >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=gnome configure_desktop_component >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=kde configure_desktop_component >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=xfce configure_desktop_component >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=lxqt configure_desktop_component >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=cinnamon configure_desktop_component >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=mate configure_desktop_component >/dev/null
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[kde]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[xfce]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[lxqt]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[cinnamon]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[mate]}"
    # uinput group/udev paths require a non-staged install: _asus_is_staged_install
    # treats a nonempty DESTDIR as staged regardless of PREFIX, and the caller
    # (kcov-install-scenarios.sh) always passes a nonempty DESTDIR, so it must be
    # unset here (not just PREFIX) to reach the real getent/groupadd/udevadm branches.
    unset DESTDIR
    PREFIX=""
    export PREFIX
    printf '#!/bin/sh\nexit 0\n' > "$mock/ydotool"
    chmod +x "$mock/ydotool"
    # _reload_uinput_udev_rule real branch (not staged, udevadm present).
    _exercise _reload_uinput_udev_rule >/dev/null
    # _install_uinput_udev_rule full success path (writable PREFIX so mkdir/cp
    # succeed and it reaches _reload_uinput_udev_rule + its own return 0).
    _exercise PREFIX="$mock/hostprefix" _install_uinput_udev_rule "$REPO_ROOT" >/dev/null
    # _enable_ydotoold_if_available past its `command -v ydotool` guard.
    _exercise PREFIX="$mock/hostprefix" _enable_ydotoold_if_available >/dev/null
    # groupadd failure when group is absent.
    cat > "$mock/getent" <<'EOF'
#!/bin/sh
if [ "$1" = "group" ] && [ "$2" = "asus-uinput" ]; then
  exit 1
fi
if [ "$1" = "passwd" ]; then
  exec /usr/bin/getent "$@"
fi
exit 1
EOF
    printf '#!/bin/sh\nexit 1\n' > "$mock/groupadd"
    _exercise _ensure_uinput_group >/dev/null
    # groupadd success when group is absent.
    printf '#!/bin/sh\nexit 0\n' > "$mock/groupadd"
    _exercise _ensure_uinput_group >/dev/null
    # Revoke record ready when group is missing (drops record).
    printf '%s\n' "$user" > "$STATE_DIR/asus-uinput-group-users"
    _exercise _uinput_revoke_record_ready \
        "$STATE_DIR/asus-uinput-group-users" asus-uinput >/dev/null
    # Restore group present for later usermod paths.
    cat > "$mock/getent" <<EOF
#!/bin/sh
if [ "\$1" = "group" ] && [ "\$2" = "asus-uinput" ]; then
  printf '%s\\n' "asus-uinput:x:4242:$user"
  exit 0
fi
if [ "\$1" = "passwd" ]; then
  exec /usr/bin/getent "\$@"
fi
exit 1
EOF
    cat > "$mock/id" <<EOF
#!/bin/sh
if [ "\$1" = "-nG" ]; then
  printf '%s\\n' "$user"
  exit 0
fi
exec /usr/bin/id "\$@"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$mock/usermod"
    _exercise _add_user_to_uinput_group "$user" >/dev/null
    printf '#!/bin/sh\nexit 1\n' > "$mock/usermod"
    _exercise _add_user_to_uinput_group "$user" >/dev/null
    # Successful revoke clears record (lines 115/117).
    printf '#!/bin/sh\nexit 0\n' > "$mock/gpasswd"
    printf '%s\n' "$user" > "$STATE_DIR/asus-uinput-group-users"
    cat > "$mock/id" <<EOF
#!/bin/sh
if [ "\$1" = "-nG" ]; then
  printf '%s\\n' "$user asus-uinput"
  exit 0
fi
exec /usr/bin/id "\$@"
EOF
    _exercise revoke_uinput_group_members >/dev/null
    # ydotoold / ydotool system unit enable branches.
    mkdir -p "$mock/systemd"
    touch "$mock/systemd/ydotoold.service" "$mock/systemd/ydotool.service"
    _comp_saved_unit_exists=$(declare -f _systemd_system_unit_exists)
    _systemd_system_unit_exists() {
        [ -f "$mock/systemd/$1" ]
    }
    _exercise _enable_ydotool_system_units >/dev/null
    eval "$_comp_saved_unit_exists"
    unset _comp_saved_unit_exists
    # Missing unit helper sibling on the live product file path.
    (
        units="$REPO_ROOT/lib/install-components-units.sh"
        mv "$units" "$units.__kcov_hide"
        trap 'mv "$units.__kcov_hide" "$units"' EXIT
        _soft _source_install_component_unit_helpers
    )
    # Touchpad / sound report helpers (force inactive via non-printing systemctl).
    _exercise SYSTEMCTL=/bin/true INSTALL_ASSUME_UNIT_ACTIVE=1 \
        _report_touchpad_unit_result >/dev/null
    _exercise SYSTEMCTL=/bin/true INSTALL_ASSUME_UNIT_ACTIVE=0 \
        _report_touchpad_unit_result >/dev/null
    _exercise _sound_activation_failed >/dev/null
    _exercise SYSTEMCTL=/bin/false _enable_sound_service_or_rollback \
        "$mock/sound-enable.log" >/dev/null
    printf 'sound enable failed\n' > "$mock/sound-enable.log"
    _exercise SYSTEMCTL=/bin/false _enable_sound_service_or_rollback \
        "$mock/sound-enable.log" >/dev/null
    _exercise BIN_DIR="$mock/missing-bin" _probe_sound_fix_or_rollback 1 \
        >/dev/null
    _exercise SYSTEMCTL=/bin/true _activate_sound_component 1 >/dev/null
    mkdir -p "$mock/notmp"
    chmod a-w "$mock/notmp"
    _exercise SYSTEMCTL=/bin/true TMPDIR="$mock/notmp" \
        _activate_sound_component 1 >/dev/null
    chmod u+w "$mock/notmp"
    printf 'nonzero sound log\n' > "$mock/sound.log"
    _exercise _print_nonempty_sound_log "$mock/sound.log" >/dev/null
    _exercise _deploy_selected_component BOGUS "$REPO_ROOT" >/dev/null
    # msgfmt missing + missing po file.
    _exercise PATH="/nonexistent" _require_locale_build_inputs "$mock" >/dev/null
    printf 'zz\n' > "$mock/po/SUPPORTED_LANGUAGES"
    _exercise _compile_supported_locale_catalogs "$mock" "$mock/locale" >/dev/null
    # Force msgfmt failure on bad po.
    printf 'broken\n' > "$mock/po/en.po"
    printf 'en\n' > "$mock/po/SUPPORTED_LANGUAGES"
    _exercise _compile_one_locale_catalog "$mock/po/en.po" "$mock/locale" >/dev/null
    _exercise TMPDIR="$mock/notmp" _soft_systemctl is-active ydotool.service >/dev/null
    PREFIX="$saved_prefix"
    export PREFIX
    _exercise _remove_sound_suspend_hook >/dev/null
    _exercise _print_nonempty_sound_log /missing-log >/dev/null
    _exercise _deploy_locale_catalogs "$mock" >/dev/null
    # ydotoold unit exists path.
    _exercise _enable_ydotool_system_units >/dev/null
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[kde]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[xfce]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[lxqt]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[cinnamon]}"
    : "${_DESKTOP_CONFIGURE_FN_BY_FAMILY[mate]}"
    _exercise _copy_install_relpaths "$REPO_ROOT" "$BIN_DIR" \
        "bin/asus-fan-toggle.sh" >/dev/null
    _exercise _chmod_sound_bins >/dev/null
    _exercise _deploy_wmi_binaries "$REPO_ROOT" >/dev/null
    _exercise _deploy_wmi_icon_assets "$REPO_ROOT" >/dev/null
    _exercise _deploy_wmi_static_assets "$REPO_ROOT" >/dev/null
    _exercise _enable_sound_service >/dev/null
}

_run_component_predicates
_run_unit_ops
_run_fail_systemctl_ops
_run_component_deploys
_run_sound_failure_paths
_run_kde_xfce_direct
_run_uinput_locale_ydotool_exercises
