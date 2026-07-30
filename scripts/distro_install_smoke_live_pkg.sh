#!/usr/bin/env bash
# Sourced by run_distro_install_smoke.sh — live package mutation cycle (container only).
# Requires shared helpers: _smoke_log, _smoke_fail, _smoke_log_command, _SMOKE_PKG_LOG,
# _prepare_install_workspace, _assert_installed_wmi_assets, _assert_uninstalled,
# _assert_pkg_available, _pkg_is_installed.

_sentinel_pkgs_for_family() {
    local family="$1" pkg
    # Safe to remove/reinstall mid-pipeline (not required by remaining coverage).
    for pkg in xdotool ydotool; do
        _assert_pkg_available "$family" "$pkg" || continue
        printf '%s\n' "$pkg"
    done
}

_SMOKE_APT_GET_OPTS=(
    -o DPkg::Lock::Timeout=60 -o Acquire::Retries=2
    -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
)

_remove_pkg_debian() {
    local pkg="$1"
    _smoke_log_command "apt remove --purge $pkg" \
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \
        "${_SMOKE_APT_GET_OPTS[@]}" \
        remove -y --purge "$pkg" </dev/null
}

_remove_pkg_rpm() {
    local pkg="$1"
    if command -v dnf >/dev/null 2>&1; then
        _smoke_log_command "dnf remove $pkg" \
            sudo -n dnf -y remove "$pkg" </dev/null
        return $?
    fi
    _smoke_log_command "zypper remove $pkg" \
        sudo -n zypper --non-interactive remove -y "$pkg" </dev/null
}

_remove_pkg_arch() {
    local pkg="$1"
    _smoke_log_command "pacman remove $pkg" \
        sudo -n pacman -R --noconfirm "$pkg" </dev/null
}

_remove_pkg() {
    local family="$1" pkg="$2"
    case "$family" in
        debian) _remove_pkg_debian "$pkg" ;;
        redhat|suse) _remove_pkg_rpm "$pkg" ;;
        arch) _remove_pkg_arch "$pkg" ;;
        *) return 1 ;;
    esac
}

_purge_one_sentinel() {
    local family="$1" pkg="$2"
    if _pkg_is_installed "$family" "$pkg"; then
        _smoke_log "  removing preinstalled sentinel: $pkg"
        _remove_pkg "$family" "$pkg" || _smoke_fail "failed to remove sentinel package $pkg"
    fi
    _pkg_is_installed "$family" "$pkg" && _smoke_fail "sentinel $pkg still installed after remove"
    return 0
}

_purge_sentinels() {
    local family="$1" sentinel_list="$2" pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        _purge_one_sentinel "$family" "$pkg"
    done <<< "$sentinel_list"
}

_assert_sentinels_installed() {
    local family="$1" sentinel_list="$2" pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        _pkg_is_installed "$family" "$pkg" \
            || _smoke_fail "install.sh did not install sentinel package $pkg"
        _smoke_log "  ✓ install restored $pkg"
    done <<< "$sentinel_list"
}

_live_soft() { "$@" || return 0; }

_read_live_installed_packages_record() {
    local record="$1"
    # Live install runs under sudo, so DESTDIR state may be root-owned; read via
    # sudo when the smoke process cannot open the file.
    if [ -r "$record" ]; then
        cat "$record"
    elif sudo -n test -f "$record" 2>/dev/null; then
        sudo -n cat "$record"
    else
        _smoke_fail "missing installed-packages record at $record"
    fi
}

_assert_record_has_sentinels() {
    local record="$1" sentinel_list="$2" pkg record_body
    record_body="$(_read_live_installed_packages_record "$record")"
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        printf '%s\n' "$record_body" | grep -Fqx "$pkg" \
            || _smoke_fail "installed-packages missing newly installed $pkg"
    done <<< "$sentinel_list"
}

_assert_sentinels_removed() {
    local family="$1" sentinel_list="$2" pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        _pkg_is_installed "$family" "$pkg" \
            && _smoke_fail "uninstall left sentinel package $pkg installed"
        _smoke_log "  ✓ uninstall removed $pkg"
    done <<< "$sentinel_list"
}

