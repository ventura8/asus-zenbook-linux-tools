#!/usr/bin/env bash
# Distro-matrix compatibility smoke: fail closed on packaging gaps, broken product
# helpers, and real DESTDIR install/uninstall regressions for the current OS family.
#
# Package deps are preinstalled in CI images so unit/e2e imports work. Availability
# probes still verify names resolve on the distro. Live package mutation (remove →
# install.sh → uninstall.sh) runs only inside containers with passwordless sudo so
# install_system_deps / remove_system_deps are actually exercised.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/install-os-detection.sh
source "$REPO_ROOT/lib/install-os-detection.sh"
# shellcheck source=lib/asus-session.sh
source "$REPO_ROOT/lib/asus-session.sh"
# shellcheck source=scripts/coverage/gates.sh
source "$REPO_ROOT/scripts/coverage/gates.sh"

_smoke_log() {
    printf '[distro-compat-smoke] %s\n' "$*"
}

_SMOKE_LOG_DIR="$(resolve_reports_root)/distro-logs"
_SMOKE_PKG_LOG="$_SMOKE_LOG_DIR/distro-compat-pkg-mutation${REPORT_DISTRO_SLUG:+-${REPORT_DISTRO_SLUG}}.log"

_smoke_log_command() {
    local label="$1"
    local status=0
    local saved_errexit
    shift
    mkdir -p "$_SMOKE_LOG_DIR"
    saved_errexit=$(shopt -po errexit)
    set +e
    {
        printf '[distro-compat-smoke] %s\n' "$label"
        "$@"
    } 2>&1 | tee -a "$_SMOKE_PKG_LOG"
    status=${PIPESTATUS[0]}
    eval "$saved_errexit"
    return "$status"
}

_smoke_fail() {
    echo "[distro-compat-smoke] ERROR: $*" >&2
    exit 1
}

_smoke_in_container() {
    [ -f /.dockerenv ] || [ -f /run/.containerenv ]
}

_required_pkgs_for_family() {
    local family="$1"
    case "$family" in
        debian) _required_pkgs_debian ;;
        redhat) _required_pkgs_redhat ;;
        suse) _required_pkgs_suse ;;
        arch) _required_pkgs_arch ;;
        *) return 1 ;;
    esac
}

_required_pkgs_debian() {
    # ydotool is optional: packaged on Ubuntu, absent on Debian.
    # python3-gi is required for GNOME gsettings "as" array helpers.
    printf '%s\n' python3-evdev python3-gi gettext \
        alsa-tools alsa-utils xdotool
    if _pkg_installed_or_known_debian ydotool; then
        printf '%s\n' ydotool
    fi
}

_required_pkgs_redhat() {
    # ydotool / alsa-tools RPMs are optional on RHEL-family (Fedora has both).
    # AlmaLinux 10 also lacks python3-evdev / xdotool in base+EPEL — require only
    # when the package manager knows them (CI uses poetry evdev on that lane).
    # SOUND still installs automatically via bundled asus_hda_verb.py when
    # system hda-verb / alsa-tools is absent.
    printf '%s\n' python3-gobject gettext alsa-utils
    if _pkg_installed_or_known_rpm python3-evdev; then
        printf '%s\n' python3-evdev
    fi
    if _pkg_installed_or_known_rpm xdotool; then
        printf '%s\n' xdotool
    fi
    if _pkg_installed_or_known_rpm alsa-tools; then
        printf '%s\n' alsa-tools
    fi
    if _pkg_installed_or_known_rpm ydotool; then
        printf '%s\n' ydotool
    fi
}

_smoke_suse_evdev_from_rpm() {
    local pkg="$1"
    command -v rpm >/dev/null 2>&1 || {
        printf '%s\n' "$pkg"
        return 0
    }
    if rpm -q "$pkg" &>/dev/null; then
        printf '%s\n' "$pkg"
        return 0
    fi
    if rpm -q python3-evdev &>/dev/null; then
        printf '%s\n' "python3-evdev"
        return 0
    fi
    printf '%s\n' "$pkg"
}

_smoke_resolve_suse_evdev_pkg() {
    local ver pkg
    ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")' \
        2>/dev/null || true)
    [ -n "$ver" ] || { printf '%s\n' "python3-evdev"; return 0; }
    pkg="python${ver}-evdev"
    _smoke_suse_evdev_from_rpm "$pkg"
}

_smoke_resolve_suse_gobject_pkg() {
    if declare -F _resolve_suse_gobject_pkg >/dev/null 2>&1; then
        _resolve_suse_gobject_pkg
        return 0
    fi
    printf '%s\n' "python3-gobject"
}

_smoke_resolve_suse_curses_pkg() {
    if declare -F _resolve_suse_curses_pkg >/dev/null 2>&1; then
        _resolve_suse_curses_pkg
        return 0
    fi
    printf '%s\n' "python3-curses"
}

