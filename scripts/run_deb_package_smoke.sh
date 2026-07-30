#!/usr/bin/env bash
# Build an unsigned .deb and smoke-install/purge it (CI deb-package + local --full).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ASUS_DEB_ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
PACKAGE_NAME="${ASUS_DEB_PACKAGE_NAME:-asus-zenbook-linux-tools}"

_require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$1" >&2
        return 1
    }
}

_require_exact_one_glob() {
    local label="$1"
    shift
    local matches=("$@")
    if [ "${#matches[@]}" -ne 1 ]; then
        printf 'Expected exactly one %s file, found %s\n' "$label" "${#matches[@]}" >&2
        printf '%s\n' "${matches[@]}" >&2
        return 1
    fi
    printf '%s\n' "${matches[0]}"
}

_apt_install_local_deb() {
    # apt treats unprefixed dir/file.deb as release/package; require ./ or absolute.
    local deb_path="$1" install_path
    if [[ "$deb_path" == /* || "$deb_path" == ./* ]]; then
        install_path="$deb_path"
    else
        install_path="./$deb_path"
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$install_path"
}

_install_packaging_deps() {
    if [ "${SKIP_DEB_PKG_DEPS:-0}" = "1" ]; then
        return 0
    fi
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential debhelper dpkg-dev gettext \
        python3-evdev python3-dbus python3-yaml
}

_cleanup_debian_build_tree() {
    # Drop staged payload / dh state so a later lint pass cannot treat
    # debian/asus-zenbook-linux-tools/usr/.../bin/*.py as product duplicates.
    rm -rf \
        "$REPO_ROOT/debian/.debhelper" \
        "$REPO_ROOT/debian/asus-zenbook-linux-tools" \
        "$REPO_ROOT/debian/tmp"
    rm -f \
        "$REPO_ROOT/debian/files" \
        "$REPO_ROOT/debian/debhelper-build-stamp" \
        "$REPO_ROOT/debian"/*.substvars
}

_prepare_build_writable_dirs() {
    mkdir -p "$REPO_ROOT/reports/distro-logs" "$ARTIFACTS_DIR"
    # Always clear prior packaging trees (root-owned leftovers block dh_clean).
    _cleanup_debian_build_tree
    if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
        return 0
    fi
    chown -R "$SUDO_USER:" "$REPO_ROOT/reports/distro-logs" "$ARTIFACTS_DIR"
}

_build_as_sudo_user() {
    runuser -u "$SUDO_USER" -- dpkg-checkbuilddeps
    runuser -u "$SUDO_USER" -- dpkg-buildpackage -b -us -uc
}

_build_unsigned_deb() {
    # Match CI: dpkg-buildpackage / dh_auto_test run as a non-root user. When
    # local --full is invoked via sudo, drop back to SUDO_USER so unit tests do
    # not run as root against the live desktop session.
    _prepare_build_writable_dirs
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        _build_as_sudo_user
        return 0
    fi
    dpkg-checkbuilddeps
    dpkg-buildpackage -b -us -uc
}

_copy_parent_deb_to_artifacts() {
    local deb_file
    shopt -s nullglob
    deb_file=$(_require_exact_one_glob '../*.deb' ../*.deb) || return 1
    shopt -u nullglob
    ls -la "$deb_file"
    dpkg-deb -I "$deb_file"
    mkdir -p "$ARTIFACTS_DIR"
    cp "$deb_file" "$ARTIFACTS_DIR/"
}

_artifact_deb_path() {
    local -a matches=()
    local artifact
    shopt -s nullglob
    matches=("$ARTIFACTS_DIR"/*.deb)
    shopt -u nullglob
    artifact=$(_require_exact_one_glob 'artifacts/*.deb' "${matches[@]}") || return 1
    printf '%s\n' "$artifact"
}

_smoke_install_and_purge() {
    local artifact_deb rel_path
    artifact_deb=$(_artifact_deb_path) || return 1
    ls -la "$artifact_deb"
    # Prefer repo-relative path so local and CI logs match (./artifacts/…).
    rel_path="${artifact_deb#"$REPO_ROOT"/}"
    if [ "$rel_path" = "$artifact_deb" ]; then
        rel_path="$artifact_deb"
    fi
    _apt_install_local_deb "$rel_path"
    dpkg -s "$PACKAGE_NAME"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PACKAGE_NAME"
}

main() {
    _require_tool apt-get
    _require_tool dpkg-buildpackage
    _require_tool dpkg-checkbuilddeps
    _require_tool dpkg-deb
    _require_tool sudo
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        _require_tool runuser
    fi
    cd "$REPO_ROOT"
    trap '_cleanup_debian_build_tree' EXIT
    _install_packaging_deps
    _build_unsigned_deb
    _copy_parent_deb_to_artifacts
    _smoke_install_and_purge
    printf 'Debian package smoke passed (%s).\n' "$PACKAGE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
