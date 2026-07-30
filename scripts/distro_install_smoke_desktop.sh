#!/usr/bin/env bash
# Sourced by run_distro_install_smoke.sh — DESKTOP DESTDIR cycles
# (GNOME/KDE/XFCE/LXQt/Cinnamon/MATE). Install wiring only (not live panels).

# shellcheck source=scripts/distro_install_smoke_lxqt.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distro_install_smoke_lxqt.sh"
# shellcheck source=scripts/distro_install_smoke_cinnamon.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distro_install_smoke_cinnamon.sh"
# shellcheck source=scripts/distro_install_smoke_mate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distro_install_smoke_mate.sh"
# shellcheck source=scripts/distro_install_smoke_full_de.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distro_install_smoke_full_de.sh"
# shellcheck source=scripts/distro_install_smoke_desktop_dispatch.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distro_install_smoke_desktop_dispatch.sh"

_SMOKE_WINDOW_SWAP_UUID="asus-window-swap@ventura8.github.com"
_SMOKE_GNOME_ORIG_ENABLED="['other-ext@example.com']"
_SMOKE_GNOME_ORIG_BINDING="['mock']"
_SMOKE_KDE_ORIG_KSCREEN="Meta+P"
_SMOKE_XFCE_ORIG_BINDING="/usr/bin/old-binding"

_smoke_bind_bus_socket() {
    local bus_path="$1"
    mkdir -p "$(dirname "$bus_path")"
    rm -f "$bus_path"
    python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()" \
        "$bus_path" 2>/dev/null || return 1
    [ -S "$bus_path" ]
}

_smoke_write_sudo_stub() {
    local mock_bin="$1"
    cat > "$mock_bin/sudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -E|-n) shift ;;
    -u) shift; [ $# -gt 0 ] && shift ;;
    -*) shift ;;
    *=*) export "$1"; shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF
    chmod +x "$mock_bin/sudo"
}

_smoke_write_session_loginctl() {
    local mock_bin="$1" user="$2"
    cat > "$mock_bin/loginctl" <<EOF
#!/bin/sh
if [ "\$1" = "list-sessions" ]; then
  echo 1
  exit 0
fi
if [ "\$1" = "show-session" ]; then
  case "\$4" in
    Type) echo wayland ;;
    State) echo active ;;
    Name) echo $user ;;
    Seat) echo seat0 ;;
    Leader) echo \$\$ ;;
  esac
fi
exit 0
EOF
    chmod +x "$mock_bin/loginctl"
}

_smoke_write_getent_stub() {
    local mock_bin="$1" user="$2" uid="$3" gid="$4" home="$5"
    cat > "$mock_bin/getent" <<EOF
#!/bin/sh
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s\\n' "$user:x:$uid:$gid::$home:/bin/bash"
  exit 0
fi
if [ -x /usr/bin/getent ]; then
  exec /usr/bin/getent "\$@"
fi
exit 1
EOF
    chmod +x "$mock_bin/getent"
}

_smoke_write_gnome_stubs() {
    local mock_bin="$1" gset_log="$2"
    printf '%s\n' "$_SMOKE_GNOME_ORIG_ENABLED" > "${gset_log}.enabled"
    printf '%s\n' "$_SMOKE_GNOME_ORIG_BINDING" > "${gset_log}.val.default"
    cat > "$mock_bin/gsettings" <<EOF
#!/bin/sh
log="$gset_log"
printf '%s\\n' "\$*" >> "\$log"
case "\$1" in
  list-keys)
    printf '%s\\n' switch-video-mode custom-keybindings control-center show-screenshot-ui
    exit 0
    ;;
  get)
    if [ "\$2" = "org.gnome.shell" ] && [ "\$3" = "enabled-extensions" ]; then
      if [ -f "\${log}.enabled" ]; then
        cat "\${log}.enabled"
      else
        echo '[]'
      fi
      exit 0
    fi
    if [ -f "\${log}.val.\$3" ]; then
      cat "\${log}.val.\$3"
    else
      cat "\${log}.val.default"
    fi
    exit 0
    ;;
  set)
    if [ "\$2" = "org.gnome.shell" ] && [ "\$3" = "enabled-extensions" ]; then
      printf '%s\\n' "\$4" > "\${log}.enabled"
    fi
    printf '%s\\n' "\$4" > "\${log}.val.\$3"
    exit 0
    ;;
  reset)
    if [ -f "\${log}.val.\$3" ]; then
      rm -f "\${log}.val.\$3"
    fi
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "$mock_bin/gsettings"
    printf '#!/bin/sh\nexit 0\n' > "$mock_bin/gnome-extensions"
    chmod +x "$mock_bin/gnome-extensions"
}