_reinstall_pkg() {
    local family="$1" pkg="$2"
    case "$family" in
        debian)
            _smoke_log_command "apt install $pkg" \
                sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \
                "${_SMOKE_APT_GET_OPTS[@]}" \
                install -y "$pkg" </dev/null
            ;;
        redhat)
            _smoke_log_command "dnf install $pkg" \
                sudo -n dnf -y install "$pkg" </dev/null
            ;;
        suse)
            _smoke_log_command "zypper install $pkg" \
                sudo -n zypper --non-interactive install -y "$pkg" </dev/null
            ;;
        arch)
            _smoke_log_command "pacman install $pkg" \
                sudo -n pacman -S --noconfirm "$pkg" </dev/null
            ;;
        *) return 1 ;;
    esac
}

_restore_sentinels_best_effort() {
    local family="$1" sentinel_list="$2" pkg restore_rc=0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        _pkg_is_installed "$family" "$pkg" && continue
        _smoke_log "  restoring $pkg after smoke"
        _reinstall_pkg "$family" "$pkg" || restore_rc=1
    done <<< "$sentinel_list"
    return "$restore_rc"
}

_live_pkg_install() {
    local dest="$1" mock_bin="$2" bus_root="$3"
    sudo -n env PATH="$mock_bin:$PATH" \
        ASUS_TEST_MODE=1 \
        SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=0 SKIP_PKG_REMOVE=0 \
        INSTALL_COMMAND_TIMEOUT=120 INSTALL_ASSUME_UNIT_ACTIVE=1 \
        NONINTERACTIVE_CHOICE="WMI TOUCHPAD" \
        DESTDIR="$dest" DBUS_BUS_ROOT="$bus_root" \
        SYSTEMCTL_CMD="$mock_bin/systemctl" \
        ./install.sh
}

# Mirror flake retries for live install (zypper/dnf CDN resets).
_live_pkg_install_with_retry() {
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        if _live_pkg_install "$@"; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le 3 ] || break
        _smoke_log "  retrying live install.sh (attempt ${attempt}/3)"
        sleep 5
    done
    return 1
}

_live_pkg_uninstall() {
    local dest="$1" mock_bin="$2" bus_root="$3"
    sudo -n env PATH="$mock_bin:$PATH" \
        ASUS_TEST_MODE=1 \
        SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=0 SKIP_PKG_REMOVE=0 \
        INSTALL_COMMAND_TIMEOUT=120 \
        DESTDIR="$dest" DBUS_BUS_ROOT="$bus_root" \
        SYSTEMCTL_CMD="$mock_bin/systemctl" \
        ./uninstall.sh
}

_live_cycle_remove_tmp() {
    local tmp="$1"
    if [ -n "$tmp" ]; then
        sudo -n rm -rf "$tmp" || _live_soft rm -rf "$tmp"
    fi
}

_live_cycle_fail() {
    local family="$1" tmp="$2" msg="$3" sentinel_list="${4:-}" restore_rc=0
    _restore_sentinels_best_effort "$family" "$sentinel_list" || restore_rc=1
    _live_cycle_remove_tmp "$tmp"
    _LIVE_CYCLE_FAMILY=""
    _LIVE_CYCLE_TMP=""
    _LIVE_CYCLE_SENTINELS=""
    if [ "$restore_rc" -ne 0 ]; then
        _smoke_fail "failed to restore sentinel packages after smoke error ($msg)"
    fi
    _smoke_fail "$msg"
}

_LIVE_CYCLE_FAMILY=""
_LIVE_CYCLE_TMP=""
_LIVE_CYCLE_SENTINELS=""
_LIVE_CYCLE_SAVED_EXIT_TRAP=""

_live_cycle_restore_sentinels_on_exit() {
    local restore_rc=0
    if [ -n "$_LIVE_CYCLE_FAMILY" ]; then
        if ! _restore_sentinels_best_effort "$_LIVE_CYCLE_FAMILY" "$_LIVE_CYCLE_SENTINELS"; then
            restore_rc=1
            _smoke_log "Warning: failed to restore sentinel packages during live-cycle cleanup" >&2
        fi
    fi
    return "$restore_rc"
}

_live_cycle_remove_tmp_on_exit() {
    if [ -n "$_LIVE_CYCLE_TMP" ]; then
        if [ -n "$_LIVE_CYCLE_FAMILY" ]; then
            sudo -n rm -rf "$_LIVE_CYCLE_TMP" || _live_soft rm -rf "$_LIVE_CYCLE_TMP"
        else
            _live_soft rm -rf "$_LIVE_CYCLE_TMP"
        fi
    fi
}

