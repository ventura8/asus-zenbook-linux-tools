#!/usr/bin/env bash
# Host-side install/remove smoke for portable release packages.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release_package_kinds.sh
source "${SCRIPT_DIR}/release_package_kinds.sh"

_release_appimage_install_smoke() {
    local artifact="$1"
    local magic="" extract_root="" abs_artifact=""
    chmod +x "$artifact"
    if [ ! -x "$artifact" ]; then
        printf 'AppImage is not executable: %s\n' "$artifact" >&2
        return 1
    fi
    magic="$(dd if="$artifact" bs=1 skip=8 count=3 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [ "$magic" != "414902" ]; then
        printf 'AppImage Type 2 magic (offset 8: AI\\x02) not found: %s\n' "$artifact" >&2
        return 1
    fi
    extract_root="$(mktemp -d)"
    abs_artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
    if ! ( cd "$extract_root" && "$abs_artifact" --appimage-extract >/dev/null ); then
        printf 'AppImage embedded SquashFS payload failed validation: %s\n' "$artifact" >&2
        rm -rf "$extract_root"
        return 1
    fi
    rm -rf "$extract_root"
}

_release_portable_install_smoke() {
    local kind="$1" artifacts_dir="$2"
    local artifact=""
    artifact="$(_release_pkg_validate_artifact "$kind" "$artifacts_dir")"
    case "$kind" in
        appimage)
            _release_appimage_install_smoke "$artifact"
            ;;
        flatpak)
            flatpak install --user -y --bundle "$artifact"
            flatpak uninstall --user -y org.github.ventura8.AsusZenBookLinuxTools
            ;;
        snap)
            sudo snap install --classic --dangerous "$artifact"
            sudo snap remove asus-zenbook-linux-tools
            ;;
        *)
            printf 'Portable install smoke called for non-portable kind: %s\n' "$kind" >&2
            return 1
            ;;
    esac
}

_release_pkg_install_smoke() {
    local kind="$1" artifacts_dir="$2"
    case "$kind" in
        appimage | flatpak | snap)
            _release_portable_install_smoke "$kind" "$artifacts_dir"
            ;;
        rpm-* | arch)
            return 0
            ;;
        *)
            printf 'Unknown package kind for install smoke: %s\n' "$kind" >&2
            return 1
            ;;
    esac
}
