#!/usr/bin/env bash
# kcov driver: exercise install.sh re-exec and validate helpers without shipping
# coverage-only branches in the product installer.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

export ASUS_INSTALL_SOURCE_ONLY=1
# shellcheck source=install.sh
source "$REPO_ROOT/install.sh"

_REEXEC_TEMP_FILES=()
_REEXEC_TEMP_DIRS=()
_REEXEC_RESTORE_CHMOD=()

_reexec_cleanup_temps() {
    local dir
    for dir in "${_REEXEC_RESTORE_CHMOD[@]+"${_REEXEC_RESTORE_CHMOD[@]}"}"; do
        chmod u+w "$dir" 2>/dev/null
    done
    _REEXEC_RESTORE_CHMOD=()
    if [ "${#_REEXEC_TEMP_FILES[@]}" -gt 0 ]; then
        rm -f "${_REEXEC_TEMP_FILES[@]}"
    fi
    if [ "${#_REEXEC_TEMP_DIRS[@]}" -gt 0 ]; then
        rm -rf "${_REEXEC_TEMP_DIRS[@]}"
    fi
    _REEXEC_TEMP_FILES=()
    _REEXEC_TEMP_DIRS=()
}

_run_reexec_helpers() {
    local empty_script bad_script ok_script filled_script nowrite_dir
    trap '_reexec_cleanup_temps; trap - RETURN' RETURN
    trap '_reexec_cleanup_temps' EXIT

    _exercise _is_stdin_executed_script >/dev/null
    _exercise _should_reexec_from_tty >/dev/null
    _exercise _reexec_from_tty_if_needed >/dev/null

    empty_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    _REEXEC_TEMP_FILES+=("$empty_script")
    : > "$empty_script"
    _exercise _reexec_capture_stdin_to_temp "$empty_script" </dev/null >/dev/null
    filled_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    _REEXEC_TEMP_FILES+=("$filled_script")
    _exercise _reexec_capture_stdin_to_temp "$filled_script" >/dev/null <<'EOF'
#!/bin/sh
exit 0
EOF
    bad_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    _REEXEC_TEMP_FILES+=("$bad_script")
    printf 'not-valid-bash((((\n' > "$bad_script"
    _exercise _reexec_validate_temp_script "$bad_script" >/dev/null
    ok_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    _REEXEC_TEMP_FILES+=("$ok_script")
    printf '#!/bin/sh\nexit 0\n' > "$ok_script"
    _exercise _reexec_validate_temp_script "$ok_script" >/dev/null

    # Cover stdin-capture write failure (unwritable destination).
    if [ "$(id -u)" -eq 0 ]; then
        echo "Skipping stdin-capture write-failure exercise as root (directory mode does not block writes)" >&2
    else
        nowrite_dir="$(mktemp -d "${TMPDIR:-/tmp}/asus-zenbook-nowrite.XXXXXX")"
        _REEXEC_TEMP_DIRS+=("$nowrite_dir")
        _REEXEC_RESTORE_CHMOD+=("$nowrite_dir")
        chmod a-w "$nowrite_dir"
        if _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
            _reexec_capture_stdin_to_temp "$nowrite_dir/blocked.sh" </dev/null >/dev/null; then
            echo "Expected _reexec_capture_stdin_to_temp to fail on unwritable destination" >&2
            return 1
        fi
    fi
    trap - EXIT
}

_run_validate_helpers() {
    _exercise _validate_required_source_file "/nope/missing.sh" "lab" >/dev/null 2>&1
    _exercise SCRIPT_DIR="$REPO_ROOT" _resolve_startup_library "install-shared.sh" >/dev/null
    _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" SCRIPT_DIR="$REPO_ROOT" \
        _resolve_startup_library "install-shared.sh" >/dev/null
    _exercise _install_source_dir_is_valid >/dev/null
    _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" _install_source_dir_is_valid >/dev/null
    _exercise _export_install_source_dir_if_valid >/dev/null
    _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" _resolve_install_script_dir >/dev/null
    _exercise INSTALL_SOURCE_DIR= _resolve_install_script_dir >/dev/null
    (
        cd /tmp || exit 1
        _exercise _export_install_source_dir_if_valid >/dev/null
        _exercise INSTALL_SOURCE_DIR= _install_source_dir_is_valid >/dev/null
        _exercise INSTALL_SOURCE_DIR= _resolve_install_script_dir >/dev/null
    )
}

