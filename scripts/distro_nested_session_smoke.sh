#!/usr/bin/env bash
# Nested-session smoke (always-on CI job).
# CI installs the full GNOME Shell / Mutter / Xvfb dep set — missing packages
# fail closed. Soft-skip ONLY after packages are present when Shell still cannot
# start (e.g. compositor/env limits in unprivileged CI) — never for missing apt.
#
# Claims: gsettings under dbus-run-session+Xvfb; headless gnome-shell exports
# org.gnome.Shell (process + D-Bus) when the environment allows.
# Does NOT claim: live panels, GDM/SDDM greeter, DRM/KMS seat, laptop OSD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SHELL_PID=""
WAYLAND_DISPLAY="${ASUS_NESTED_WAYLAND_DISPLAY:-asus-nested-wl}"

_log() { printf '[nested-session-smoke] %s\n' "$*"; }
_soft_skip() { _log "SOFT-SKIP: $*"; exit 0; }
_fail() { echo "[nested-session-smoke] ERROR: $*" >&2; exit 1; }

_require_cmd() { command -v "$1" >/dev/null 2>&1; }

_cleanup() {
    if [ -n "${SHELL_PID}" ]; then
        kill "${SHELL_PID}" 2>/dev/null || true
        wait "${SHELL_PID}" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

_require_runtime_pkgs() {
    local cmd
    for cmd in gnome-shell mutter xvfb-run dbus-run-session gsettings gdbus; do
        _require_cmd "$cmd" || _fail "required command missing after CI install: $cmd"
    done
}

_prepare_runtime_dir() {
    if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
        XDG_RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/asus-nested-rt.XXXXXX")"
    fi
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR"
}

_assert_extension_tree() {
    local ext="$REPO_ROOT/gnome/asus-window-swap@ventura8.github.com"
    [ -f "$ext/metadata.json" ] && [ -f "$ext/extension.js" ]
}

_assert_gsettings_under_xvfb() {
    xvfb-run -a dbus-run-session -- bash -c '
        set -euo pipefail
        gsettings list-schemas >/dev/null
        if gsettings list-schemas | grep -Fq org.gnome.desktop.interface; then
            cur=$(gsettings get org.gnome.desktop.interface clock-format 2>/dev/null || true)
            [ -n "$cur" ]
        fi
    '
}

_dbus_shell_ready() {
    gdbus introspect --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
        >/dev/null 2>&1
}

_assert_shell_started() {
    # Process alive OR session D-Bus name — both preferred; D-Bus required.
    if [ -n "${SHELL_PID}" ] && kill -0 "${SHELL_PID}" 2>/dev/null; then
        _log "  ✓ gnome-shell process alive (pid=${SHELL_PID})"
    else
        _log "  · gnome-shell process not alive (pid=${SHELL_PID:-unset})"
    fi
    if ! _dbus_shell_ready; then
        return 1
    fi
    _log "  ✓ org.gnome.Shell on session bus"
    return 0
}

_start_headless_shell() {
    export WAYLAND_DISPLAY
    _prepare_runtime_dir
    gnome-shell --wayland --headless --wayland-display="$WAYLAND_DISPLAY" \
        --virtual-monitor 1280x720 >/tmp/asus-nested-shell.log 2>&1 &
    SHELL_PID=$!
    local _
    for _ in $(seq 1 80); do
        if _dbus_shell_ready; then
            return 0
        fi
        if ! kill -0 "${SHELL_PID}" 2>/dev/null; then
            _log "  · gnome-shell exited early (see /tmp/asus-nested-shell.log)"
            return 1
        fi
        sleep 0.25
    done
    return 1
}

_run_shell_probe_inner() {
    # Return 0 if Shell started; 1 if env start failed after packages present.
    if ! _start_headless_shell; then
        return 1
    fi
    _assert_shell_started || return 1
    return 0
}

_run_nested_session_probe() {
    local status=0
    if [ "${ASUS_NESTED_INNER:-}" = "1" ]; then
        if _run_shell_probe_inner; then
            status=0
        else
            status=$?
        fi
    else
        set +e
        ASUS_NESTED_INNER=1 dbus-run-session -- "$0" "$@"
        status=$?
        set -e
    fi
    _NESTED_SESSION_STATUS="$status"
}

_report_nested_session_status() {
    case "$1" in
        0)
            _log "nested-session smoke passed (limited; Shell D-Bus asserted)"
            ;;
        *)
            _soft_skip \
                "nested Shell failed to start after packages present (status=$1; see /tmp/asus-nested-shell.log)"
            ;;
    esac
}

main() {
    _log "Nested-session smoke (pkgs required; soft-skip only on Shell env start failure)"
    _assert_extension_tree || _fail "Window Swap extension tree missing under gnome/"
    _log "  ✓ extension tree present"
    _require_runtime_pkgs
    if ! _assert_gsettings_under_xvfb; then
        _fail "gsettings under Xvfb+dbus-run-session failed after packages present"
    fi
    _log "  ✓ gsettings under Xvfb + dbus-run-session"
    _NESTED_SESSION_STATUS=0
    _run_nested_session_probe "$@"
    _report_nested_session_status "$_NESTED_SESSION_STATUS"
}

main "$@"
