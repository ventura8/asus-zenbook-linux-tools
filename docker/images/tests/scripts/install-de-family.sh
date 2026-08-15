#!/usr/bin/env bash
# Install curated DE-family packages for ASUS_CI_DE_FAMILY image variants.
# Empty family = no-op (headless/CLI PR images). Skips unpackaged cells with a log.
set -euo pipefail

FAMILY="${ASUS_CI_DE_FAMILY:-}"
if [ -z "$FAMILY" ]; then
    exit 0
fi

case "$FAMILY" in
    gnome|kde|xfce|lxqt|cinnamon|mate) ;;
    *)
        echo "install-de-family: unsupported ASUS_CI_DE_FAMILY='$FAMILY'" >&2
        exit 1
        ;;
esac

# EL10 EPEL ships libxfce4util 4.18.x but not xfconf — build matching upstream.
_XFCONF_VERSION="4.18.1"
_XFCONF_TARBALL_URL="https://archive.xfce.org/src/xfce/xfconf/4.18/xfconf-${_XFCONF_VERSION}.tar.bz2"
_XFCONF_TARBALL_SHA256="d9714751bbcfdc5a59340da6ef8ddfc0807221587b962d907f97dc0a8a002257"

declare -A APT_FAMILY_PACKAGES=(
    [gnome]="dconf-cli gsettings-desktop-schemas"
    [kde]="libkf6config-bin qt6-tools-dev"
    [xfce]="xfconf"
    [lxqt]="lxqt-globalkeys"
    [cinnamon]="cinnamon-desktop-data"
    [mate]="mate-desktop"
)
declare -A DNF_FAMILY_PACKAGES=(
    [gnome]="dconf gsettings-desktop-schemas"
    [kde]="kf6-kconfig"
    [xfce]="xfconf"
    [lxqt]="lxqt-globalkeys"
    [cinnamon]="cinnamon-desktop"
    [mate]="mate-desktop"
)
declare -A ZYPPER_FAMILY_PACKAGES=(
    [gnome]="gsettings-desktop-schemas"
    [kde]="kf6-kconfig"
    [xfce]="xfconf"
    [lxqt]="lxqt-globalkeys"
    [cinnamon]="cinnamon"
    [mate]="mate-desktop"
)
declare -A PACMAN_FAMILY_PACKAGES=(
    [gnome]="gsettings-desktop-schemas dconf"
    [kde]="kconfig"
    [xfce]="xfconf"
    [lxqt]="lxqt-globalkeys"
    [cinnamon]="cinnamon-desktop"
    [mate]="mate-desktop"
)

_os_id() {
    local id=""
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        id="${ID:-}"
    fi
    printf '%s' "$id"
}

_skip_rhel_unpackaged_de() {
    local id="$1"
    # cinnamon/mate/lxqt unpackaged on EL. Alma XFCE builds xfconf from source.
    case "$id-$FAMILY" in
        rocky-cinnamon|rocky-mate|almalinux-cinnamon|almalinux-mate|rhel-cinnamon|rhel-mate|\
        rocky-lxqt|almalinux-lxqt|rhel-lxqt)
            echo "install-de-family: skip $FAMILY on $id (unpackaged / RHEL gap)" >&2
            return 0
            ;;
    esac
    return 1
}

_dnf_packages_for_family() {
    local id="$1"
    case "$FAMILY" in
        kde)
            case "$id" in
                rocky|rhel)
                    # EL9: kf6-kconfig absent; kf5-kconfig provides kwriteconfig5.
                    printf '%s' "kf5-kconfig"
                    ;;
                *)
                    printf '%s' "kf6-kconfig"
                    ;;
            esac
            ;;
        *)
            printf '%s' "${DNF_FAMILY_PACKAGES[$FAMILY]}"
            ;;
    esac
}

_el_xfce_needs_source_build() {
    local id="$1"
    [ "$FAMILY" = "xfce" ] || return 1
    case "$id" in
        almalinux|rhel) return 0 ;;
        *) return 1 ;;
    esac
}

_xfconf_fetch_tarball() {
    local dest="$1"
    # Prefer PATH curl (Alma images ship curl-minimal; full curl conflicts with it).
    command -v curl >/dev/null || {
        echo "install-de-family: curl required to fetch xfconf tarball" >&2
        return 1
    }
    curl -fsSL --connect-timeout 15 --max-time 120 \
        --retry 8 --retry-all-errors --retry-delay 2 \
        "$_XFCONF_TARBALL_URL" -o "$dest"
    echo "${_XFCONF_TARBALL_SHA256}  ${dest}" | sha256sum -c -
}

