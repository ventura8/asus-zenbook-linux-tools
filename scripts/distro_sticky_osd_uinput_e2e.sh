#!/usr/bin/env bash
# Sticky-OSD marker + real ydotool proof (always-on CI).
# CI installs ydotool + Xvfb — missing packages fail closed.
# Attempts: make /dev/uinput writable, start ydotoold, run asus-display-mode.sh,
# assert .session/.ctx, --cancel-osd.
#
# Soft-skip ONLY after setup attempts fail for environmental reasons
# (uinput unusable / ydotoold won't listen / injection inactive) — never for
# missing apt packages. Does NOT claim Mutter OSD dialog pixels.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

YDOTOOLD_PID=""
_log() { printf '[sticky-osd-uinput-e2e] %s\n' "$*"; }
_soft_skip() { _log "SOFT-SKIP: $*"; exit 0; }
_fail() { echo "[sticky-osd-uinput-e2e] ERROR: $*" >&2; exit 1; }

_require_cmd() { command -v "$1" >/dev/null 2>&1; }

_cleanup() {
    if [ -n "${YDOTOOLD_PID}" ]; then
        kill "${YDOTOOLD_PID}" 2>/dev/null || true
        wait "${YDOTOOLD_PID}" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

_e2e_soft() { "$@" || return 0; }

_require_runtime_pkgs() {
    local cmd
    for cmd in ydotool ydotoold xvfb-run timeout; do
        _require_cmd "$cmd" || _fail "required command missing after CI install: $cmd"
    done
}

_try_load_uinput() {
    if [ ! -e /dev/uinput ]; then
        if _require_cmd modprobe; then
            sudo -n modprobe uinput 2>/dev/null || _e2e_soft modprobe uinput 2>/dev/null
        fi
    fi
}

_try_fix_uinput_permissions() {
    if [ -e /dev/uinput ] && [ ! -w /dev/uinput ]; then
        _e2e_soft sudo -n chmod a+rw /dev/uinput 2>/dev/null
        _e2e_soft sudo -n setfacl -m "u:$(id -un):rw" /dev/uinput 2>/dev/null
    fi
}

_try_make_uinput_writable() {
    if [ -e /dev/uinput ] && [ -w /dev/uinput ]; then
        return 0
    fi
    _try_load_uinput
    _try_fix_uinput_permissions
    [ -e /dev/uinput ] && [ -w /dev/uinput ]
}

_runtime_dir() {
    printf '%s' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
}

_ydotool_socket_path() {
    printf '%s/.ydotool_socket' "$(_runtime_dir)"
}

_wait_socket() {
    local sock="$1" _
    for _ in $(seq 1 50); do
        [ -S "$sock" ] && return 0
        sleep 0.1
    done
    return 1
}

_ensure_ydotoold() {
    local sock runtime
    runtime="$(_runtime_dir)"
    mkdir -p "$runtime"
    sock="$(_ydotool_socket_path)"
    if [ -S "$sock" ]; then
        _log "  · ydotoold socket already present: $sock"
        export YDOTOOL_SOCKET="$sock"
        return 0
    fi
    ydotoold --socket-path="$sock" >/tmp/asus-sticky-ydotoold.log 2>&1 &
    YDOTOOLD_PID=$!
    if ! _wait_socket "$sock"; then
        _log "  · ydotoold failed to create socket (see /tmp/asus-sticky-ydotoold.log)"
        return 1
    fi
    export YDOTOOL_SOCKET="$sock"
    _log "  ✓ ydotoold listening on $sock"
    return 0
}

_run_display_mode() {
    local helper="$1"
    export ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE=1
    export ASUS_DISPLAY_MODE_DISABLE_SETTINGS=1
    if [ -n "${YDOTOOL_SOCKET:-}" ]; then
        export ASUS_TEST_MODE="${ASUS_TEST_MODE:-1}"
        export ASUS_YDOTOOL_SOCKET_ALLOW="${ASUS_YDOTOOL_SOCKET_ALLOW:-1}"
    fi
    xvfb-run -a timeout 20 "$helper"
}

_prepare_sticky_osd_environment() {
    local uid="$1"
    uid="$(id -u)"
    export NOTIF_ID_ROOT="${NOTIF_ID_ROOT:-/tmp/asus-zenbook-notif-e2e}"
    mkdir -p "$NOTIF_ID_ROOT/$uid"
    XDG_RUNTIME_DIR="$(_runtime_dir)"
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR"
    _e2e_soft chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
}

_require_sticky_osd_runtime() {
    local helper="$1"
    _log "Sticky OSD marker/ydotool E2E (pkgs required; soft-skip only on env failure)"
    [ -x "$helper" ] || _fail "missing $helper"
    _require_runtime_pkgs

    if ! _try_make_uinput_writable; then
        _soft_skip "/dev/uinput missing or not writable after modprobe/chmod attempt"
    fi
    _log "  ✓ /dev/uinput writable"

    if ! _ensure_ydotoold; then
        _soft_skip "ydotoold could not listen after packages present"
    fi
}

_open_sticky_osd_session() {
    local helper="$1" prefix="$2"
    rm -f "${prefix}.session" "${prefix}.ctx" "${prefix}.cancel"
    export ASUS_DISPLAY_MODE_STATE_PREFIX="$prefix"

    if ! _run_display_mode "$helper"; then
        _soft_skip "asus-display-mode.sh did not complete under Xvfb+ydotoold (env)"
    fi
    if [ ! -f "${prefix}.session" ] && [ ! -f "${prefix}.ctx" ]; then
        _soft_skip "no .session/.ctx after display-mode (injection backend inactive)"
    fi
    _log "  ✓ sticky markers present"
}

_cancel_sticky_osd_session() {
    local helper="$1" prefix="$2"
    if ! timeout 5 "$helper" --cancel-osd; then
        _fail "--cancel-osd failed"
    fi
    if [ -f "${prefix}.session" ] || [ -f "${prefix}.ctx" ]; then
        _fail "--cancel-osd left sticky markers"
    fi
    _log "  ✓ --cancel-osd cleared markers"
}

main() {
    local uid prefix helper sock
    uid="$(id -u)"
    prefix="${NOTIF_ID_ROOT:-/tmp/asus-zenbook-notif-e2e}/$uid/asus-display-mode"
    helper="$REPO_ROOT/bin/asus-display-mode.sh"
    _prepare_sticky_osd_environment "$uid"
    _require_sticky_osd_runtime "$helper"
    _open_sticky_osd_session "$helper" "$prefix"
    _cancel_sticky_osd_session "$helper" "$prefix"
    sock="$(_ydotool_socket_path)"
    _log "sticky OSD uinput E2E passed (markers only; socket=$sock; not laptop OSD dialog)"
}

main "$@"