_required_pkgs_suse() {
    local evdev_pkg gobject_pkg curses_pkg
    evdev_pkg=$(_smoke_resolve_suse_evdev_pkg)
    gobject_pkg=$(_smoke_resolve_suse_gobject_pkg)
    curses_pkg=$(_smoke_resolve_suse_curses_pkg)
    printf '%s\n' "$evdev_pkg" "$gobject_pkg" "$curses_pkg" \
        gettext-tools hda-verb alsa-utils xdotool
    if _pkg_installed_or_known_rpm alsa-tools; then
        printf '%s\n' alsa-tools
    fi
    if _pkg_installed_or_known_rpm ydotool; then
        printf '%s\n' ydotool
    fi
}

_required_pkgs_arch() {
    printf '%s\n' python-evdev python-gobject gettext alsa-utils xdotool
    if _pkg_installed_or_known_arch alsa-tools; then
        printf '%s\n' alsa-tools
    fi
    if _pkg_installed_or_known_arch ydotool; then
        printf '%s\n' ydotool
    fi
}

_pkg_installed_or_known_debian() {
    local pkg="$1"
    dpkg -s "$pkg" >/dev/null 2>&1 && return 0
    apt-cache show "$pkg" >/dev/null 2>&1
}

_pkg_installed_or_known_rpm() {
    local pkg="$1"
    rpm -q "$pkg" >/dev/null 2>&1 && return 0
    _rpm_repo_has_pkg "$pkg"
}

_rpm_repo_has_pkg() {
    local pkg="$1"
    if command -v dnf >/dev/null 2>&1; then
        dnf info "$pkg" >/dev/null 2>&1
        return $?
    fi
    command -v zypper >/dev/null 2>&1 || return 1
    zypper --non-interactive search -x "$pkg" >/dev/null 2>&1
}

_pkg_installed_or_known_arch() {
    local pkg="$1"
    pacman -Q "$pkg" >/dev/null 2>&1 && return 0
    pacman -Si "$pkg" >/dev/null 2>&1
}

_assert_pkg_available() {
    local family="$1" pkg="$2"
    case "$family" in
        debian) _pkg_installed_or_known_debian "$pkg" ;;
        redhat|suse) _pkg_installed_or_known_rpm "$pkg" ;;
        arch) _pkg_installed_or_known_arch "$pkg" ;;
        *) return 1 ;;
    esac
}

_pkg_is_installed() {
    local family="$1" pkg="$2"
    case "$family" in
        debian)
            # dpkg -s succeeds for "config-files" leftovers after apt remove
            # without --purge (uninstall path). Require fully installed.
            dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null \
                | grep -qx 'install ok installed'
            ;;
        redhat|suse) rpm -q "$pkg" >/dev/null 2>&1 ;;
        arch) pacman -Q "$pkg" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

_assert_supported_smoke_family() {
    case "$1" in
        debian|redhat|suse|arch) return 0 ;;
    esac
    _smoke_fail "unsupported OS family for smoke: ${1:-unknown}"
}

_check_one_required_pkg() {
    local family="$1" pkg="$2"
    if _assert_pkg_available "$family" "$pkg"; then
        _smoke_log "  ✓ $pkg available"
        return 0
    fi
    echo "[distro-compat-smoke] ERROR: required package unavailable: $pkg" >&2
    return 1
}

_scan_required_packages() {
    local family="$1" pkg pkg_gap=0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        _check_one_required_pkg "$family" "$pkg" || pkg_gap=1
    done < <(_required_pkgs_for_family "$family")
    return "$pkg_gap"
}

_verify_required_packages() {
    local family="$1"
    _assert_supported_smoke_family "$family"
    _smoke_log "Verifying installer package availability for family=$family"
    _scan_required_packages "$family" \
        || _smoke_fail "installer package set is incomplete on this distro"
}

_verify_product_shell_syntax() {
    local path
    _smoke_log "Syntax-checking product shell scripts"
    # Same product set as kcov gates (all bin/lib *.sh plus installers); no maxdepth.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        bash -n "$path" || _smoke_fail "bash -n failed for $path"
    done < <(
        find bin lib -type f -name '*.sh' | LC_ALL=C sort
        printf '%s\n' install.sh uninstall.sh
    )
}

_verify_product_python_imports() {
    _smoke_log "Importing product Python modules"
    # Discover bin/*.py regularly (skip hyphenated symlink CLI entrypoints) so new
    # modules are imported without updating a hardcoded list.
    PYTHONPATH="$REPO_ROOT/bin${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - <<'PY' || _smoke_fail "product Python import check failed"
import importlib
from pathlib import Path

bin_dir = Path("bin")
modules = []
for path in sorted(bin_dir.glob("*.py")):
    if path.is_symlink() or path.name == "__init__.py":
        continue
    modules.append(path.stem)
if not modules:
    raise SystemExit("no product Python modules found under bin/")
for name in modules:
    importlib.import_module(name)
print("imports-ok")
PY
}

