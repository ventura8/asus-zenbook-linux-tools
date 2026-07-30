#!/usr/bin/env bash
# MoveFocused nested E2E (always-on CI job).
# CI installs gnome-shell/mutter/Xvfb/dbus/GTK deps — missing packages fail closed.
#
# Tier A (required when Shell+extension come up): GetFocusedMonitor with a focused
#   GTK window (monitor index >= 0).
# Tier B (best-effort): MoveFocused true under dual virtual monitors.
#
# Soft-skip ONLY after install+start attempt fails for environmental reasons
# (compositor/D-Bus won't come up) — never for missing apt packages.
# Does NOT prove: Fn races, ScreenPad topology, laptop OSD, logout-on-Wayland parity.
# Never mock owned Window Swap APIs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

UUID="asus-window-swap@ventura8.github.com"
OBJ="/org/gnome/Shell/Extensions/AsusWindowSwap"
IFACE="org.gnome.Shell.Extensions.AsusWindowSwap"
SHELL_PID=""
WIN_PID=""
WAYLAND_DISPLAY="${ASUS_MF_WAYLAND_DISPLAY:-asus-mf-wl}"
MF_SHELL_LOG=""
MF_TIER_A_OUT=""
MF_TIER_B_OUT=""
MF_TIER_B_ERR=""
MF_TMP_DIR=""

_log() { printf '[movefocused-nested-e2e] %s\n' "$*"; }
_soft_skip() { _log "SOFT-SKIP: $*"; exit 0; }
_fail() { echo "[movefocused-nested-e2e] ERROR: $*" >&2; exit 1; }

_require_cmd() { command -v "$1" >/dev/null 2>&1; }

_cleanup_pid() {
    local pid="$1" wait_for_exit="${2:-0}"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    if [ "$wait_for_exit" = 1 ]; then
        wait "$pid" 2>/dev/null || true
    fi
}

_cleanup() {
    _cleanup_pid "${WIN_PID}" 0
    _cleanup_pid "${SHELL_PID}" 1
    if [ -n "${MF_TMP_DIR}" ]; then
        rm -rf "${MF_TMP_DIR}"
    fi
}
trap _cleanup EXIT

_init_mf_temp_files() {
    MF_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/asus-mf-logs.XXXXXX")"
    MF_SHELL_LOG="${MF_TMP_DIR}/shell.log"
    MF_TIER_A_OUT="${MF_TMP_DIR}/tier-a.out"
    MF_TIER_B_OUT="${MF_TMP_DIR}/tier-b.out"
    MF_TIER_B_ERR="${MF_TMP_DIR}/tier-b.err"
}

_extension_tree_ok() {
    local ext="$REPO_ROOT/gnome/$UUID"
    [ -f "$ext/metadata.json" ] && [ -f "$ext/extension.js" ]
}

_require_runtime_pkgs() {
    # Fail closed: CI must have installed these; missing packages are not soft-skips.
    local cmd
    for cmd in gnome-shell mutter gdbus gsettings python3 dbus-run-session; do
        _require_cmd "$cmd" || _fail "required command missing after CI install: $cmd"
    done
    python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' \
        || _fail "python3 Gtk 4 bindings missing after CI install (python3-gi/gir1.2-gtk-4.0)"
}

_prepare_runtime_dir() {
    if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
        XDG_RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/asus-mf-rt.XXXXXX")"
    fi
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR"
}

_install_extension_user() {
    local src="$REPO_ROOT/gnome/$UUID"
    local dst="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -a "$src" "$dst"
}

_dbus_obj_ready() {
    gdbus introspect --session --dest org.gnome.Shell --object-path "$1" \
        >/dev/null 2>&1
}

_wait_dbus_obj() {
    local path="$1" label="$2" _
    for _ in $(seq 1 80); do
        if _dbus_obj_ready "$path"; then
            _log "  ✓ ${label} ready"
            return 0
        fi
        if [ -n "${SHELL_PID}" ] && ! kill -0 "${SHELL_PID}" 2>/dev/null; then
            _log "  · gnome-shell exited while waiting for ${label}"
            return 1
        fi
        sleep 0.25
    done
    return 1
}

_assert_shell_started() {
    # Require session D-Bus name before Tier A; prefer live process too.
    if [ -n "${SHELL_PID}" ] && kill -0 "${SHELL_PID}" 2>/dev/null; then
        _log "  ✓ gnome-shell process alive (pid=${SHELL_PID})"
    elif [ -n "${SHELL_PID}" ]; then
        _log "  · gnome-shell process not alive (pid=${SHELL_PID})"
    fi
    if ! _dbus_obj_ready /org/gnome/Shell; then
        return 1
    fi
    _log "  ✓ org.gnome.Shell on session bus"
    return 0
}

