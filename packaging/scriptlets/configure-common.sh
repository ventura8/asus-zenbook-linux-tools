#!/bin/bash
# Shared post-install configure helpers for RPM and Arch package scriptlets.
set -e

# Deb/RPM stage under /usr/sbin; Arch PKGBUILD relocates to /usr/bin (filesystem
# owns /usr/sbin). Resolve at runtime so scriptlets stay shared.
CONFIGURE_BIN="/usr/sbin/asus-zenbook-configure"
STATE_DIR="/var/lib/asus-zenbook-linux-tools"

_asus_resolve_configure_bin() {
    if [ -x "$CONFIGURE_BIN" ]; then
        return 0
    fi
    if [ -x /usr/bin/asus-zenbook-configure ]; then
        CONFIGURE_BIN=/usr/bin/asus-zenbook-configure
        return 0
    fi
    return 1
}

_asus_is_noninteractive_frontend() {
    case "${DEBIAN_FRONTEND:-}${RPM_INSTALL_PREFIX:-}" in
        *noninteractive*)
            return 0
            ;;
    esac
    case "${CI:-}" in true|1) return 0 ;; esac
    case "${GITHUB_ACTIONS:-}" in true|1) return 0 ;; esac
    return 1
}

_asus_can_use_tty() {
    [ -t 0 ] && [ -t 1 ]
}

_asus_print_reconfigure_hint() {
    echo "ASUS ZenBook Linux Tools files are installed."
    echo "Configure components interactively with:"
    echo "  sudo asus-zenbook-configure"
}

_asus_systemd_is_live() {
    local state
    command -v systemctl >/dev/null 2>&1 || return 1
    state=$(systemctl is-system-running 2>/dev/null || true)
    case "$state" in
        running|degraded|starting|maintenance)
            return 0
            ;;
    esac
    return 1
}

_asus_daemon_reload_if_live() {
    if ! _asus_systemd_is_live; then
        return 0
    fi
    systemctl daemon-reload
}

_asus_run_interactive_configure() {
    if ! _asus_resolve_configure_bin; then
        echo "Missing configure helper: /usr/sbin|/usr/bin/asus-zenbook-configure" >&2
        return 1
    fi
    SKIP_PKG_INSTALL=1 "$CONFIGURE_BIN"
}

_asus_should_run_interactive_wizard() {
    local previous_version="${1:-}"
    if _asus_is_noninteractive_frontend || ! _asus_can_use_tty; then
        return 1
    fi
    if [ -n "$previous_version" ] && [ "${ASUS_FORCE_RECONFIGURE:-}" != "1" ]; then
        return 1
    fi
    return 0
}

_asus_configure_after_install() {
    local previous_version="${1:-}"
    if ! _asus_should_run_interactive_wizard "$previous_version"; then
        _asus_print_reconfigure_hint
        _asus_daemon_reload_if_live
        return 0
    fi
    if ! _asus_run_interactive_configure; then
        echo "Component configuration did not complete successfully." >&2
        _asus_print_reconfigure_hint >&2
        return 1
    fi
    _asus_daemon_reload_if_live
    return 0
}

_asus_run_packaged_uninstall() {
    local uninstall_sh="/usr/share/asus-zenbook-linux-tools/uninstall.sh"
    local status=0
    if [ ! -f "$uninstall_sh" ]; then
        echo "Error: packaged uninstall helper missing: $uninstall_sh" >&2
        return 1
    fi
    if SKIP_PKG_REMOVE=1 bash "$uninstall_sh"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        echo "Error: packaged uninstall helper exited with status $status; package removal is aborted." >&2
        return "$status"
    fi
    return 0
}

_asus_purge_state_dir() {
    rm -rf "$STATE_DIR"
}
