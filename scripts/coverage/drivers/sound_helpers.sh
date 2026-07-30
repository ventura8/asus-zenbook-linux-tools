#!/usr/bin/env bash
# kcov driver: exercise helpers from bin/asus-sound-fix.sh as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

KCOV_EXERCISE_RETURN_STATUS=1
# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

# shellcheck source=scripts/coverage/gates.sh
source "$REPO_ROOT/scripts/coverage/gates.sh"

_SOUND_HELPERS_LOG="$(resolve_reports_root)/distro-logs/sound_helpers_driver.log"
_SOUND_TEE_DIR=""
_SOUND_TEE_FIFO=""
mkdir -p "$(dirname "$_SOUND_HELPERS_LOG")"

_sound_helpers_report_flush() {
    local flush_status="$1"
    if [ "$flush_status" -eq 0 ]; then
        return 0
    fi
    echo "sound_helpers: tee flush failed with status $flush_status" >&3
}

_sound_helpers_remove_tee_dir() {
    local flush_status="$1" rm_status=0
    if [ -n "${_SOUND_TEE_DIR:-}" ]; then
        rm -rf "$_SOUND_TEE_DIR" || rm_status=$?
    fi
    if [ "$flush_status" -eq 0 ] && [ "$rm_status" -ne 0 ]; then
        printf '%s\n' "$rm_status"
    else
        printf '%s\n' "$flush_status"
    fi
}

_sound_helpers_flush_tee() {
    local entry_status=$? flush_status=0
    exec 1>&- 2>&-
    exec 2>&3
    if [ -n "${_SOUND_TEE_PID:-}" ]; then
        wait "$_SOUND_TEE_PID" || flush_status=$?
    fi
    flush_status="$(_sound_helpers_remove_tee_dir "$flush_status")"
    _sound_helpers_report_flush "$flush_status"
    exec 1>&4
    exec 4>&-
    exec 3>&-
    return "$entry_status"
}

_SOUND_TEE_DIR=$(mktemp -d)
trap 'rm -rf "${_SOUND_TEE_DIR:-}"' EXIT
_SOUND_TEE_FIFO="$_SOUND_TEE_DIR/tee.fifo"
mkfifo "$_SOUND_TEE_FIFO"
tee -a "$_SOUND_HELPERS_LOG" < "$_SOUND_TEE_FIFO" &
_SOUND_TEE_PID=$!
# Preserve original stderr on fd 3 so EXIT cleanup can report failures.
exec 4>&1
exec 3>&2
exec >"$_SOUND_TEE_FIFO" 2>&1
trap '_sound_helpers_flush_tee' EXIT

# shellcheck source=bin/asus-sound-fix.sh
source "$REPO_ROOT/bin/asus-sound-fix.sh" >/dev/null 2>&1

if [ -z "${DEV_SND_ROOT:-}" ]; then
    echo "DEV_SND_ROOT is required for the sound coverage driver" >&3
    exit 1
fi
hwdev="${DEV_SND_ROOT}/hwC0D0"

_run_sound_probe_helpers() {
    # Probe helpers are coverage-only; tolerate missing-device failures here.
    _soft _exercise _get_codec_file "$hwdev" >/dev/null
    _soft _exercise check_codec_match "$hwdev" >/dev/null
    _soft _exercise find_sound_hwdev >/dev/null
    _soft _exercise poll_sound_hwdev >/dev/null
}

_run_sound_apply_mode() {
    local status=0
    _exercise apply_hda_verbs "$hwdev" >/dev/null || status=$?
    return "$status"
}

_run_sound_verbs_mode() {
    local status=0
    _exercise _run_hda_verbs "$hwdev" hda-verb >/dev/null 2>&1 || status=$?
    return "$status"
}