_verify_desktop_family_string() {
    local input="$1" expected="$2" got
    got=$(asus_desktop_family_from_string "$input")
    [ "$got" = "$expected" ] \
        || _smoke_fail "expected $expected for $input, got $got"
}

_verify_session_desktop_family() {
    local got
    _smoke_log "Checking desktop-family precedence helpers"
    _verify_desktop_family_string "XFCE:ubuntu" xfce
    _verify_desktop_family_string "KDE:ubuntu" kde
    _verify_desktop_family_string "LXQt:ubuntu" lxqt
    _verify_desktop_family_string "X-Cinnamon" cinnamon
    _verify_desktop_family_string "MATE" mate
    got=$(ASUS_DESKTOP_FAMILY=gnome asus_desktop_family "")
    [ "$got" = "gnome" ] || _smoke_fail "ASUS_DESKTOP_FAMILY override failed"
}

_probe_helper_fails_closed() {
    local family="$1" helper_path="$2" smoke_probe_log="$3" label="$4" mock_bin="$5"
    local helper_status=0 helper_out
    helper_out=$(PATH="$mock_bin:$PATH" ASUS_DESKTOP_FAMILY="$family" \
        "$helper_path" 2>&1) || helper_status=$?
    printf '%s\n' "$helper_out" | tee -a "$smoke_probe_log"
    if [ "$helper_status" -eq 0 ]; then
        _smoke_fail "$label unexpectedly succeeded without a session"
    fi
    if ! printf '%s\n' "$helper_out" | grep -Fq "No active graphical session found"; then
        _smoke_fail "$label exited $helper_status without expected session-failure text"
    fi
}

_verify_helper_scripts_fail_closed() {
    local tmp mock_bin smoke_probe_log prev_exit_trap
    tmp=$(mktemp -d)
    prev_exit_trap=$(trap -p EXIT || true)
    # Expand path at registration so EXIT cleanup stays valid under set -u.
    trap 'rm -rf "'"$tmp"'"' EXIT
    mock_bin="$tmp/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/loginctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$mock_bin/loginctl"
    _smoke_log "Checking helpers fail closed without a GUI session"
    mkdir -p "$_SMOKE_LOG_DIR"
    smoke_probe_log="$_SMOKE_LOG_DIR/distro-compat-session-probes${REPORT_DISTRO_SLUG:+-${REPORT_DISTRO_SLUG}}.log"
    _probe_helper_fails_closed gnome bin/asus-screenshot.sh "$smoke_probe_log" \
        "asus-screenshot.sh" "$mock_bin"
    _probe_helper_fails_closed kde bin/asus-control-center.sh "$smoke_probe_log" \
        "asus-control-center.sh" "$mock_bin"
    trap - EXIT
    if [ -n "$prev_exit_trap" ]; then
        eval "$prev_exit_trap"
    fi
    rm -rf "$tmp"
    return 0
}

_write_systemctl_stub() {
    local path="$1"
    local state_file state_file_quoted
    state_file="$(dirname "$path")/.asus_systemctl_state"
    state_file_quoted="$(printf '%q' "$state_file")"
    cat > "$path" <<EOF
#!/bin/sh
state_file=$state_file_quoted
case "\$1" in
  daemon-reload) exit 0 ;;
  enable|restart|start)
    printf 'active\\n' > "\$state_file"
    exit 0
    ;;
  stop|disable)
    printf 'inactive\\n' > "\$state_file"
    exit 0
    ;;
  is-active)
    if [ -f "\$state_file" ] && [ "\$(cat "\$state_file")" = "active" ]; then
      echo active
      exit 0
    fi
    echo inactive
    exit 3
    ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$path"
}

_have_bin_asset() {
    local bin="$1" rel="$2"
    if [ -e "$bin/$rel" ]; then
        return 0
    fi
    echo "[distro-compat-smoke] missing installed asset: $bin/$rel" >&2
    return 1
}

_assert_core_lib_and_unit() {
    local dest="$1"
    [ -f "$dest/usr/local/lib/asus-zenbook-linux-tools/asus-session.sh" ] || return 1
    [ -f "$dest/usr/local/lib/asus-zenbook-linux-tools/asus-i18n.sh" ] || return 1
    [ -f "$dest/etc/systemd/system/asus-hotkey-daemon.service" ] || return 1
    return 0
}

