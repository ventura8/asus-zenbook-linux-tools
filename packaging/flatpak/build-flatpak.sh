#!/usr/bin/env bash
# Build experimental Flatpak single-file bundle for GitHub Releases.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLATPAK_DIR="${REPO_ROOT}/packaging/flatpak"
ARTIFACTS_DIR="${ASUS_RELEASE_ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
OUTPUT="${ARTIFACTS_DIR}/asus-zenbook-linux-tools-${VERSION}.flatpak"
FLATHUB_LOCATOR="https://flathub.org/repo/flathub.flatpakrepo"
FLATHUB_REPO_URL="https://dl.flathub.org/repo/"

_flatpak_run_as_builder_user() {
    # flatpak --user + bwrap cannot use root-owned .flatpak-builder trees under sudo.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        if ! command -v runuser >/dev/null 2>&1; then
            echo "runuser is required to build Flatpak as ${SUDO_USER}" >&2
            return 1
        fi
        runuser -u "$SUDO_USER" -- "$@"
        return $?
    fi
    "$@"
}

_flatpak_has_runtime() {
    _flatpak_run_as_builder_user flatpak --user info org.freedesktop.Platform//24.08 \
        >/dev/null 2>&1 \
        && _flatpak_run_as_builder_user flatpak --user info org.freedesktop.Sdk//24.08 \
            >/dev/null 2>&1
}

_ensure_flathub_remote() {
    local remotes="" existing_url="" expected_url=""
    remotes="$(_flatpak_run_as_builder_user flatpak --user remotes --columns=name,url 2>/dev/null || true)"
    if printf '%s\n' "$remotes" | awk '$1 == "flathub" { found=1; exit 0 } END { exit !found }'; then
        existing_url="$(printf '%s\n' "$remotes" | awk '$1 == "flathub" { print $2; exit }')"
        existing_url="${existing_url%/}"
        expected_url="${FLATHUB_REPO_URL%/}"
        if [ "$existing_url" != "$expected_url" ]; then
            echo "Existing flathub remote URL mismatch: ${existing_url:-<empty>}" >&2
            echo "Expected: $expected_url" >&2
            exit 1
        fi
        return 0
    fi
    _flatpak_run_as_builder_user flatpak --user remote-add --if-not-exists flathub \
        "$FLATHUB_LOCATOR"
}

_flatpak_wipe_staging() {
    # Host rm may fail on root-owned leftovers from a prior sudo pipeline run.
    rm -rf "${FLATPAK_DIR}/builddir" "${FLATPAK_DIR}/repo" \
        "${REPO_ROOT}/.flatpak-builder" 2>/dev/null || true
    if [ -e "${FLATPAK_DIR}/builddir" ] || [ -e "${FLATPAK_DIR}/repo" ] \
        || [ -e "${REPO_ROOT}/.flatpak-builder" ]; then
        docker run --rm \
            -v "${REPO_ROOT}:/workspace:Z" \
            -w /workspace \
            alpine:3.20 \
            sh -c 'rm -rf /workspace/.flatpak-builder \
                /workspace/packaging/flatpak/builddir \
                /workspace/packaging/flatpak/repo'
    fi
}

_flatpak_prepare_writable_dirs() {
    mkdir -p "$ARTIFACTS_DIR"
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        chown "$SUDO_USER:" "$ARTIFACTS_DIR" \
            "${FLATPAK_DIR}" 2>/dev/null || true
    fi
}

mkdir -p "$ARTIFACTS_DIR"
_flatpak_prepare_writable_dirs
chmod +x "${FLATPAK_DIR}/asus-zenbook-configure-wrapper" \
    "${REPO_ROOT}/packaging/stage-payload.sh" \
    "${REPO_ROOT}/packaging/asus-zenbook-configure"

if ! command -v flatpak-builder >/dev/null 2>&1; then
    echo "flatpak-builder is required" >&2
    exit 1
fi

if ! _flatpak_has_runtime; then
    _ensure_flathub_remote
    _flatpak_run_as_builder_user flatpak --user install -y flathub \
        org.freedesktop.Platform//24.08 \
        org.freedesktop.Sdk//24.08
fi

_flatpak_wipe_staging
_flatpak_run_as_builder_user flatpak-builder --user --force-clean \
    --repo="${FLATPAK_DIR}/repo" \
    "${FLATPAK_DIR}/builddir" \
    "${FLATPAK_DIR}/org.github.ventura8.AsusZenBookLinuxTools.yml"

_flatpak_run_as_builder_user flatpak build-bundle --runtime-repo="$FLATHUB_LOCATOR" \
    "${FLATPAK_DIR}/repo" "$OUTPUT" \
    org.github.ventura8.AsusZenBookLinuxTools master

ls -la "$OUTPUT"
