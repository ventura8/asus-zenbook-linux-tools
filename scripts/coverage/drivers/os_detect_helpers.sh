#!/usr/bin/env bash
# kcov driver: exercise lib/install-os-detection.sh helpers as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_driver_source_i18n || exit 1

# shellcheck source=lib/install-os-detection.sh
if ! source "$REPO_ROOT/lib/install-os-detection.sh"; then
    echo "os_detect_helpers: failed to source lib/install-os-detection.sh" >&2
    exit 1
fi

_run_os_lookup_helpers() {
    _exercise _trim_os_release_value "\"quoted\"" >/dev/null
    _exercise _trim_os_release_value "'quoted'" >/dev/null
    _exercise _lookup_os_family_exact ubuntu >/dev/null
    _exercise _lookup_os_family_exact fedora >/dev/null
    _exercise _lookup_os_family_exact arch >/dev/null
    _exercise _lookup_os_family_exact steamos >/dev/null
    _exercise _lookup_os_family_exact opensuse >/dev/null
    _exercise _lookup_os_family_exact bogus >/dev/null
    _exercise _lookup_os_family_like "*ubuntu*" >/dev/null
    _exercise _lookup_os_family_like "*fedora*" >/dev/null
    _exercise _lookup_os_family_like "*arch*" >/dev/null
    _exercise _lookup_os_family_like "*suse*" >/dev/null
    _exercise _lookup_os_family_like "*none*" >/dev/null
    _exercise _read_os_release_values >/dev/null
    _exercise _lookup_family_from_inputs ubuntu debian >/dev/null
    _exercise _lookup_family_from_inputs "" "*arch*" >/dev/null
    _exercise _lookup_family_from_inputs bogus "" >/dev/null
    _exercise _has_supported_pkg_manager >/dev/null
}

_run_os_family_detect() {
    _exercise INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian _detect_os_family >/dev/null
    _exercise INSTALL_OS_ID=fedora _detect_os_family >/dev/null
    _exercise INSTALL_OS_ID=arch _detect_os_family >/dev/null
    _exercise INSTALL_OS_ID=opensuse _detect_os_family >/dev/null
    _exercise INSTALL_OS_ID=linuxmint INSTALL_OS_ID_LIKE=ubuntu _detect_os_family >/dev/null
    _exercise INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' _detect_os_family >/dev/null
    unset INSTALL_OS_ID INSTALL_OS_ID_LIKE
    _exercise _detect_os_family >/dev/null
}