_xfconf_build_and_install() {
    local src_root="$1"
    (
        cd "$src_root"
        ./configure --prefix=/usr --disable-static --disable-gtk-doc
        make -j"$(nproc)"
        make install
    )
}

_install_xfconf_from_source() {
    # EPEL on EL10 has libxfce4util but not xfconf; build a matching 4.18.x.
    local tarball="" src=""
    local -a build_pkgs=(
        gcc make pkgconf-pkg-config glib2-devel libxfce4util-devel
        dbus-devel dbus-glib-devel gettext intltool gobject-introspection-devel
        tar bzip2 ca-certificates
    )
    echo "install-de-family: building xfconf ${_XFCONF_VERSION} from source (EL gap)" >&2
    dnf -y install --setopt=install_weak_deps=False --nodocs "${build_pkgs[@]}"
    # Non-local path so RETURN trap under set -u can still expand it.
    _XFCONF_BUILD_TMP="$(mktemp -d)"
    trap 'rm -rf "${_XFCONF_BUILD_TMP:-}"' RETURN
    tarball="$_XFCONF_BUILD_TMP/xfconf.tar.bz2"
    _xfconf_fetch_tarball "$tarball"
    src="$_XFCONF_BUILD_TMP/src"
    mkdir -p "$src"
    tar -xjf "$tarball" -C "$src" --strip-components=1
    _xfconf_build_and_install "$src"
    command -v xfconf-query >/dev/null
    dnf -y remove --setopt=clean_requirements_on_remove=0 \
        gcc make pkgconf-pkg-config glib2-devel libxfce4util-devel \
        dbus-devel dbus-glib-devel intltool gobject-introspection-devel \
        tar bzip2
    # Keep runtime libxfce4util (pulled by -devel); fail closed if CLI vanished.
    dnf -y install --setopt=install_weak_deps=False --nodocs libxfce4util
    command -v xfconf-query >/dev/null
    xfconf-query --version >/dev/null
}

_install_apt() {
    local -a pkgs=()
    read -r -a pkgs <<< "${APT_FAMILY_PACKAGES[$FAMILY]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-gi gettext
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
    rm -rf /var/lib/apt/lists/*
}

_install_dnf() {
    local -a pkgs=()
    local id pkg_line
    id="$(_os_id)"
    pkg_line="$(_dnf_packages_for_family "$id")"
    read -r -a pkgs <<< "$pkg_line"
    dnf -y install --setopt=install_weak_deps=False --nodocs \
        python3-gobject gettext
    if dnf -y install --setopt=install_weak_deps=False --nodocs "${pkgs[@]}"; then
        dnf clean all
        return 0
    fi
    if _el_xfce_needs_source_build "$id"; then
        _install_xfconf_from_source
        dnf clean all
        return 0
    fi
    echo "install-de-family: skip $FAMILY on $id (dnf install failed / unpackaged)" >&2
    return 0
}

_install_zypper() {
    local -a pkgs=()
    read -r -a pkgs <<< "${ZYPPER_FAMILY_PACKAGES[$FAMILY]}"
    zypper --non-interactive install -y \
        python3-gobject gettext-runtime
    if ! zypper --non-interactive install -y "${pkgs[@]}"; then
        echo "install-de-family: skip $FAMILY on openSUSE (packages unknown or conflict)" >&2
        return 0
    fi
    zypper clean --all
}

_install_pacman() {
    local -a pkgs=()
    read -r -a pkgs <<< "${PACMAN_FAMILY_PACKAGES[$FAMILY]}"
    pacman -Syu --noconfirm
    pacman -S --noconfirm --needed python-gobject gettext
    pacman -S --noconfirm --needed "${pkgs[@]}"
    pacman -Scc --noconfirm
}

_install_with_available_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        _install_apt
        return 0
    fi
    if command -v dnf >/dev/null 2>&1; then
        _install_dnf
        return 0
    fi
    if command -v zypper >/dev/null 2>&1; then
        _install_zypper
        return 0
    fi
    if command -v pacman >/dev/null 2>&1; then
        _install_pacman
        return 0
    fi
    echo "install-de-family: no supported package manager" >&2
    return 1
}

main() {
    local id
    id="$(_os_id)"
    if _skip_rhel_unpackaged_de "$id"; then
        return 0
    fi
    echo "install-de-family: installing curated packages for family=$FAMILY id=$id"
    _install_with_available_manager
}

main "$@"
