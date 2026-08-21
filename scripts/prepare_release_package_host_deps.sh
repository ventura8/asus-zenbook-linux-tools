#!/usr/bin/env bash
# Install host tools required to build portable release packages (CI / local smoke).
set -euo pipefail

PKG_KIND="${1:?package kind required}"

_require_cmd_on_path() {
    local cmd="$1" err="$2"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$err" >&2
        return 1
    }
}

_install_appimage_apt_deps() {
    local fuse_pkg="libfuse2"
    sudo apt-get update
    if ! apt-cache show libfuse2 >/dev/null 2>&1; then
        fuse_pkg="libfuse2t64"
    fi
    sudo apt-get install -y curl file gettext "$fuse_pkg"
}

_install_appimage_host_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        _install_appimage_apt_deps
        return $?
    fi
    _require_cmd_on_path curl "curl is required for AppImage builds" || return 1
    _require_cmd_on_path file "file is required for AppImage install smoke" || return 1
    _require_cmd_on_path msgfmt "gettext msgfmt is required for AppImage builds"
}

_install_flatpak_host_deps() {
    if ! command -v flatpak-builder >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y flatpak flatpak-builder
        else
            echo "flatpak-builder is required" >&2
            return 1
        fi
    fi
    flatpak --user remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo
    flatpak --user install -y flathub org.freedesktop.Platform//24.08 \
        org.freedesktop.Sdk//24.08
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
    sudo "$@"
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

_os_release_id() {
    if [ -r /etc/os-release ]; then
        (
            # shellcheck source=/dev/null
            . /etc/os-release
            printf '%s\n' "${ID:-}"
        )
    fi
}

_ensure_snapcraft_installed() {
    if command -v snapcraft >/dev/null 2>&1; then
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "snapcraft is required" >&2
        return 1
    fi
    sudo apt-get update
    sudo apt-get install -y snapd
    sudo snap install snapcraft --classic
}

_snap_skip_lxd_setup() {
    local host_id="" host_ver=""
    host_id="$(_os_release_id)"
    [ "$host_id" = ubuntu ] || return 1
    host_ver="$(_ubuntu_version_id)"
    [ "$host_ver" = "24.04" ]
}

_ensure_lxd_profile_ready() {
    if ! _lxd_run lxc list >/dev/null 2>&1; then
        sudo lxd init --auto
        return 0
    fi
    if _lxd_run sh -c 'lxc profile show default 2>/dev/null | grep -Fq "path: /"'; then
        return 0
    fi
    sudo lxd init --auto
}

_configure_lxd_runner_access() {
    if getent group lxd >/dev/null 2>&1; then
        sudo usermod -aG lxd "$(id -un)" 2>/dev/null || true
        sudo snap set lxd daemon.group=lxd 2>/dev/null || true
    fi
    sudo lxd waitready --timeout=120 2>/dev/null || true
}

_verify_lxd_usable() {
    if _lxd_run lxc list >/dev/null 2>&1; then
        return 0
    fi
    echo "LXD is unavailable after init (ensure the runner user can run lxc list)" >&2
    return 1
}

_install_snap_host_deps() {
    _ensure_snapcraft_installed || return 1
    snap version >/dev/null 2>&1 || {
        echo "snapd must be available to build snaps" >&2
        return 1
    }
    if _snap_skip_lxd_setup; then
        return 0
    fi
    if ! snap list lxd >/dev/null 2>&1; then
        sudo snap install lxd
    fi
    _ensure_lxd_profile_ready
    _configure_lxd_runner_access
    _verify_lxd_usable
}

case "$PKG_KIND" in
    appimage)
        _install_appimage_host_deps
        ;;
    flatpak)
        _install_flatpak_host_deps
        ;;
    snap)
        _install_snap_host_deps
        ;;
    rpm-* | arch)
        ;;
    *)
        echo "Unknown package kind for host deps: $PKG_KIND" >&2
        exit 1
        ;;
esac