_run_pkg_installer_cmds() {
    local no_timeout
    _exercise INSTALL_OS_ID=ubuntu pkg_installer_cmd >/dev/null
    _exercise INSTALL_OS_ID=fedora pkg_installer_cmd >/dev/null
    _exercise INSTALL_OS_ID=arch pkg_installer_cmd >/dev/null
    _exercise INSTALL_OS_ID=opensuse pkg_installer_cmd >/dev/null
    _exercise INSTALL_OS_ID=bogus _detect_redhat_or_arch_pkg_cmd >/dev/null
    _exercise _report_no_pkg_installer >/dev/null
    _exercise _report_pkg_install_failure 1 >/dev/null
    _exercise _report_pkg_install_failure 124 >/dev/null
    _exercise _report_pkg_install_failure 137 >/dev/null
    _exercise _run_pkg_install_cmd "true" >/dev/null
    _exercise _run_pkg_install_cmd "false" >/dev/null
    # No timeout(1): cover the bash -c fallback branch.
    _exercise PATH="/usr/bin:/bin" _run_pkg_install_cmd "true" >/dev/null
    no_timeout=$(mktemp -d)
    printf '#!/bin/sh\nexit 0\n' > "$no_timeout/bash"
    chmod +x "$no_timeout/bash"
    _exercise PATH="$no_timeout" _run_pkg_install_cmd "true" >/dev/null
    _exercise PATH="$no_timeout" _run_pkg_install_cmd "false" >/dev/null
    rm -rf "$no_timeout"
}
_run_pkg_path_exercises() {
    local apt_only="" dnf_only="" pacman_only="" no_timeout=""
    _exercise PATH="/nonexistent" _report_no_pkg_installer >/dev/null
    _exercise PATH="/nonexistent" _has_supported_pkg_manager >/dev/null
    _exercise PATH="/nonexistent" _report_no_pkg_remover >/dev/null
    trap '{ [ -n "$apt_only" ] && rm -rf "$apt_only"; [ -n "$dnf_only" ] && rm -rf "$dnf_only"; [ -n "$pacman_only" ] && rm -rf "$pacman_only"; [ -n "$no_timeout" ] && rm -rf "$no_timeout"; }' RETURN
    apt_only=$(mktemp -d)
    dnf_only=$(mktemp -d)
    pacman_only=$(mktemp -d)
    no_timeout=$(mktemp -d)
    printf '#!/bin/sh\nexit 0\n' > "$apt_only/apt"
    printf '#!/bin/sh\nexit 0\n' > "$apt_only/dpkg"
    chmod +x "$apt_only/apt" "$apt_only/dpkg"
    _exercise PATH="$apt_only" INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian pkg_installer_cmd >/dev/null
    _exercise PATH="$apt_only" INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian pkg_remover_cmd >/dev/null
    # apt (not apt-get) debian installer command branch.
    _exercise PATH="$apt_only" INSTALL_OS_ID=debian _resolve_debian_pkg_cmd >/dev/null
    _exercise INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' install_system_deps >/dev/null
    _exercise INSTALL_OS_ID=rocky _rhel_family_skips_optional_rpm >/dev/null
    _exercise INSTALL_OS_ID=opensuse _resolve_any_supported_pkg_cmd >/dev/null

    printf '#!/bin/sh\nexit 0\n' > "$dnf_only/dnf"
    chmod +x "$dnf_only/dnf"
    _exercise PATH="$dnf_only" _resolve_any_supported_pkg_cmd >/dev/null

    printf '#!/bin/sh\nexit 0\n' > "$pacman_only/pacman"
    chmod +x "$pacman_only/pacman"
    _exercise PATH="$pacman_only" _resolve_any_supported_pkg_cmd >/dev/null
    _exercise _resolve_pkg_cmd_for_redhat_or_arch other >/dev/null

    _exercise _fallback_remove_packages_for_family debian >/dev/null
    _exercise _fallback_remove_packages_for_family suse >/dev/null
    _exercise _fallback_remove_packages_for_family redhat >/dev/null
    _exercise _fallback_remove_packages_for_family arch >/dev/null
    _exercise _is_base_runtime_pkg python3 >/dev/null
    _exercise _is_base_runtime_pkg ydotool >/dev/null
    _exercise INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' pkg_remover_cmd >/dev/null
    _exercise _resolve_pkg_remove_cmd_for_family bogus >/dev/null

    printf '#!/bin/sh\nexit 0\n' > "$no_timeout/bash"
    chmod +x "$no_timeout/bash"
    _exercise PATH="$no_timeout" INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        _run_pkg_remove_cmd "true" >/dev/null
    trap - RETURN
    rm -rf "$apt_only" "$dnf_only" "$pacman_only" "$no_timeout"
}

_make_pkg_manager_stubs() {
    local stub_dir="$1" tool
    mkdir -p "$stub_dir"
    for tool in apt apt-get dpkg dnf rpm pacman zypper yum sudo; do
        printf '#!/bin/sh\nexit 0\n' > "$stub_dir/$tool"
        chmod +x "$stub_dir/$tool"
    done
}

_run_install_system_deps() {
    local stubs=""
    trap '{ [ -n "$stubs" ] && rm -rf "$stubs"; }' RETURN
    stubs=$(mktemp -d)
    _make_pkg_manager_stubs "$stubs"
    _exercise SKIP_PKG_INSTALL=1 INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        install_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_INSTALL=0 \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian install_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_INSTALL=0 \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=fedora install_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_INSTALL=0 \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=arch install_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_INSTALL=0 \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=opensuse install_system_deps >/dev/null
    trap - RETURN
    rm -rf "$stubs"
}