_smoke_write_kde_stubs() {
    local mock_bin="$1" kde_log="$2"
    printf '%s\n' "$_SMOKE_KDE_ORIG_KSCREEN" > "${kde_log}.val.kscreen._launch"
    printf '%s\n' "$_SMOKE_KDE_ORIG_KSCREEN" > "${kde_log}.val.kscreen._k_friendly_name"
    cat > "$mock_bin/kwriteconfig6" <<EOF
#!/bin/sh
log="$kde_log"
printf '%s\\n' "\$*" >> "\$log"
group=""
key=""
delete=0
value=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --group) if [ \$# -ge 2 ]; then group="\$2"; shift 2; else shift; fi ;;
    --key) if [ \$# -ge 2 ]; then key="\$2"; shift 2; else shift; fi ;;
    --delete) delete=1; shift ;;
    --file) if [ \$# -ge 2 ]; then shift 2; else shift; fi ;;
    *) value="\$1"; shift ;;
  esac
done
if [ -n "\$group" ] && [ -n "\$key" ]; then
  if [ "\$delete" = 1 ]; then
    rm -f "\${log}.val.\${group}.\${key}"
  elif [ -n "\$value" ]; then
    printf '%s\\n' "\$value" > "\${log}.val.\${group}.\${key}"
  fi
fi
exit 0
EOF
    cat > "$mock_bin/kreadconfig6" <<EOF
#!/bin/sh
log="$kde_log"
group=""
key=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --group) if [ \$# -ge 2 ]; then group="\$2"; shift 2; else shift; fi ;;
    --key) if [ \$# -ge 2 ]; then key="\$2"; shift 2; else shift; fi ;;
    --file) if [ \$# -ge 2 ]; then shift 2; else shift; fi ;;
    *) shift ;;
  esac
done
if [ -f "\${log}.val.\${group}.\${key}" ]; then
  cat "\${log}.val.\${group}.\${key}"
  exit 0
fi
printf '%s\\n' "$_SMOKE_KDE_ORIG_KSCREEN"
exit 0
EOF
    printf '#!/bin/sh\nexit 0\n' > "$mock_bin/qdbus"
    chmod +x "$mock_bin/kwriteconfig6" "$mock_bin/kreadconfig6" "$mock_bin/qdbus"
}

_smoke_write_xfce_stubs() {
    local mock_bin="$1" xfce_log="$2"
    printf '%s\n' "$_SMOKE_XFCE_ORIG_BINDING" > "${xfce_log}.val.XF86Display"
    printf '%s\n' "$_SMOKE_XFCE_ORIG_BINDING" > "${xfce_log}.val.SuperF12"
    printf '%s\n' "$_SMOKE_XFCE_ORIG_BINDING" > "${xfce_log}.val.SuperShiftS"
    cat > "$mock_bin/xfconf-query" <<EOF
#!/bin/sh
log="$xfce_log"
printf '%s\\n' "\$*" >> "\$log"
path=""
set_val=""
do_set=0
do_rm=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -p) if [ \$# -ge 2 ]; then path="\$2"; shift 2; else shift; fi ;;
    -s) if [ \$# -ge 2 ]; then set_val="\$2"; do_set=1; shift 2; else shift; fi ;;
    -n) shift ;;
    -t) if [ \$# -ge 2 ]; then shift 2; else shift; fi ;;
    -r) do_rm=1; shift ;;
    -c) if [ \$# -ge 2 ]; then shift 2; else shift; fi ;;
    -l) shift ;;
    *) shift ;;
  esac
