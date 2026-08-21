#!/usr/bin/env bash
# Stage the product payload for native packages (.deb, .rpm, Arch).
# Usage: stage-payload.sh DESTROOT
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    echo "Usage: stage-payload.sh DESTROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTDIR="$1"

PKG_SHARE="${DESTDIR}/usr/share/asus-zenbook-linux-tools"
PKG_SBIN="${DESTDIR}/usr/sbin"
PKG_LOCALE="${DESTDIR}/usr/share/locale"
PKG_APPLICATIONS="${DESTDIR}/usr/share/applications"
PKG_ICONS="${DESTDIR}/usr/share/icons/hicolor/scalable/apps"

_stage_layout_dirs() {
    mkdir -p \
        "${PKG_SHARE}/bin" \
        "${PKG_SHARE}/lib" \
        "${PKG_SHARE}/systemd" \
        "${PKG_SHARE}/assets/icons" \
        "${PKG_SHARE}/assets/applications" \
        "${PKG_APPLICATIONS}" \
        "${PKG_ICONS}"
}

_stage_shell_assets() {
    shopt -s nullglob
    local f
    for f in "${REPO_ROOT}"/lib/*.sh; do
        cp -a "$f" "${PKG_SHARE}/lib/"
    done
    for f in "${REPO_ROOT}"/systemd/*.service; do
        cp -a "$f" "${PKG_SHARE}/systemd/"
    done
    for f in "${REPO_ROOT}"/assets/icons/asus-*-symbolic.svg; do
        cp -a "$f" "${PKG_SHARE}/assets/icons/"
    done
    shopt -u nullglob
}

_stage_optional_dirs() {
    if [ -d "${REPO_ROOT}/gnome" ]; then
        cp -a "${REPO_ROOT}/gnome" "${PKG_SHARE}/"
    fi
    if [ -d "${REPO_ROOT}/udev" ]; then
        cp -a "${REPO_ROOT}/udev" "${PKG_SHARE}/"
    fi
}

_stage_product_tree() {
    find "${REPO_ROOT}/bin" -maxdepth 1 -type f ! -name '__init__.py' \
        -exec cp -a {} "${PKG_SHARE}/bin/" \;
    find "${REPO_ROOT}/bin" -maxdepth 1 -type l -exec cp -a {} "${PKG_SHARE}/bin/" \;
    _stage_shell_assets
    cp -a \
        "${REPO_ROOT}/shared_imports.py" \
        "${REPO_ROOT}/VERSION" \
        "${REPO_ROOT}/install.sh" \
        "${REPO_ROOT}/uninstall.sh" \
        "${PKG_SHARE}/"
    _stage_optional_dirs
}

_stage_locale_catalogs() {
    if ! command -v msgfmt >/dev/null 2>&1; then
        echo "msgfmt is required to compile gettext catalogs" >&2
        exit 1
    fi

    shopt -s nullglob
    local f lang out
    for f in "${REPO_ROOT}"/po/*.po; do
        lang="${f##*/}"
        lang="${lang%.po}"
        out="${PKG_LOCALE}/${lang}/LC_MESSAGES"
        mkdir -p "$out"
        msgfmt -c -o "${out}/asus-zenbook-linux-tools.mo" "$f"
    done
    shopt -u nullglob

    if [ -f "${PKG_LOCALE}/jw/LC_MESSAGES/asus-zenbook-linux-tools.mo" ]; then
        mkdir -p "${PKG_LOCALE}/jv/LC_MESSAGES"
        cp -a "${PKG_LOCALE}/jw/LC_MESSAGES/asus-zenbook-linux-tools.mo" \
            "${PKG_LOCALE}/jv/LC_MESSAGES/asus-zenbook-linux-tools.mo"
    fi
}

_stage_configure_helper() {
    install -Dm755 "${REPO_ROOT}/packaging/asus-zenbook-configure" \
        "${PKG_SBIN}/asus-zenbook-configure"
    if [ -d "${REPO_ROOT}/packaging/scriptlets" ]; then
        mkdir -p "${PKG_SHARE}/packaging"
        cp -a "${REPO_ROOT}/packaging/scriptlets" "${PKG_SHARE}/packaging/"
    fi
}

_stage_layout_dirs
_stage_product_tree
_stage_locale_catalogs
_stage_configure_helper