_run_remove_system_deps() {
    local state="" stubs="" no_timeout=""
    trap '{ [ -n "$state" ] && rm -rf "$state"; [ -n "$stubs" ] && rm -rf "$stubs"; [ -n "$no_timeout" ] && rm -rf "$no_timeout"; }' RETURN
    state=$(mktemp -d)
    stubs=$(mktemp -d)
    mkdir -p "$state"
    _make_pkg_manager_stubs "$stubs"
    printf '%s\n' python3-evdev ydotool > "$state/installed-packages"
    _exercise SKIP_PKG_REMOVE=1 INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        remove_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_REMOVE=0 STATE_DIR="$state" \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian remove_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_REMOVE=0 STATE_DIR="$state" \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=fedora remove_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_REMOVE=0 STATE_DIR="$state" \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=arch remove_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_REMOVE=0 STATE_DIR="$state" \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=opensuse remove_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_REMOVE=0 STATE_DIR="$state/missing" \
        INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian remove_system_deps >/dev/null
    _exercise PATH="$stubs:$PATH" SUDO_CMD="$stubs/sudo" SKIP_PKG_REMOVE=0 STATE_DIR="$state/missing" \
        ASUS_UNINSTALL_FALLBACK_PKGS=1 INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian remove_system_deps >/dev/null
    _exercise _report_no_pkg_remover >/dev/null
    _exercise _report_pkg_remove_failure 1 >/dev/null
    _exercise _report_pkg_remove_failure 124 >/dev/null
    _exercise INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 _run_pkg_remove_cmd "true" >/dev/null
    _exercise INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 _run_pkg_remove_cmd "false" >/dev/null
    no_timeout=$(mktemp -d)
    printf '#!/bin/sh\nexit 0\n' > "$no_timeout/bash"
    chmod +x "$no_timeout/bash"
    _exercise PATH="$no_timeout" _run_pkg_remove_cmd "true" >/dev/null
    _exercise PATH="$no_timeout" _run_pkg_remove_cmd "false" >/dev/null
    rm -rf "$no_timeout"
    _exercise _validate_pkg_remove_resolution 1 >/dev/null
    _exercise _validate_pkg_remove_resolution 0 >/dev/null
    _exercise _handle_empty_pkg_remove_cmd "" >/dev/null
    trap - RETURN
    rm -rf "$state" "$stubs"
}

_run_pkg_name_validation() {
    _exercise _is_allowed_pkg_name "python3-evdev" >/dev/null
    _exercise _is_allowed_pkg_name "bad;pkg" >/dev/null
    _exercise _is_allowed_pkg_name "-evil-pkg" >/dev/null
    _exercise _emit_non_base_pkg_line "python3" >/dev/null
    _exercise _emit_non_base_pkg_line "ok-pkg" >/dev/null
    _exercise _emit_non_base_pkg_line "bad pkg" >/dev/null
}

_run_pkg_remove_cmd_resolution() {
    local state="" stubs=""
    trap '{ [ -n "$state" ] && rm -rf "$state"; [ -n "$stubs" ] && rm -rf "$stubs"; }' RETURN
    state=$(mktemp -d)
    stubs=$(mktemp -d)
    mkdir -p "$state"
    _make_pkg_manager_stubs "$stubs"
    printf '%s\n' python3-evdev ydotool > "$state/installed-packages"
    _exercise INSTALL_OS_ID=ubuntu pkg_remover_cmd >/dev/null
    _exercise INSTALL_OS_ID=fedora pkg_remover_cmd >/dev/null
    _exercise INSTALL_OS_ID=arch pkg_remover_cmd >/dev/null
    _exercise INSTALL_OS_ID=opensuse pkg_remover_cmd >/dev/null
    # Force non-empty filtered package lists so build_*_pkg_remove_cmd echoes.
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _resolve_debian_pkg_remove_cmd >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _resolve_suse_pkg_remove_cmd >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _resolve_redhat_pkg_remove_cmd >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _resolve_arch_pkg_remove_cmd >/dev/null
    # apt (not apt-get) remove command path
    rm -f "$stubs/apt-get"
    _exercise PATH="$stubs" STATE_DIR="$state" _resolve_debian_pkg_remove_cmd >/dev/null
    # Probe-any path when family detection fails.
    _exercise PATH="$stubs" STATE_DIR="$state" INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' \
        pkg_remover_cmd >/dev/null
    # Force build_* remove command echo paths with nonempty package lists.
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _build_debian_pkg_remove_cmd apt python3-evdev ydotool >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _build_debian_pkg_remove_cmd apt-get python3-evdev >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _build_arch_pkg_remove_cmd python-evdev >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _build_redhat_pkg_remove_cmd dnf python3-evdev >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _build_suse_pkg_remove_cmd python3-evdev >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" \
        _filter_installed_pkgs_pacman python3-evdev nosuch-pkg >/dev/null
    _exercise PATH="$stubs" STATE_DIR="$state" INSTALL_OS_ID=arch \
        _filter_installed_pkgs_for_family arch python-evdev >/dev/null
    trap - RETURN
    rm -rf "$state" "$stubs"
}

