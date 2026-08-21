#!/usr/bin/env bash
# Portable installer AppImage (runs asus-zenbook-configure; still requires root).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${REPO_ROOT}/packaging/appimage/AppDir"
ARTIFACTS_DIR="${ASUS_RELEASE_ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
OUTPUT="${ARTIFACTS_DIR}/asus-zenbook-linux-tools-${VERSION}-x86_64.AppImage"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
APPIMAGE_RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64"
APPIMAGE_RUNTIME_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

_verify_cached_sha256() {
    local dest="$1" expected_sha="$2" checksum_file=""
    checksum_file="$(mktemp)"
    printf '%s  %s\n' "$expected_sha" "$dest" > "$checksum_file"
    if sha256sum -c "$checksum_file" >/dev/null 2>&1; then
        rm -f "$checksum_file"
        return 0
    fi
    rm -f "$checksum_file"
    return 1
}

_verify_pinned_download() {
    local url="$1" dest="$2" expected_sha="$3" label="$4"
    local checksum_file=""
    echo "Downloading ${label}..." >&2
    curl -fsSL -o "$dest" "$url"
    checksum_file="$(mktemp)"
    printf '%s  %s\n' "$expected_sha" "$dest" > "$checksum_file"
    if ! sha256sum -c "$checksum_file" >/dev/null; then
        rm -f "$checksum_file" "$dest"
        echo "${label} checksum verification failed" >&2
        exit 1
    fi
    rm -f "$checksum_file"
}

_ensure_appimagetool() {
    local appimage="${REPO_ROOT}/.tools/appimagetool.AppImage"
    if [ -x "$appimage" ] && _verify_cached_sha256 "$appimage" "$APPIMAGETOOL_SHA256"; then
        printf '%s\n' "$appimage"
        return 0
    fi
    rm -f "$appimage"
    mkdir -p "${REPO_ROOT}/.tools"
    _verify_pinned_download "$APPIMAGETOOL_URL" "$appimage" \
        "$APPIMAGETOOL_SHA256" "appimagetool (pinned release 1.9.1)"
    chmod +x "$appimage"
    printf '%s\n' "$appimage"
}

_ensure_appimage_runtime() {
    local runtime="${REPO_ROOT}/.tools/appimage-runtime-x86_64"
    if [ -f "$runtime" ] && _verify_cached_sha256 "$runtime" "$APPIMAGE_RUNTIME_SHA256"; then
        printf '%s\n' "$runtime"
        return 0
    fi
    rm -f "$runtime"
    mkdir -p "${REPO_ROOT}/.tools"
    if [ -z "$APPIMAGE_RUNTIME_SHA256" ]; then
        echo "APPIMAGE_RUNTIME_SHA256 must be set for pinned runtime downloads" >&2
        exit 1
    fi
    _verify_pinned_download "$APPIMAGE_RUNTIME_URL" "$runtime" \
        "$APPIMAGE_RUNTIME_SHA256" "AppImage type-2 runtime (pinned release 20251108)"
    chmod +x "$runtime"
    printf '%s\n' "$runtime"
}

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR" "$ARTIFACTS_DIR"
"${REPO_ROOT}/packaging/stage-payload.sh" "$APP_DIR"

cat > "${APP_DIR}/AppRun" <<'EOF'
#!/bin/bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "${0}")")"
export INSTALL_SOURCE_DIR="${HERE}/usr/share/asus-zenbook-linux-tools"
if [ "$(id -u)" -ne 0 ]; then
    echo "This portable installer must run as root (sudo)." >&2
    echo "Example: sudo ./asus-zenbook-linux-tools-*.AppImage" >&2
    exit 1
fi
exec "${HERE}/usr/sbin/asus-zenbook-configure" "$@"
EOF
chmod +x "${APP_DIR}/AppRun"

cp "${REPO_ROOT}/packaging/appimage/org.github.ventura8.AsusZenBookLinuxTools.desktop" \
    "${APP_DIR}/org.github.ventura8.AsusZenBookLinuxTools.desktop"
cp "${REPO_ROOT}/assets/icons/asus-screenpad-toggle-symbolic.svg" \
    "${APP_DIR}/asus-zenbook-linux-tools.svg"
ln -sf asus-zenbook-linux-tools.svg "${APP_DIR}/.DirIcon"
mkdir -p "${APP_DIR}/usr/share/applications" "${APP_DIR}/usr/share/metainfo"
cp "${REPO_ROOT}/packaging/appimage/org.github.ventura8.AsusZenBookLinuxTools.desktop" \
    "${APP_DIR}/usr/share/applications/org.github.ventura8.AsusZenBookLinuxTools.desktop"
# appimagetool looks specifically for <desktop-basename>.appdata.xml
cp "${REPO_ROOT}/packaging/appimage/org.github.ventura8.AsusZenBookLinuxTools.metainfo.xml" \
    "${APP_DIR}/usr/share/metainfo/org.github.ventura8.AsusZenBookLinuxTools.appdata.xml"

appimagetool_appimage="$(_ensure_appimagetool)"
runtime_file="$(_ensure_appimage_runtime)"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool_appimage" \
    --runtime-file "$runtime_file" "$APP_DIR" "$OUTPUT"

chmod +x "$OUTPUT"
ls -la "$OUTPUT"