_run_sound_fallback_mode() {
    # Cover python3 asus_hda_verb.py when system hda-verb is absent and the
    # helper is resolved beside a staged script (Rocky-style layout), not the
    # checkout bin/ tree that always ships asus_hda_verb.py.
    local status=0 py src tool
    # Non-local so the RETURN trap can expand the path under set -u after locals end.
    _SOUND_FALLBACK_ISOLATED="$(mktemp -d)"
    trap 'rm -rf "${_SOUND_FALLBACK_ISOLATED:-}"; unset _SOUND_FALLBACK_ISOLATED; trap - RETURN' RETURN
    mkdir -p "$_SOUND_FALLBACK_ISOLATED/bin" "$_SOUND_FALLBACK_ISOLATED/path"
    cp "$REPO_ROOT/bin/asus-sound-fix.sh" "$_SOUND_FALLBACK_ISOLATED/bin/asus-sound-fix.sh"
    printf 'import sys\nsys.exit(0)\n' > "$_SOUND_FALLBACK_ISOLATED/bin/asus_hda_verb.py"
    for tool in bash sed grep dirname basename; do
        src="$(type -P "$tool" 2>/dev/null || true)"
        [ -n "$src" ] || continue
        ln -s "$src" "$_SOUND_FALLBACK_ISOLATED/path/$tool"
    done
    py="$(type -P python3 2>/dev/null || true)"
    if [ -n "$py" ]; then
        ln -s "$py" "$_SOUND_FALLBACK_ISOLATED/path/python3"
    fi
    _exercise env PATH="$_SOUND_FALLBACK_ISOLATED/path" \
        ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="$REPO_ROOT/lib" \
        DEV_SND_ROOT="$DEV_SND_ROOT" \
        PROC_ASOUND_ROOT="${PROC_ASOUND_ROOT:-/proc/asound}" \
        bash "$_SOUND_FALLBACK_ISOLATED/bin/asus-sound-fix.sh" >/dev/null || status=$?
    return "$status"
}

_sound_remove_prepare_tree() {
    local prefix="$1" ctl="$2"
    mkdir -p "${prefix}/usr/local/bin" \
        "${prefix}/usr/local/lib/asus-zenbook-linux-tools" \
        "${prefix}/etc/systemd/system" \
        "${prefix}/lib/systemd/system-sleep" \
        "${prefix}/var/lib/asus-zenbook-linux-tools"
    printf '#!/bin/sh\nexit 0\n' > "$ctl"
    chmod +x "$ctl"
}

_sound_remove_load_uninstall() {
    local ctl="$1"
    # uninstall.sh assigns SYSTEMCTL from SYSTEMCTL_CMD at source time.
    export SYSTEMCTL_CMD="$ctl" SYSTEMCTL="$ctl" SKIP_PKG_REMOVE=1
    if declare -F remove_installed_files >/dev/null 2>&1; then
        return 0
    fi
    # shellcheck source=uninstall.sh
    ASUS_UNINSTALL_SOURCE_ONLY=1 source "$REPO_ROOT/uninstall.sh" >/dev/null 2>&1 || true
    declare -F remove_installed_files >/dev/null 2>&1
}

_sound_remove_export_dirs() {
    local prefix="$1" ctl="$2"
    PREFIX="$prefix"
    BIN_DIR="${prefix}/usr/local/bin"
    LIB_DIR="${prefix}/usr/local/lib/asus-zenbook-linux-tools"
    SYS_DIR="${prefix}/etc/systemd/system"
    HOOK_DIR="${prefix}/lib/systemd/system-sleep"
    STATE_DIR="${prefix}/var/lib/asus-zenbook-linux-tools"
    SYSTEMCTL="$ctl"
    export PREFIX BIN_DIR LIB_DIR SYS_DIR HOOK_DIR STATE_DIR SYSTEMCTL SKIP_PKG_REMOVE SYSTEMCTL_CMD
}

_run_sound_remove_mode() {
    local status=0 owned_dest saved_destdir="" had_destdir=0 prefix ctl
    if [ -v DESTDIR ]; then
        had_destdir=1
        saved_destdir="$DESTDIR"
    fi
    owned_dest=$(mktemp -d)
    DESTDIR="$owned_dest"
    export DESTDIR
    prefix="$DESTDIR"
    ctl="${prefix}/usr/local/bin/fake-systemctl"
    _sound_remove_prepare_tree "$prefix" "$ctl"
    if ! _sound_remove_load_uninstall "$ctl"; then
        echo "remove_installed_files is required for SOUND_HELPER_MODE=remove" >&2
        rm -rf "$owned_dest"
        return 1
    fi
    _sound_remove_export_dirs "$prefix" "$ctl"
    _exercise remove_installed_files >/dev/null 2>&1 || status=$?
    rm -rf "$owned_dest"
    if [ "$had_destdir" -eq 1 ]; then
        export DESTDIR="$saved_destdir"
    else
        unset DESTDIR
    fi
    return "$status"
}

_run_sound_mode_helpers() {
    local mode="${SOUND_HELPER_MODE:-apply}"
    case "$mode" in
        apply) _run_sound_apply_mode ;;
        verbs) _run_sound_verbs_mode ;;
        fallback) _run_sound_fallback_mode ;;
        remove) _run_sound_remove_mode ;;
        *)
            echo "Unknown SOUND_HELPER_MODE: $mode" >&2
            return 1
            ;;
    esac
}

_run_sound_probe_helpers
_run_sound_mode_helpers