_run_pkg_reconcile_exercises() {
    local state missing record
    state=$(mktemp -d)
    trap 'rm -rf "$state"' RETURN
    mkdir -p "$state"
    STATE_DIR="$state"
    export STATE_DIR
    printf 'pkg-a\npkg-b\n' > "$state/installed-packages"
    missing="$state/missing"
    printf 'pkg-a\n\n' > "$missing"
    _exercise _pkg_revert_inputs_exist "$missing" >/dev/null
    _exercise _pkg_revert_inputs_exist "" >/dev/null
    _exercise STATE_DIR="" _pkg_revert_inputs_exist "$missing" >/dev/null
    _exercise _pkg_revert_record "$missing" >/dev/null
    _exercise _create_pkg_revert_temp >/dev/null
    record=$(_installed_packages_record_path)
    _exercise _write_reverted_pkg_record "$missing" "$record" "$state/tmp-merge" >/dev/null
    _exercise _revert_pkg_record_entries "$missing" >/dev/null
    _exercise _revert_pkg_record_entries "$state/nope" >/dev/null
    # mv failure on revert finalize.
    (
        mv() { return 1; }
        _exercise _revert_pkg_record_entries "$missing" >/dev/null
    )
    # Filter/merge failure edges for pkg-remove record helpers.
    _exercise _mv_tmp_to_pkg_record "$state/no-such-tmp" "$state/installed-packages" \
        >/dev/null
    _exercise _filter_missing_pkgs_for_record "$state/missing" >/dev/null
    : > "$state/empty-pkgs"
    _exercise _filter_missing_pkgs_for_record "$state/empty-pkgs" >/dev/null
    _exercise _record_packages_installed "$state/missing" >/dev/null
    _exercise _reconcile_packages_installed "$missing" >/dev/null
    _exercise INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' \
        _reconcile_packages_installed "$missing" >/dev/null
    # Force execute install failure + reconcile soft path.
    printf 'pkg-a\n' > "$missing"
    _exercise STATE_DIR="$state" _execute_pkg_install "false" "$missing" >/dev/null
    _exercise INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' install_system_deps >/dev/null
    _exercise INSTALL_OS_ID=ubuntu ASUS_PKG_MISSING_FILE="$state/miss" \
        install_system_deps >/dev/null
    _exercise _resolve_any_supported_pkg_cmd >/dev/null
    _exercise _validate_required_source_file "/missing-$$" "label" >/dev/null
    _exercise _read_os_release_values >/dev/null
    _exercise INSTALL_OS_ID= _detect_os_family >/dev/null
    _exercise INSTALL_OS_ID=debian _should_request_ydotool_deb >/dev/null
    _exercise INSTALL_OS_ID=ubuntu _should_request_ydotool_deb >/dev/null
    _exercise INSTALL_OS_ID=rocky _rhel_family_skips_optional_rpm >/dev/null
    _exercise INSTALL_OS_ID=fedora _rhel_family_skips_optional_rpm >/dev/null
    _exercise _write_missing_pkg_list >/dev/null
    _exercise ASUS_PKG_MISSING_FILE="$state/miss2" _write_missing_pkg_list >/dev/null
    _exercise ASUS_PKG_MISSING_FILE="$state/miss2" _write_missing_pkg_list a b >/dev/null
    _exercise _report_no_pkg_installer >/dev/null
    _exercise INSTALL_OS_ID=bogus INSTALL_OS_ID_LIKE='' _report_no_pkg_installer >/dev/null
    # debian apt (not apt-get) build branch + empty missing list.
    _exercise INSTALL_OS_ID=ubuntu _build_debian_pkg_cmd apt >/dev/null
    _exercise INSTALL_OS_ID=ubuntu _build_debian_pkg_cmd apt-get >/dev/null
    _exercise INSTALL_OS_ID=bogus _detect_debian_or_suse_pkg_cmd >/dev/null
    _exercise _resolve_pkg_cmd_for_debian_or_suse other >/dev/null
    _exercise _rpm_repo_has_pkg nosuch-pkg-$$ >/dev/null
    _exercise _os_release_id >/dev/null
}

_run_os_lookup_helpers
_run_os_family_detect
_run_pkg_installer_cmds
_run_install_system_deps
_run_remove_system_deps
_run_pkg_name_validation
_run_pkg_remove_cmd_resolution
_run_pkg_path_exercises
_run_pkg_reconcile_exercises