_assert_installed_wmi_assets() {
    local dest="$1" bin asset_gap=0 rel
    bin="$dest/usr/local/bin"
    for rel in asus-hotkey-daemon.py asus-display-mode.sh asus-screenshot.sh \
        asus-control-center.sh \
        asus-touchpad-share.py asus_touchpad_share.py asus_touchpad_share_bounds.py; do
        if ! _have_bin_asset "$bin" "$rel"; then
            asset_gap=1
        fi
    done
    if ! _assert_core_lib_and_unit "$dest"; then
        asset_gap=1
    fi
    if [ "$asset_gap" -ne 0 ]; then
        echo "[distro-compat-smoke] install did not deploy expected WMI/TOUCHPAD assets" >&2
        return 1
    fi
    return 0
}

_assert_uninstalled() {
    local dest="$1"
    if [ -e "$dest/usr/local/bin/asus-hotkey-daemon.py" ]; then
        _smoke_fail "uninstall left asus-hotkey-daemon.py behind"
    fi
    if [ -e "$dest/usr/local/bin/asus-touchpad-share.py" ]; then
        _smoke_fail "uninstall left asus-touchpad-share.py behind"
    fi
    if [ -e "$dest/etc/systemd/system/asus-hotkey-daemon.service" ]; then
        _smoke_fail "uninstall left hotkey unit behind"
    fi
}

_prepare_install_workspace() {
    local tmp="$1"
    mkdir -p "$tmp/dest" "$tmp/bin" "$tmp/bus/$(id -u)"
    _write_systemctl_stub "$tmp/bin/systemctl"
    cat > "$tmp/bin/loginctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$tmp/bin/loginctl"
}

_run_destdir_install() {
    local dest="$1" mock_bin="$2" bus_root="$3" skip_pkg="$4"
    PATH="$mock_bin:$PATH" \
        ASUS_TEST_MODE=1 \
        SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL="$skip_pkg" SKIP_PKG_REMOVE="$skip_pkg" \
        INSTALL_COMMAND_TIMEOUT=5 INSTALL_ASSUME_UNIT_ACTIVE=1 \
        NONINTERACTIVE_CHOICE="WMI TOUCHPAD" \
        DESTDIR="$dest" DBUS_BUS_ROOT="$bus_root" \
        SYSTEMCTL_CMD="$mock_bin/systemctl" \
        ./install.sh
}

_run_destdir_uninstall() {
    local dest="$1" mock_bin="$2" bus_root="$3" skip_pkg="$4"
    PATH="$mock_bin:$PATH" \
        ASUS_TEST_MODE=1 \
        SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL="$skip_pkg" SKIP_PKG_REMOVE="$skip_pkg" \
        INSTALL_COMMAND_TIMEOUT=5 \
        DESTDIR="$dest" DBUS_BUS_ROOT="$bus_root" \
        SYSTEMCTL_CMD="$mock_bin/systemctl" \
        ./uninstall.sh
}

_run_file_install_uninstall_cycle() {
    (
        local tmp dest mock_bin bus_root
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _prepare_install_workspace "$tmp"
        dest="$tmp/dest"
        mock_bin="$tmp/bin"
        bus_root="$tmp/bus"

        _smoke_log "Running DESTDIR file install/uninstall (SKIP_PKG_*=1)"
        if ! _run_destdir_install "$dest" "$mock_bin" "$bus_root" 1; then
            _smoke_fail "install.sh failed (file cycle)"
        fi
        _assert_installed_wmi_assets "$dest" || _smoke_fail "install assets missing (file cycle)"
        if ! _run_destdir_uninstall "$dest" "$mock_bin" "$bus_root" 1; then
            _smoke_fail "uninstall.sh failed (file cycle)"
        fi
        _assert_uninstalled "$dest"
        _smoke_log "DESTDIR file install/uninstall cycle passed"
    )
}

# shellcheck source=scripts/distro_install_smoke_desktop.sh
source "$SCRIPT_DIR/distro_install_smoke_desktop.sh"
# shellcheck source=scripts/distro_install_smoke_live_pkg.sh
source "$SCRIPT_DIR/distro_install_smoke_live_pkg.sh"

main() {
    local family
    family=$(_detect_os_family) || _smoke_fail "could not detect OS family"
    _smoke_log "Detected OS family: $family"
    _verify_required_packages "$family"
    _verify_python_gi_import
    _verify_optional_desktop_cli_tools
    _verify_product_shell_syntax
    _verify_product_python_imports
    _verify_session_desktop_family
    _verify_helper_scripts_fail_closed
    _run_file_install_uninstall_cycle
    _run_desktop_install_uninstall_cycles
    if _smoke_in_container; then
        _run_live_pkg_install_uninstall_cycle "$family"
    else
        _smoke_log "Skipping live package mutation outside container (preinstalled deps stay put)"
    fi
    _smoke_log "OK"
}

main "$@"