done
key=""
# Quote patterns that contain <...> so dash (/bin/sh) does not treat them as
# redirections ("Syntax error: redirection unexpected").
case "\$path" in
  *XF86Display) key="XF86Display" ;;
  *'<Super>F12') key="SuperF12" ;;
  *'<Super><Shift>s'|*'<Super><Shift>S'|*SuperShiftS) key="SuperShiftS" ;;
esac
if [ "\$do_rm" = 1 ] && [ -n "\$key" ]; then
  rm -f "\${log}.val.\$key"
  exit 0
fi
if [ "\$do_set" = 1 ] && [ -n "\$key" ]; then
  printf '%s\\n' "\$set_val" > "\${log}.val.\$key"
  exit 0
fi
if [ -n "\$key" ] && [ -f "\${log}.val.\$key" ]; then
  cat "\${log}.val.\$key"
  exit 0
fi
if [ -n "\$path" ]; then
  printf '%s\\n' "$_SMOKE_XFCE_ORIG_BINDING"
  exit 0
fi
exit 0
EOF
    chmod +x "$mock_bin/xfconf-query"
}

_smoke_prepare_desktop_workspace() {
    local tmp="$1" user="$2" uid="$3" gid="$4"
    local dest mock_bin bus_root home_dir
    mkdir -p "$tmp/dest" "$tmp/bin" "$tmp/bus/$uid" "$tmp/home" "$tmp/logs"
    dest="$tmp/dest"
    mock_bin="$tmp/bin"
    bus_root="$tmp/bus"
    home_dir="$tmp/home/$user"
    mkdir -p "$home_dir"
    _write_systemctl_stub "$mock_bin/systemctl"
    _smoke_write_sudo_stub "$mock_bin"
    _smoke_write_session_loginctl "$mock_bin" "$user"
    _smoke_write_getent_stub "$mock_bin" "$user" "$uid" "$gid" "$home_dir"
    if ! _smoke_bind_bus_socket "$bus_root/$uid/bus"; then
        _smoke_fail "failed to bind fake session bus at $bus_root/$uid/bus"
    fi
    _SMOKE_DESKTOP_DEST="$dest"
    _SMOKE_DESKTOP_MOCK_BIN="$mock_bin"
    _SMOKE_DESKTOP_BUS_ROOT="$bus_root"
    _SMOKE_DESKTOP_HOME_DIR="$home_dir"
    return 0
}

_smoke_run_desktop_install() {
    local family="$1" dest="$2" mock_bin="$3" bus_root="$4"
    PATH="$mock_bin:$PATH" \
        SUDO_CMD="$mock_bin/sudo" \
        ASUS_TEST_MODE=1 \
        SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=1 SKIP_PKG_REMOVE=1 \
        INSTALL_COMMAND_TIMEOUT=30 INSTALL_ASSUME_UNIT_ACTIVE=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        ASUS_DESKTOP_FAMILY="$family" \
        NONINTERACTIVE_CHOICE="DESKTOP" \
        DESTDIR="$dest" DBUS_BUS_ROOT="$bus_root" BUS_ROOT="$bus_root" \
        SYSTEMCTL_CMD="$mock_bin/systemctl" \
        ./install.sh
}

_smoke_run_desktop_uninstall() {
    local dest="$1" mock_bin="$2" bus_root="$3"
    PATH="$mock_bin:$PATH" \
        SUDO_CMD="$mock_bin/sudo" \
        ASUS_TEST_MODE=1 \
        SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=1 SKIP_PKG_REMOVE=1 \
        INSTALL_COMMAND_TIMEOUT=30 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        DESTDIR="$dest" DBUS_BUS_ROOT="$bus_root" BUS_ROOT="$bus_root" \
        SYSTEMCTL_CMD="$mock_bin/systemctl" \
        ./uninstall.sh
}

_smoke_require_file() {
    if [ ! -f "$1" ]; then
        _smoke_fail "$2"
    fi
}

