#!/usr/bin/env bash
# Build a release package artifact for one matrix cell (tag workflow + local debug).
set -euo pipefail

PKG_KIND="${1:?package kind required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ASUS_RELEASE_ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
LOG_DIR="${REPO_ROOT}/reports/distro-logs"

# shellcheck source=scripts/release_package_kinds.sh
source "${SCRIPT_DIR}/release_package_kinds.sh"

mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR"

_artifacts_dir_for_docker() {
    _release_repo_relative_path "$REPO_ROOT" "$ARTIFACTS_DIR"
}

_rpm_top_for_docker() {
    printf '%s\n' ".rpm-build-${PKG_KIND}"
}

_run_docker_build() {
    local image="$1"
    local inner="$2"
    local docker_artifacts="" docker_rpm_top="" log_file=""
    docker_artifacts="$(_artifacts_dir_for_docker)"
    docker_rpm_top="$(_rpm_top_for_docker)"
    log_file="${LOG_DIR}/release-build-${PKG_KIND}.log"
    docker run --rm -i \
        -v "${REPO_ROOT}:/workspace:Z" \
        -w /workspace \
        -e "VERSION=${VERSION}" \
        -e "ASUS_RELEASE_ARTIFACTS_DIR=${docker_artifacts}" \
        -e "ASUS_RELEASE_PKG_KIND=${PKG_KIND}" \
        -e "ASUS_RELEASE_INSTALL_SMOKE=${ASUS_RELEASE_INSTALL_SMOKE:-1}" \
        -e "RPM_TOP=${docker_rpm_top}" \
        "$image" \
        bash -s <<<"$inner" 2>&1 | tee "$log_file"
    return "${PIPESTATUS[0]}"
}

_rpm_docker_copy_artifact() {
    printf '%s\n' 'cp "$rpm_path" "$artifacts_dir/"'
}

_rpm_install_smoke_snippet() {
    local install_line="$1"
    local remove_line="$2"
    cat <<EOF
if [ "\${ASUS_RELEASE_INSTALL_SMOKE:-1}" = "1" ]; then
  pkg_name="asus-zenbook-linux-tools"
  installed_rpm="\$artifacts_dir/\$(basename "\$rpm_path")"
  rpm -qip "\$installed_rpm"
  ${install_line}
  rpm -q "\$pkg_name"
  ${remove_line}
fi
EOF
}

_rpm_docker_body() {
    local install_cmd="$1"
    local copy_line="" install_smoke=""
    copy_line="$(_rpm_docker_copy_artifact)"
    install_smoke="$(_rpm_install_smoke_snippet "$2" "$3")"
    cat <<EOF
set -euo pipefail
artifacts_dir="\${ASUS_RELEASE_ARTIFACTS_DIR:-artifacts}"
rpm_top="\${RPM_TOP:-.rpm-build-\${ASUS_RELEASE_PKG_KIND}}"
case "\$artifacts_dir" in
  /*) ;;
  *) artifacts_dir="/workspace/\$artifacts_dir" ;;
esac
case "\$rpm_top" in
  /*) ;;
  *) rpm_top="/workspace/\$rpm_top" ;;
esac
mkdir -p "\$rpm_top" "\$artifacts_dir"
rm -rf "\$rpm_top"/RPMS "\$rpm_top"/SRPMS
${install_cmd}
chmod +x packaging/rpm/build-rpm.sh packaging/stage-payload.sh packaging/asus-zenbook-configure
RPM_TOP="\$rpm_top" ./packaging/rpm/build-rpm.sh
shopt -s nullglob
matches=("\$rpm_top"/RPMS/*/asus-zenbook-linux-tools-${VERSION}*.rpm)
shopt -u nullglob
if [ "\${#matches[@]}" -ne 1 ] || [ ! -f "\${matches[0]}" ]; then
  echo "RPM build produced unexpected package count for version ${VERSION}: \${#matches[@]}" >&2
  printf '%s\n' "\${matches[@]}" >&2
  exit 1
fi
rpm_path="\${matches[0]}"
${copy_line}
${install_smoke}
EOF
}

_build_rpm_fedora() {
    _run_docker_build \
        fedora:44@sha256:6c75d5bf57cb0fa5aa4b92c6a83c86c791644496d9ac230de7711f5b8ec3b898 \
        "$(_rpm_docker_body \
        "dnf install -y rpm-build gettext" \
        'dnf install -y "$installed_rpm"' \
        'dnf remove -y "$pkg_name"')"
}

_build_rpm_rocky() {
    _run_docker_build \
        rockylinux/rockylinux:10@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834 \
        "$(_rpm_docker_body \
        "dnf install -y rpm-build gettext" \
        'dnf install -y "$installed_rpm"' \
        'dnf remove -y "$pkg_name"')"
}

_build_rpm_opensuse() {
    _run_docker_build \
        opensuse/tumbleweed@sha256:6e40218854d0ef063cfbd0a05898c04d8cb7e4ec823f40cfe19f0c60ddb317e0 \
        "$(_rpm_docker_body \
        "zypper --non-interactive refresh
zypper --non-interactive install rpm-build gettext-tools alsa-utils python3 python313-evdev python313-dbus-python python313-gobject hda-verb" \
        'zypper --non-interactive install --allow-unsigned-rpm "$installed_rpm"' \
        'zypper --non-interactive remove -y "$pkg_name"')"
}

_build_arch_package() {
    chmod +x "${REPO_ROOT}/scripts/run_arch_package_smoke.sh"
    ASUS_ARCH_INSTALL_SMOKE="${ASUS_RELEASE_INSTALL_SMOKE:-1}" \
        ASUS_ARCH_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        "${REPO_ROOT}/scripts/run_arch_package_smoke.sh"
}

_build_portable_package() {
    local script_path="$1"
    chmod +x "$script_path"
    "$script_path"
}

_build_rpm_kind() {
    local kind="$1"
    case "$kind" in
        rpm-fedora-44) _build_rpm_fedora ;;
        rpm-rocky-10) _build_rpm_rocky ;;
        rpm-opensuse-tw) _build_rpm_opensuse ;;
        *) return 1 ;;
    esac
}

_build_portable_kind() {
    local kind="$1"
    case "$kind" in
        appimage)
            _build_portable_package "${REPO_ROOT}/packaging/appimage/build-appimage.sh"
            ;;
        flatpak)
            _build_portable_package "${REPO_ROOT}/packaging/flatpak/build-flatpak.sh"
            ;;
        snap)
            _build_portable_package "${REPO_ROOT}/packaging/snap/build-snap.sh"
            ;;
        *) return 1 ;;
    esac
}

_run_release_builder() {
    local kind="$1"
    shift
    local status=0
    if "$@"; then
        return 0
    else
        status=$?
    fi
    echo "Release build failed for ${kind} (exit ${status})." >&2
    return "$status"
}

_dispatch_pkg_kind() {
    local kind="$1"
    if ! _release_pkg_kind_is_valid "$kind"; then
        echo "Unknown package kind: $kind" >&2
        return 1
    fi
    if [[ "$kind" == rpm-* ]]; then
        _run_release_builder "$kind" _build_rpm_kind "$kind"
        return $?
    fi
    if [ "$kind" = "arch" ]; then
        _run_release_builder "$kind" _build_arch_package
        return $?
    fi
    _run_release_builder "$kind" _build_portable_kind "$kind"
}

_dispatch_pkg_kind "$PKG_KIND"
_release_pkg_validate_artifact "$PKG_KIND" "$ARTIFACTS_DIR" >/dev/null
ls -la "$ARTIFACTS_DIR"