_live_cycle_restore_prior_exit_trap() {
    local saved_trap="$1" saved_body=""
    [ -n "$saved_trap" ] || return 0
    # Run prior EXIT body first; re-eval of trap -p only reinstalls.
    if [[ $saved_trap =~ ^trap\ --\ \'(.*)\'\ EXIT$ ]]; then
        saved_body="${BASH_REMATCH[1]}"
        eval "$saved_body"
    fi
    eval "$saved_trap"
}

_live_cycle_trap_cleanup() {
    local restore_rc=0 saved_trap=""
    _live_cycle_restore_sentinels_on_exit || restore_rc=1
    _live_cycle_remove_tmp_on_exit
    _LIVE_CYCLE_FAMILY=""
    _LIVE_CYCLE_TMP=""
    _LIVE_CYCLE_SENTINELS=""
    saved_trap="$_LIVE_CYCLE_SAVED_EXIT_TRAP"
    _LIVE_CYCLE_SAVED_EXIT_TRAP=""
    _live_cycle_restore_prior_exit_trap "$saved_trap"
    return "$restore_rc"
}

_live_cycle_require_sudo_and_sentinels() {
    local sentinel_list="$1"
    sudo -n true >/dev/null 2>&1 \
        || _smoke_fail "container smoke needs passwordless sudo for live package install/remove"
    [ -n "$sentinel_list" ] \
        || _smoke_fail "no sentinel packages available for live install/remove"
}

_live_cycle_install_phase() {
    local family="$1" tmp="$2" dest="$3" mock_bin="$4" bus_root="$5" record="$6" sentinel_list="$7"
    _purge_sentinels "$family" "$sentinel_list"
    _live_pkg_install_with_retry "$dest" "$mock_bin" "$bus_root" \
        || _live_cycle_fail "$family" "$tmp" "install.sh failed (live package cycle)" \
            "$sentinel_list"
    _assert_installed_wmi_assets "$dest" \
        || _live_cycle_fail "$family" "$tmp" "install assets missing (live package cycle)" \
            "$sentinel_list"
    _assert_sentinels_installed "$family" "$sentinel_list"
    _assert_record_has_sentinels "$record" "$sentinel_list"
}

_live_cycle_uninstall_phase() {
    local family="$1" tmp="$2" dest="$3" mock_bin="$4" bus_root="$5" sentinel_list="$6"
    _live_pkg_uninstall "$dest" "$mock_bin" "$bus_root" \
        || _live_cycle_fail "$family" "$tmp" "uninstall.sh failed (live package cycle)" \
            "$sentinel_list"
    _assert_uninstalled "$dest"
    _assert_sentinels_removed "$family" "$sentinel_list"
}

_run_live_pkg_install_uninstall_cycle() {
    local family="$1" tmp dest mock_bin bus_root record sentinel_list
    sentinel_list=$(_sentinel_pkgs_for_family "$family")
    if [ -z "$sentinel_list" ]; then
        # Rocky/Alma (and similar) may lack xdotool/ydotool RPMs entirely.
        _smoke_log "Skipping live package mutation (no xdotool/ydotool packaged here)"
        return 0
    fi
    _live_cycle_require_sudo_and_sentinels "$sentinel_list"
    tmp=$(mktemp -d)
    _LIVE_CYCLE_FAMILY="$family"
    _LIVE_CYCLE_TMP="$tmp"
    _LIVE_CYCLE_SENTINELS="$sentinel_list"
    _LIVE_CYCLE_SAVED_EXIT_TRAP=$(trap -p EXIT || true)
    trap '_live_cycle_trap_cleanup' EXIT
    _prepare_install_workspace "$tmp"
    dest="$tmp/dest"
    mock_bin="$tmp/bin"
    bus_root="$tmp/bus"
    record="$dest/var/lib/asus-zenbook-linux-tools/installed-packages"
    _smoke_log "Live package cycle: purge sentinels, then real install.sh/uninstall.sh"
    _live_cycle_install_phase "$family" "$tmp" "$dest" "$mock_bin" "$bus_root" "$record" \
        "$sentinel_list"
    _live_cycle_uninstall_phase "$family" "$tmp" "$dest" "$mock_bin" "$bus_root" \
        "$sentinel_list"
    trap - EXIT
    _live_cycle_trap_cleanup || _smoke_fail "failed to restore sentinel packages after smoke"
    _smoke_log "live package install/uninstall cycle passed"
}