_smoke_require_dir() {
    if [ ! -d "$1" ]; then
        _smoke_fail "$2"
    fi
}

_smoke_require_absent() {
    if [ -e "$1" ]; then
        _smoke_fail "$2"
    fi
}

_smoke_require_eq() {
    if [ "$1" != "$2" ]; then
        _smoke_fail "$3"
    fi
}

_smoke_require_grep() {
    if ! grep -Fq "$1" "$2" 2>/dev/null; then
        _smoke_fail "$3"
    fi
}

_smoke_require_no_grep() {
    if grep -Fq "$1" "$2" 2>/dev/null; then
        _smoke_fail "$3"
    fi
}

_smoke_assert_family_marker() {
    local state_dir="$1" family="$2"
    _smoke_require_file "$state_dir/desktop_family" "$family desktop_family marker missing"
    _smoke_require_eq "$(cat "$state_dir/desktop_family")" "$family" "expected desktop_family=$family"
}

_smoke_assert_marker_cleared() {
    local state_dir="$1" label="$2"
    if [ -f "$state_dir/desktop_family" ]; then
        _smoke_fail "uninstall left $label desktop_family marker"
    fi
}

_smoke_assert_gnome_installed() {
    local dest="$1" home_dir="$2" uid="$3" gset_log="$4"
    local ext state_dir
    ext="$home_dir/.local/share/gnome-shell/extensions/$_SMOKE_WINDOW_SWAP_UUID"
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_require_file "$ext/metadata.json" "GNOME extension metadata.json missing at $ext"
    _smoke_require_file "$ext/extension.js" "GNOME extension.js missing at $ext"
    _smoke_assert_family_marker "$state_dir" gnome
    _smoke_require_file "$state_dir/orig_show_screenshot_ui" \
        "GNOME orig_show_screenshot_ui backup missing"
    _smoke_require_file "$state_dir/orig_control_center" \
        "GNOME orig_control_center backup missing"
    _smoke_require_grep "$_SMOKE_WINDOW_SWAP_UUID" "${gset_log}.enabled" \
        "gsettings enabled-extensions was not set with Window Swap UUID"
}

_smoke_assert_file_eq() {
    local path="$1" expected="$2" label="$3"
    _smoke_require_file "$path" "$label missing at $path"
    _smoke_require_eq "$(cat "$path")" "$expected" \
        "$label not restored (expected $expected)"
}

_smoke_assert_gnome_uninstalled() {
    local dest="$1" home_dir="$2" uid="$3" gset_log="$4"
    local ext state_dir
    ext="$home_dir/.local/share/gnome-shell/extensions/$_SMOKE_WINDOW_SWAP_UUID"
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_require_absent "$ext" "uninstall left Window Swap extension at $ext"
    _smoke_assert_marker_cleared "$state_dir" GNOME
    _smoke_assert_file_eq "${gset_log}.enabled" "$_SMOKE_GNOME_ORIG_ENABLED" \
        "GNOME enabled-extensions original"
    _smoke_require_no_grep "$_SMOKE_WINDOW_SWAP_UUID" "${gset_log}.enabled" \
        "uninstall left Window Swap UUID in enabled-extensions"
    _smoke_assert_file_eq "${gset_log}.val.show-screenshot-ui" "$_SMOKE_GNOME_ORIG_BINDING" \
        "GNOME show-screenshot-ui"
    _smoke_assert_file_eq "${gset_log}.val.control-center" "$_SMOKE_GNOME_ORIG_BINDING" \
        "GNOME control-center"
}

_smoke_assert_kde_installed() {
    local dest="$1" uid="$2" kde_log="$3"
    local apps state_dir
    apps="$dest/usr/local/share/applications"
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_require_file "$apps/asus-display-mode.desktop" \
        "KDE helper desktop missing: asus-display-mode.desktop"
    _smoke_require_file "$apps/asus-control-center.desktop" \
        "KDE helper desktop missing: asus-control-center.desktop"
    _smoke_require_file "$apps/asus-screenshot.desktop" \
        "KDE helper desktop missing: asus-screenshot.desktop"
    _smoke_assert_family_marker "$state_dir" kde
    _smoke_require_dir "$state_dir/kde" "KDE state directory missing"
    _smoke_require_grep "asus-display-mode.desktop" "$kde_log" \
        "kwriteconfig was not invoked for asus-display-mode.desktop"
}

