#!/usr/bin/env bash
# Sourced by distro_install_smoke_desktop.sh — desktop-family dispatch helpers.

_smoke_write_secondary_family_stubs() {
    local family="$1" mock_bin="$2" gset_log="$3"
    case "$family" in
        lxqt) _smoke_write_lxqt_stubs "$mock_bin" ;;
        cinnamon) _smoke_write_cinnamon_stubs "$mock_bin" "$gset_log" ;;
        mate) _smoke_write_mate_stubs "$mock_bin" "$gset_log" ;;
        *) _smoke_fail "unknown desktop family for smoke: $family" ;;
    esac
}

_smoke_write_family_stubs() {
    local family="$1" mock_bin="$2" gset_log="$3" kde_log="$4" xfce_log="$5"
    # FULL_DE: fail closed when curated image should have real CLIs; stubs still
    # drive install/uninstall wiring asserts under the mock PATH.
    if [ "${ASUS_CI_FULL_DE:-}" = "1" ]; then
        _smoke_require_full_de_clis "$family"
    fi
    case "$family" in
        gnome) _smoke_write_gnome_stubs "$mock_bin" "$gset_log" ;;
        kde) _smoke_write_kde_stubs "$mock_bin" "$kde_log" ;;
        xfce) _smoke_write_xfce_stubs "$mock_bin" "$xfce_log" ;;
        *) _smoke_write_secondary_family_stubs "$@" ;;
    esac
}

_smoke_assert_secondary_family_installed() {
    local family="$1" dest="$2" home_dir="$3" uid="$4" gset_log="$5"
    case "$family" in
        lxqt) _smoke_assert_lxqt_installed "$dest" "$home_dir" "$uid" ;;
        cinnamon) _smoke_assert_cinnamon_installed "$dest" "$uid" "$gset_log" ;;
        mate) _smoke_assert_mate_installed "$dest" "$uid" "$gset_log" ;;
    esac
}

_smoke_assert_family_installed() {
    local family="$1" dest="$2" home_dir="$3" uid="$4"
    local gset_log="$5" kde_log="$6" xfce_log="$7"
    case "$family" in
        gnome) _smoke_assert_gnome_installed "$dest" "$home_dir" "$uid" "$gset_log" ;;
        kde) _smoke_assert_kde_installed "$dest" "$uid" "$kde_log" ;;
        xfce) _smoke_assert_xfce_installed "$dest" "$uid" "$xfce_log" ;;
        *) _smoke_assert_secondary_family_installed "$@" ;;
    esac
}

_smoke_assert_secondary_family_uninstalled() {
    local family="$1" dest="$2" home_dir="$3" uid="$4" gset_log="$5"
    case "$family" in
        lxqt) _smoke_assert_lxqt_uninstalled "$dest" "$home_dir" "$uid" ;;
        cinnamon) _smoke_assert_cinnamon_uninstalled "$dest" "$uid" "$gset_log" ;;
        mate) _smoke_assert_mate_uninstalled "$dest" "$uid" "$gset_log" ;;
    esac
}

_smoke_assert_family_uninstalled() {
    local family="$1" dest="$2" home_dir="$3" uid="$4"
    local gset_log="$5" kde_log="$6" xfce_log="$7"
    case "$family" in
        gnome) _smoke_assert_gnome_uninstalled "$dest" "$home_dir" "$uid" "$gset_log" ;;
        kde) _smoke_assert_kde_uninstalled "$dest" "$uid" "$kde_log" ;;
        xfce) _smoke_assert_xfce_uninstalled "$dest" "$uid" "$xfce_log" ;;
        *) _smoke_assert_secondary_family_uninstalled "$@" ;;
    esac
}
