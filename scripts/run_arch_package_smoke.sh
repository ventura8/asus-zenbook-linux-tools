#!/usr/bin/env bash
# Build Arch package smoke: archlinux container build + optional install/remove cycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ASUS_ARCH_ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
PACKAGE_NAME="${ASUS_ARCH_PACKAGE_NAME:-asus-zenbook-linux-tools}"
IMAGE="${ASUS_ARCH_SMOKE_IMAGE:-archlinux:latest}"
LOG_DIR="${REPO_ROOT}/reports/distro-logs"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

# shellcheck source=scripts/release_package_kinds.sh
source "${SCRIPT_DIR}/release_package_kinds.sh"

_require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$1" >&2
        return 1
    }
}

_run_arch_smoke() {
    local docker_artifacts="" host_uid="" host_gid=""
    docker_artifacts="$(_release_repo_relative_path "$REPO_ROOT" "$ARTIFACTS_DIR")"
    host_uid="$(id -u)"
    host_gid="$(id -g)"
    mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR"
    # Root is required for pacman; chown bind-mounted outputs to the host user
    # so workspace files are not left root-owned after the smoke.
    docker run --rm \
        -v "${REPO_ROOT}:/workspace:Z" \
        -w /workspace \
        -e "PACKAGE_NAME=${PACKAGE_NAME}" \
        -e "VERSION=${VERSION}" \
        -e "ASUS_ARCH_ARTIFACTS_DIR=${docker_artifacts}" \
        -e "ASUS_ARCH_INSTALL_SMOKE=${ASUS_ARCH_INSTALL_SMOKE:-1}" \
        -e "HOST_UID=${host_uid}" \
        -e "HOST_GID=${host_gid}" \
        "$IMAGE" \
        bash -lc '
set -euo pipefail
artifacts_dir="${ASUS_ARCH_ARTIFACTS_DIR:-artifacts}"
case "$artifacts_dir" in
  /*) ;;
  *) artifacts_dir="/workspace/$artifacts_dir" ;;
esac
pacman_retry="./docker/images/tests/scripts/pacman-retry.sh"
chmod +x "$pacman_retry"
"$pacman_retry" -Syu --noconfirm
"$pacman_retry" -S --noconfirm base-devel gettext python python-evdev python-dbus python-gobject alsa-utils
rm -f packaging/arch/asus-zenbook-linux-tools-*.pkg.tar.*
chmod +x packaging/arch/build-arch.sh packaging/stage-payload.sh packaging/asus-zenbook-configure
./packaging/arch/build-arch.sh
shopt -s nullglob
matches=(packaging/arch/asus-zenbook-linux-tools-"${VERSION}"*.pkg.tar.*)
shopt -u nullglob
if [ "${#matches[@]}" -ne 1 ] || [ ! -f "${matches[0]}" ]; then
  echo "Arch build produced unexpected package count for version ${VERSION}: ${#matches[@]}" >&2
  printf "%s\n" "${matches[@]}" >&2
  exit 1
fi
pkg_path="${matches[0]}"
mkdir -p "$artifacts_dir"
cp "$pkg_path" "$artifacts_dir/"
if [ "${ASUS_ARCH_INSTALL_SMOKE:-1}" = "1" ]; then
  pacman -U --noconfirm "$artifacts_dir/$(basename "$pkg_path")"
  pacman -Q "${PACKAGE_NAME}"
  pacman -R --noconfirm "${PACKAGE_NAME}"
fi
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID}" "$artifacts_dir" \
    packaging/arch/asus-zenbook-linux-tools-*.pkg.tar.* \
    packaging/arch/pkg packaging/arch/src 2>/dev/null || true
fi
'
}

main() {
    set -o pipefail
    _require_tool docker
    cd "$REPO_ROOT"
    mkdir -p "$LOG_DIR"
    _release_docker_rm "$REPO_ROOT" \
        "${REPO_ROOT}/packaging/arch/pkg" \
        "${REPO_ROOT}/packaging/arch/src"
    if ! _run_arch_smoke 2>&1 | tee "${LOG_DIR}/arch-package-smoke.log"; then
        return 1
    fi
    local -a matches=()
    shopt -s nullglob
    matches=("$ARTIFACTS_DIR"/asus-zenbook-linux-tools-"${VERSION}"*.pkg.tar.*)
    shopt -u nullglob
    _require_exact_one_glob 'artifacts/*.pkg.tar.*' "${matches[@]}" >/dev/null
    printf 'Arch package smoke passed (%s).\n' "$PACKAGE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