_run_checksum_helpers() {
    local ok_script bad_script missing_sum
    ok_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    bad_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    _REEXEC_TEMP_FILES+=("$ok_script" "$bad_script")
    printf '#!/bin/sh\nexit 0\n' > "$ok_script"
    # Success path with valid INSTALL_SOURCE_DIR + matching sha256.
    _soft_expect 0 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="$REPO_ROOT" \
        _reexec_verify_temp_script_checksum "$REPO_ROOT/install.sh" >/dev/null
    # Missing checksum file.
    missing_sum="$(mktemp -d "${TMPDIR:-/tmp}/asus-zenbook-nosum.XXXXXX")"
    _REEXEC_TEMP_DIRS+=("$missing_sum")
    mkdir -p "$missing_sum/bin" "$missing_sum/systemd"
    : > "$missing_sum/bin/.keep"
    : > "$missing_sum/systemd/.keep"
    printf '#!/bin/sh\nexit 0\n' > "$bad_script"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="$missing_sum" \
        _reexec_verify_temp_script_checksum "$bad_script" >/dev/null
    # Mismatched checksum.
    printf 'deadbeef  install.sh\n' > "$missing_sum/install.sh.sha256"
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="$missing_sum" \
        _reexec_verify_temp_script_checksum "$bad_script" >/dev/null
    # Invalid INSTALL_SOURCE_DIR (no bin/+systemd/) → early checksum error.
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="/tmp" \
        _reexec_verify_temp_script_checksum "$bad_script" >/dev/null
}

_run_bootstrap_exercises() {
    local tmp_script prefix_dir
    tmp_script="$(mktemp --suffix=.sh "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX")"
    prefix_dir="$(mktemp -d "${TMPDIR:-/tmp}/asus-zenbook-prefix.XXXXXX")"
    _REEXEC_TEMP_FILES+=("$tmp_script")
    _REEXEC_TEMP_DIRS+=("$prefix_dir")
    printf '#!/bin/sh\nexit 0\n' > "$tmp_script"
    mkdir -p "$prefix_dir/usr/local/bin" \
        "$prefix_dir/usr/local/lib/asus-zenbook-linux-tools" \
        "$prefix_dir/etc/systemd/system"
    # Same-shell calls (not _exercise) so kcov attributes the CCN-split helpers.
    PREFIX="" BIN_DIR="" LIB_DIR="" SYS_DIR="" HOOK_DIR=""
    unset ASUS_HOST_ROOT DESTDIR
    _soft_expect 0 _bootstrap_set_install_prefix_paths
    _soft_expect 0 test "$BIN_DIR" = "/usr/local/bin"
    ASUS_HOST_ROOT="$prefix_dir" _soft_expect 0 _bootstrap_set_install_prefix_paths
    _soft_expect 0 test "$BIN_DIR" = "$prefix_dir/usr/local/bin"
    unset ASUS_HOST_ROOT
    DESTDIR="$prefix_dir" _soft_expect 0 _bootstrap_set_install_prefix_paths
    _soft_expect 0 test "$LIB_DIR" = \
        "$prefix_dir/usr/local/lib/asus-zenbook-linux-tools"
    unset DESTDIR
    _soft_expect 0 _bootstrap_resolve_installer_script_dir
    _soft_expect 0 test -n "$SCRIPT_DIR"
    _soft_expect 0 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="$REPO_ROOT" INSTALL_TEMP_SCRIPT="$tmp_script" \
        _bootstrap_installer_after_reexec >/dev/null
    _soft_expect 0 _exercise \
        PREFIX="$prefix_dir" \
        BIN_DIR="$prefix_dir/usr/local/bin" \
        LIB_DIR="$prefix_dir/usr/local/lib/asus-zenbook-linux-tools" \
        SYS_DIR="$prefix_dir/etc/systemd/system" \
        _prepare_install_runtime "$REPO_ROOT" >/dev/null
    _soft_expect 0 _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" \
        _pwd_of_bash_source_dir >/dev/null
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR= INSTALL_STDIN_REEXEC=1 \
        _resolve_install_script_dir >/dev/null
    # Reexec body until checksum/validate failure (avoid final exec).
    _reexec_saved_should=$(declare -f _should_reexec_from_tty)
    _should_reexec_from_tty() { return 0; }
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="/tmp" \
        _reexec_from_tty_if_needed >/dev/null </dev/null
    _soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
        INSTALL_SOURCE_DIR="$REPO_ROOT" \
        _reexec_from_tty_if_needed >/dev/null <<'EOF'
#!/bin/sh
exit 0
EOF
    eval "$_reexec_saved_should"
    unset _reexec_saved_should
    # Full reexec body through chmod/exec stubs (avoid replacing this shell).
    (
        set +e
        _should_reexec_from_tty() { return 0; }
        _reexec_verify_temp_script_checksum() { return 0; }
        _reexec_validate_temp_script() { return 0; }
        exec() { printf 'stub-exec\n'; return 0; }
        _reexec_from_tty_if_needed <<'EOF'
#!/bin/sh
exit 0
EOF
    )
    (
        set +e
        pwd() { return 1; }
        _pwd_of_bash_source_dir || true
        true
    )
    _soft_expect 0,1 _exercise INSTALL_SOURCE_DIR="$REPO_ROOT" \
        _prepare_install_runtime "$REPO_ROOT" >/dev/null
}

_run_reexec_helpers
_run_validate_helpers
_run_checksum_helpers
_run_bootstrap_exercises