_smoke_assert_kde_uninstalled() {
    local dest="$1" uid="$2" kde_log="$3"
    local apps state_dir
    apps="$dest/usr/local/share/applications"
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_require_absent "$apps/asus-display-mode.desktop" \
        "uninstall left asus-display-mode.desktop"
    _smoke_require_absent "$apps/asus-control-center.desktop" \
        "uninstall left asus-control-center.desktop"
    _smoke_require_absent "$apps/asus-screenshot.desktop" \
        "uninstall left asus-screenshot.desktop"
    _smoke_assert_marker_cleared "$state_dir" KDE
    _smoke_assert_file_eq "${kde_log}.val.kscreen._launch" "$_SMOKE_KDE_ORIG_KSCREEN" \
        "KDE kscreen _launch"
    _smoke_assert_file_eq "${kde_log}.val.kscreen._k_friendly_name" "$_SMOKE_KDE_ORIG_KSCREEN" \
        "KDE kscreen _k_friendly_name"
}

_smoke_assert_xfce_installed() {
    local dest="$1" uid="$2" xfce_log="$3"
    local state_dir
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_assert_family_marker "$state_dir" xfce
    _smoke_require_file "$state_dir/xfce_bus_path" "XFCE xfce_bus_path missing"
    if [ ! -f "$state_dir/orig_xfce_xf86display" ]; then
        _smoke_require_file "$state_dir/orig_xfce_xf86display.absent" \
            "XFCE XF86Display backup missing"
    fi
    _smoke_require_grep "XF86Display" "$xfce_log" \
        "xfconf-query was not invoked for XF86Display"
}

_smoke_assert_xfce_uninstalled() {
    local dest="$1" uid="$2" xfce_log="$3"
    local state_dir
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_assert_marker_cleared "$state_dir" XFCE
    _smoke_assert_file_eq "${xfce_log}.val.XF86Display" "$_SMOKE_XFCE_ORIG_BINDING" \
        "XFCE XF86Display"
    _smoke_assert_file_eq "${xfce_log}.val.SuperF12" "$_SMOKE_XFCE_ORIG_BINDING" \
        "XFCE Super+F12"
    _smoke_assert_file_eq "${xfce_log}.val.SuperShiftS" "$_SMOKE_XFCE_ORIG_BINDING" \
        "XFCE Super+Shift+S"
}

_smoke_run_logged_step() {
    # Run command with live tee; fail closed on nonzero status.
    local label="$1" smoke_log="$2"
    local status=0 caller_errexit
    local -a pipe_status=()
    shift 2
    caller_errexit=$(shopt -po errexit)
    set +e
    "$@" 2>&1 | tee -a "$smoke_log"
    pipe_status=("${PIPESTATUS[@]}")
    eval "$caller_errexit"
    status="${pipe_status[0]}"
    if [ "$status" -ne 0 ]; then
        _smoke_fail "$label"
    fi
}

_smoke_require_desktop_workspace() {
    local tmp="$1" user="$2" uid="$3" gid="$4"
    _SMOKE_DESKTOP_DEST=""
    _SMOKE_DESKTOP_MOCK_BIN=""
    _SMOKE_DESKTOP_BUS_ROOT=""
    _SMOKE_DESKTOP_HOME_DIR=""
    _smoke_prepare_desktop_workspace "$tmp" "$user" "$uid" "$gid"
    if [ -z "${_SMOKE_DESKTOP_DEST:-}" ] || [ -z "${_SMOKE_DESKTOP_MOCK_BIN:-}" ] \
        || [ -z "${_SMOKE_DESKTOP_BUS_ROOT:-}" ] || [ -z "${_SMOKE_DESKTOP_HOME_DIR:-}" ]; then
        _smoke_fail "desktop workspace prepare returned empty dest/mock/bus/home"
    fi
}

