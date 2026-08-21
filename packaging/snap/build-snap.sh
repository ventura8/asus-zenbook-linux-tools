#!/usr/bin/env bash
# Build classic snap for GitHub Releases.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNAP_DIR="${REPO_ROOT}/packaging/snap"
ARTIFACTS_DIR="${ASUS_RELEASE_ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

# shellcheck source=scripts/release_package_kinds.sh
source "${REPO_ROOT}/scripts/release_package_kinds.sh"

mkdir -p "$ARTIFACTS_DIR"
chmod +x "${SNAP_DIR}/asus-zenbook-configure-wrapper" \
    "${REPO_ROOT}/packaging/stage-payload.sh" \
    "${REPO_ROOT}/packaging/asus-zenbook-configure"

if ! command -v snapcraft >/dev/null 2>&1; then
    echo "snapcraft is required" >&2
    exit 1
fi

if ! snap version >/dev/null 2>&1; then
    echo "snapd must be available to build snaps" >&2
    exit 1
fi

_sudo_n() {
    if ! sudo -n true >/dev/null 2>&1; then
        echo "Passwordless sudo (-n) is required for snapcraft packaging" >&2
        return 1
    fi
    sudo -n "$@"
}

_lxd_run() {
    if lxc list >/dev/null 2>&1; then
        "$@"
        return $?
    fi
    if command -v sg >/dev/null 2>&1 && getent group lxd >/dev/null 2>&1; then
        sg lxd -c "$(printf '%q ' "$@")"
        return $?
    fi
    _sudo_n "$@"
}

_lxd_profile_ready() {
    _lxd_run sh -c 'lxc profile show default 2>/dev/null | grep -Fq "path: /"'
}

_ubuntu_version_id() {
    if [ -r /etc/os-release ]; then
        (
            # shellcheck source=/dev/null
            . /etc/os-release
            printf '%s\n' "${VERSION_ID:-}"
        )
    fi
}

_snapcraft_try_lxd_init() {
    if _lxd_run lxc list >/dev/null 2>&1 && _lxd_profile_ready; then
        return 0
    fi
    _sudo_n lxd init --auto 2>/dev/null || true
    _sudo_n lxd waitready --timeout=120 2>/dev/null || true
}

_snapcraft_pack_via_lxd() {
    if ! snap list lxd >/dev/null 2>&1; then
        echo "lxd snap is required to build core24 snaps on non-24.04 Ubuntu" >&2
        return 1
    fi
    _snapcraft_try_lxd_init
    if ! _lxd_run lxc list >/dev/null 2>&1 || ! _lxd_profile_ready; then
        echo "LXD is not initialized for snapcraft (run: sudo lxd init --auto)" >&2
        return 1
    fi
    _lxd_run snapcraft pack --use-lxd
}

_snapcraft_pack() {
    local host_id="" host_ver=""
    if [ -r /etc/os-release ]; then
        read -r host_id < <(
            # shellcheck source=/dev/null
            . /etc/os-release
            printf '%s\n' "${ID:-}"
        )
    fi
    if [ "$host_id" = ubuntu ]; then
        host_ver="$(_ubuntu_version_id)"
        if [ "$host_ver" = "24.04" ]; then
            # Destructive mode builds directly on the host filesystem and
            # needs root to apt-get install the part's build-packages.
            _sudo_n snapcraft pack --destructive-mode
            return $?
        fi
    fi
    _snapcraft_pack_via_lxd
}

# Build from REPO_ROOT (via the top-level "snap" symlink to packaging/snap)
# so craft-parts' local-source work_dir equals its source root exactly.
# Building from a directory nested two levels inside `source:` (the old
# `cd "$SNAP_DIR"` + `source: ../..`) makes craft-parts ignore only the
# first path component of that nesting ("packaging"), silently dropping
# the whole packaging/ tree — including stage-payload.sh — from the copy.
cd "$REPO_ROOT"
rm -f asus-zenbook-linux-tools_*.snap
_snapcraft_pack
matches=()
shopt -s nullglob
matches=(asus-zenbook-linux-tools_"${VERSION}"_*.snap)
shopt -u nullglob
snap_file="$(_require_exact_one_glob "asus-zenbook-linux-tools_${VERSION}_*.snap" "${matches[@]}")"
cp "$snap_file" "${ARTIFACTS_DIR}/"
ls -la "${ARTIFACTS_DIR}/$(basename "$snap_file")"