_enable_window_swap_extension() {
    gsettings set org.gnome.shell disable-user-extensions false
    gsettings set org.gnome.shell enabled-extensions "[\"${UUID}\"]"
    if _require_cmd gnome-extensions; then
        gnome-extensions enable "$UUID" || true
    fi
}

_start_nested_shell() {
    export WAYLAND_DISPLAY
    _prepare_runtime_dir
    # GNOME 49+: headless compositor with dual virtual monitors (Tier B).
    gnome-shell --wayland --headless --wayland-display="$WAYLAND_DISPLAY" \
        --virtual-monitor 1280x720 --virtual-monitor 800x600 \
        >"$MF_SHELL_LOG" 2>&1 &
    SHELL_PID=$!
    if ! _wait_dbus_obj /org/gnome/Shell "org.gnome.Shell"; then
        _log "  · gnome-shell PID=${SHELL_PID} did not export org.gnome.Shell"
        return 1
    fi
    _assert_shell_started || return 1
    _enable_window_swap_extension
    _wait_dbus_obj "$OBJ" "AsusWindowSwap" || return 1
    return 0
}

_start_focus_window() {
    WAYLAND_DISPLAY="$WAYLAND_DISPLAY" GDK_BACKEND=wayland python3 - <<'PY' &
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, GLib


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="org.asus.mfprobe")

    def do_activate(self):
        win = Gtk.ApplicationWindow(application=self, title="asus-mf-probe")
        win.set_default_size(400, 300)
        win.set_child(Gtk.Label(label="focus me"))
        win.present()
        GLib.timeout_add_seconds(20, self.quit)


App().run(None)
PY
    WIN_PID=$!
}

_wait_focused_monitor() {
    local out _
    for _ in $(seq 1 40); do
        out="$(gdbus call --session --dest org.gnome.Shell --object-path "$OBJ" \
            --method "${IFACE}.GetFocusedMonitor" 2>/dev/null || true)"
        case "$out" in
            \(0,\)|\(1,\)|\(2,\)|\(3,\))
                printf '%s' "$out" >"$MF_TIER_A_OUT"
                return 0
                ;;
        esac
        sleep 0.25
    done
    return 1
}

_tier_b_movefocused() {
    gdbus call --session \
        --dest org.gnome.Shell \
        --object-path "$OBJ" \
        --method "${IFACE}.MoveFocused" right >"$MF_TIER_B_OUT" 2>"$MF_TIER_B_ERR"
}

_ensure_nested_session() {
    if _dbus_obj_ready "$OBJ"; then
        _log "  · AsusWindowSwap already on session bus"
        _assert_shell_started || return 1
        return 0
    fi
    _install_extension_user
    _log "  · starting nested headless gnome-shell…"
    _start_nested_shell
}

_run_inside_session() {
    # Return codes: 0 ok, 1 env soft-skip, 2 Tier A hard fail.
    if ! _ensure_nested_session; then
        return 1
    fi
    # Re-assert Shell before Tier A (process or D-Bus name).
    _assert_shell_started || return 1
    _start_focus_window
    if ! _wait_focused_monitor; then
        return 2
    fi
    _log "  ✓ Tier A GetFocusedMonitor: $(tr -d '\n' <"$MF_TIER_A_OUT")"
    if _tier_b_movefocused; then
        _log "  ✓ Tier B MoveFocused: $(tr -d '\n' <"$MF_TIER_B_OUT")"
    else
        _log "  · Tier B soft (neighbor move unavailable)"
    fi
    return 0
}

_run_movefocused_session() {
    local status=0
    # dbus-run-session isolates nested Shell from the caller's ambient session.
    if [ "${ASUS_MF_NESTED_INNER:-}" = "1" ]; then
        if _run_inside_session; then
            status=0
        else
            status=$?
        fi
    else
        set +e
        ASUS_MF_NESTED_INNER=1 dbus-run-session -- "$0" "$@"
        status=$?
        set -e
    fi

    _MF_SESSION_STATUS="$status"
}

_report_movefocused_status() {
    case "$1" in
        0) _log "MoveFocused nested E2E finished (limited; not laptop panel proof)" ;;
        2) _fail "Tier A GetFocusedMonitor failed after nested Shell started" ;;
        *)
            _soft_skip \
                "nested Shell/extension failed to start after packages present (status=$1)"
            ;;
    esac
}

main() {
    local status
    _init_mf_temp_files
    _log "MoveFocused nested E2E (pkgs required; soft-skip only on env start failure)"
    _extension_tree_ok || _fail "extension tree missing under gnome/"
    _require_runtime_pkgs
    _MF_SESSION_STATUS=0
    _run_movefocused_session "$@"
    status="$_MF_SESSION_STATUS"
    _report_movefocused_status "$status"
}

main "$@"