_smoke_desktop_family_cycle_body() {
    local family="$1" tmp="$2"
    local dest mock_bin bus_root home_dir user uid gid
    local gset_log kde_log xfce_log smoke_log
    user="$(id -un)"
    uid="$(id -u)"
    gid="$(id -g)"
    _smoke_require_desktop_workspace "$tmp" "$user" "$uid" "$gid"
    dest="$_SMOKE_DESKTOP_DEST"
    mock_bin="$_SMOKE_DESKTOP_MOCK_BIN"
    bus_root="$_SMOKE_DESKTOP_BUS_ROOT"
    home_dir="$_SMOKE_DESKTOP_HOME_DIR"
    gset_log="$tmp/logs/gsettings.log"
    kde_log="$tmp/logs/kde.log"
    xfce_log="$tmp/logs/xfce.log"
    : > "$gset_log"
    : > "$kde_log"
    : > "$xfce_log"
    if [ "$family" = "lxqt" ]; then
        _smoke_seed_lxqt_conf "$home_dir"
    fi
    _smoke_write_family_stubs "$family" "$mock_bin" "$gset_log" "$kde_log" "$xfce_log"
    mkdir -p "$REPO_ROOT/reports/distro-logs"
    smoke_log="$REPO_ROOT/reports/distro-logs/distro-compat-desktop-${family}${REPORT_DISTRO_SLUG:+-${REPORT_DISTRO_SLUG}}.log"
    _smoke_log "DESKTOP configure cycle: family=$family"
    _smoke_run_logged_step "install.sh DESKTOP ($family) failed" "$smoke_log" \
        _smoke_run_desktop_install "$family" "$dest" "$mock_bin" "$bus_root"
    _smoke_assert_family_installed "$family" "$dest" "$home_dir" "$uid" \
        "$gset_log" "$kde_log" "$xfce_log"
    _smoke_run_logged_step "uninstall.sh after DESKTOP ($family) failed" "$smoke_log" \
        _smoke_run_desktop_uninstall "$dest" "$mock_bin" "$bus_root"
    _smoke_assert_family_uninstalled "$family" "$dest" "$home_dir" "$uid" \
        "$gset_log" "$kde_log" "$xfce_log"
    _smoke_log "DESKTOP cycle passed: family=$family"
}

_smoke_desktop_family_cycle() {
    local family="$1"
    (
        local tmp
        set -euo pipefail
        tmp=$(mktemp -d)
        trap 'rm -rf "'"$tmp"'"' EXIT
        _smoke_desktop_family_cycle_body "$family" "$tmp"
        trap - EXIT
        rm -rf "$tmp"
    ) || exit $?
}

_run_desktop_install_uninstall_cycles() {
    local family
    for family in gnome kde xfce lxqt cinnamon mate; do
        _smoke_desktop_family_cycle "$family"
    done
}

_verify_python_gi_import() {
    local py
    _smoke_log "Checking python3 GLib (gi) for gsettings as-array helpers"
    for py in /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
        [ -n "$py" ] && [ -x "$py" ] || continue
        if "$py" -c 'import gi; gi.require_version("GLib", "2.0"); from gi.repository import GLib' \
            >/dev/null 2>&1; then
            _smoke_log "  ✓ $py imports gi.repository.GLib"
            return 0
        fi
    done
    _smoke_fail "no python3 with gi/GLib (need python3-gi / python3-gobject / python-gobject)"
}

_verify_optional_desktop_cli_tools() {
    local tool
    _smoke_log "Probing optional DESKTOP CLI tools (informational)"
    for tool in kwriteconfig6 kwriteconfig5 xfconf-query qdbus6 qdbus-qt6 qdbus \
        lxqt-config lxqt-config-monitor screengrab \
        cinnamon-settings mate-control-center mate-display-properties \
        gnome-screenshot mate-screenshot; do
        if command -v "$tool" >/dev/null 2>&1; then
            _smoke_log "  ✓ $tool present"
        else
            _smoke_log "  · $tool absent (DESKTOP smoke uses stubs)"
        fi
    done
    return 0
}
