#!/usr/bin/env bash
# Build RPM package smoke: Fedora container build + optional install/remove cycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ASUS_RPM_ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
PACKAGE_NAME="${ASUS_RPM_PACKAGE_NAME:-asus-zenbook-linux-tools}"
IMAGE="${ASUS_RPM_SMOKE_IMAGE:-fedora:44}"
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

_run_fedora_smoke() {
    local docker_artifacts=""
    docker_artifacts="$(_release_repo_relative_path "$REPO_ROOT" "$ARTIFACTS_DIR")"
    mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR"
    docker run --rm \
        -v "${REPO_ROOT}:/workspace:Z" \
        -w /workspace \
        -e "PACKAGE_NAME=${PACKAGE_NAME}" \
        -e "VERSION=${VERSION}" \
        -e "ASUS_RPM_ARTIFACTS_DIR=${docker_artifacts}" \
        -e "ASUS_RPM_INSTALL_SMOKE=${ASUS_RPM_INSTALL_SMOKE:-1}" \
        -e "HOST_UID=$(id -u)" \
        -e "HOST_GID=$(id -g)" \
        "$IMAGE" \
        bash -lc '
set -euo pipefail
artifacts_dir="${ASUS_RPM_ARTIFACTS_DIR:-artifacts}"
case "$artifacts_dir" in
  /*) ;;
  *) artifacts_dir="/workspace/$artifacts_dir" ;;
esac
dnf install -y rpm-build gettext python3 python3-devel
rm -rf .rpm-build
chmod +x packaging/rpm/build-rpm.sh packaging/stage-payload.sh packaging/asus-zenbook-configure
./packaging/rpm/build-rpm.sh
shopt -s nullglob
matches=(.rpm-build/RPMS/*/asus-zenbook-linux-tools-"${VERSION}"*.rpm)
shopt -u nullglob
if [ "${#matches[@]}" -ne 1 ] || [ ! -f "${matches[0]}" ]; then
  echo "RPM build produced unexpected package count for version ${VERSION}: ${#matches[@]}" >&2
  printf "%s\n" "${matches[@]}" >&2
  exit 1
fi
rpm_path="${matches[0]}"
mkdir -p "$artifacts_dir"
cp "$rpm_path" "$artifacts_dir/"
rm -rf .rpm-build
chown -R "${HOST_UID}:${HOST_GID}" "$artifacts_dir"
rpm -qip "$artifacts_dir/$(basename "$rpm_path")"
if [ "${ASUS_RPM_INSTALL_SMOKE:-1}" = "1" ]; then
  dnf install -y "$artifacts_dir/$(basename "$rpm_path")"
  rpm -q "${PACKAGE_NAME}"
  dnf remove -y "${PACKAGE_NAME}"
fi
'
}

main() {
    _require_tool docker
    cd "$REPO_ROOT"
    mkdir -p "$LOG_DIR"
    rm -rf .rpm-build
    _run_fedora_smoke 2>&1 | tee "${LOG_DIR}/rpm-package-smoke.log"
    local -a matches=()
    shopt -s nullglob
    matches=("$ARTIFACTS_DIR"/asus-zenbook-linux-tools-"${VERSION}"*.rpm)
    shopt -u nullglob
    _require_exact_one_glob 'artifacts/*.rpm' "${matches[@]}" >/dev/null
    printf 'RPM package smoke passed (%s).\n' "$PACKAGE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
